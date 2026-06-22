//
//  WSClient.swift
//  HTTP request/response + polling client for the Pinch wire protocol.
//
//  WHY HTTP (not WebSockets): on the physical Apple Watch, plain HTTPS works
//  (URLSession dataTask GET → 200) but URLSessionWebSocketTask is refused by the
//  OS on the watch's network path. So we dropped WebSockets entirely on the watch
//  and talk to the backend over plain HTTP request/response + a short-poll loop.
//
//  Public API is UNCHANGED from the old WS client (init/configure/connect/disconnect/
//  reconnectNow/send + onState/onMessage callbacks + ConnectionState incl. .isAlive +
//  the resumeSessionId UserDefaults persistence), so the Store / views need no changes.
//
//  Transport (HTTP contract, base = configured serverURL forced to https, NO /ws path,
//  every request carries `Authorization: Bearer <token>`, JSON):
//   • connect(): POST {base}/api/session {deviceId, resumeSessionId?}
//       → {sessionId, mode, project, models, resumed, protocolVersion}
//       On success: store + persist sessionId, emit .ready AND synthesize onMessage(.ready)
//       so the Store populates mode/project/models exactly like the old WS `ready`.
//   • Poll loop (a Task while connected): every ~1.2s GET {base}/api/poll?sessionId=X&cursor=N
//       → {cursor, events:[ServerMsg...]}; decode each event with the existing ServerMsg
//       decoder, deliver via onMessage on the main actor, advance cursor to the high-water.
//       HTTP 410 (session_gone) → drop sessionId+resume and re-POST /api/session.
//       This loop REPLACES both the WS receive loop AND the heartbeat (no ping needed).
//   • send(ClientMsg) maps each case to an HTTP request (see sendRaw).
//
//  Threading: all internal state is touched only on `queue` (a private serial queue).
//  The two callbacks fire on the main actor for the SwiftUI Store. This keeps the class
//  data-race-free. All network requests use URLSession dataTask (NOT WebSocketTask) with
//  the same reachability-maximizing config proven to work for plain HTTPS on the watch.
//
//  Foreground-only by design: the Store connects on scenePhase .active and disconnects on
//  background (stops the poll loop).
//

import Foundation
import Network

/// High-level connection state for the UI badge. (Unchanged public surface.)
enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected          // session POST in flight / accepted, awaiting `ready`
    case ready              // `ready` received — fully usable
    case reconnecting(attempt: Int)
    case failed(String)     // fatal (bad token / version) — needs user action

    /// True while there's a live (or self-healing) connection: anything except a permanently
    /// dead state. Send stays ENABLED here so the message queues and the hardware double
    /// pinch always has a target. Only `.disconnected` / `.failed` are dead.
    var isAlive: Bool {
        switch self {
        case .connecting, .connected, .ready, .reconnecting: return true
        case .disconnected, .failed: return false
        }
    }
}

/// Owns the HTTP session lifecycle. State is confined to `queue`; callbacks hop to main.
/// (Class name kept as `WSClient` so the rest of the app is untouched, even though the
/// transport is now HTTP.)
final class WSClient: NSObject, @unchecked Sendable {

    // Configuration (only mutated on `queue`).
    private var serverURL: URL
    private var token: String
    private let deviceId: String

    // Callbacks — invoked on the main actor by the Store.
    var onState: (@MainActor (ConnectionState) -> Void)?
    var onMessage: (@MainActor (ServerMsg) -> Void)?

    private var session: URLSession!

    /// The live agent session id from the last /api/session, used by poll + all sends.
    private var sessionId: String?
    /// Monotonic poll cursor: the index we ask the backend for next (`>= cursor`). The
    /// backend's poll high-water is `nextIndex` (one PAST the last event), so feeding it
    /// straight back as the next cursor requests only strictly-new events.
    private var pollCursor = 0
    /// Idempotency high-water: the smallest event index we have NOT yet delivered to the
    /// Store. Events arrive WITHOUT their index over the wire, so we reconstruct each
    /// event's index from the returned high-water (the last event's index is `hi - 1`) and
    /// drop anything `< appliedHighWater`. This makes event-apply idempotent even if the
    /// backend (whose own dedup is being audited) ever re-sends — the same index can never
    /// be delivered twice, so a message can never append-or-speak twice on the watch.
    private var appliedHighWater = 0
    /// The poll loop task — replaces the WS receive loop AND the heartbeat.
    private var pollTask: Task<Void, Never>?

    /// Agent config pushed from the Store. Sent in the /api/session body so the very first
    /// turn uses them, and re-pushed via /api/config whenever the Store changes them on a
    /// live session. Defaults match Store's contract defaults.
    private var model = "claude-opus-4-8"
    private var thinking = "medium"

    /// The agent session to resume on the next /api/session. PERSISTED to UserDefaults so it
    /// survives the watchOS app being suspended-then-killed (the common case: the screen sleeps,
    /// watchOS reclaims us AND frequently terminates the process, so the next launch builds a
    /// fresh client). Without persistence, every relaunch sent a nil resumeSessionId → the
    /// backend spun a brand-new agent session and the whole conversation + context was lost.
    /// Keyed per (server, deviceId) so switching servers doesn't resurrect a dead session id.
    private var resumeSessionId: String? {
        didSet { Self.persistResume(resumeSessionId, key: resumeKey) }
    }
    private var resumeKey: String { "pinch.resumeSessionId.\(deviceId)" }

    // Reconnect bookkeeping.
    private var reconnectAttempt = 0
    private var shouldStayConnected = false
    private var reconnectTask: Task<Void, Never>?
    /// True once we've received `ready` at least once on the current credentials.
    /// If we never reach ready after several tries, it's almost certainly a bad token /
    /// version mismatch, so we stop hammering and surface a .failed state.
    private var everReachedReady = false
    private let maxColdAttempts = 3
    /// Last underlying error, surfaced in `.failed` so the user can read the real reason
    /// (bad host, timed out, TLS, no route) instead of a generic message.
    private var lastErrorMessage = "unknown error"

    /// Debounce / hysteresis for the connection pill. A single slow or dropped poll is
    /// normal on the watch's flaky path, so we DON'T flip the UI to disconnected on the
    /// first failure. We count consecutive poll failures and only surface a degraded state
    /// after this many in a row; any success resets the counter back to 0.
    private var consecutivePollFailures = 0
    private let pollFailureThreshold = 3
    /// The last state we actually emitted, so we can COALESCE: identical states are never
    /// re-emitted (stops the pill flapping connected/reconnecting/connected on every tick).
    private var lastEmittedState: ConnectionState?
    /// True once the poll loop has degraded to "reconnecting" so we know to announce the
    /// recovery (a single .ready emission) when polls start succeeding again.
    private var pollDegraded = false

    /// Serial queue that confines all internal state mutation.
    private let queue = DispatchQueue(label: "com.josh.pinch.http")

    /// DIAGNOSTIC: watches the OS's view of the network path for THIS app, logged at startup
    /// and on every change, so on-device we can see what the OS thinks the path is.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.josh.pinch.netmonitor")

    init(serverURL: URL, token: String, deviceId: String) {
        self.serverURL = serverURL
        self.token = token
        self.deviceId = deviceId
        super.init()
        // Restore the last session id so a relaunched app resumes instead of starting fresh.
        // Read directly (the property's didSet would just re-write the same value).
        self.resumeSessionId = UserDefaults.standard.string(forKey: "pinch.resumeSessionId.\(deviceId)")
        let config = URLSessionConfiguration.default
        // Same config proven to work for plain HTTPS on the watch: wait for a usable path
        // rather than instant-failing, and allow cellular / expensive (phone-relay) /
        // constrained (Low Data Mode) paths so the OS can fail over instead of giving up.
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForRequest = 30
        // No custom delegate queue needed for dataTask completions; default session is fine,
        // but we keep a delegate for the waiting-for-connectivity diagnostic.
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        startPathMonitor()
    }

    /// Update credentials/URL (from Settings). Caller should reconnect() after.
    func configure(serverURL: URL, token: String) {
        queue.async {
            // New credentials → give them a fresh shot at reaching ready, and drop any
            // resume id / live session that belonged to the OLD server/token.
            if self.serverURL != serverURL || self.token != token {
                self.everReachedReady = false
                self.resumeSessionId = nil
                self.sessionId = nil
            }
            self.serverURL = serverURL
            self.token = token
        }
    }

    // MARK: - Lifecycle

    func connect() {
        queue.async {
            self.shouldStayConnected = true
            self.reconnectTask?.cancel()
            self.openSession()
        }
    }

    func disconnect() {
        queue.async {
            self.shouldStayConnected = false
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.teardown(notify: true)
        }
    }

    /// Force a fresh attempt now (e.g. user tapped "reconnect" or settings changed).
    func reconnectNow() {
        queue.async {
            self.shouldStayConnected = true
            self.everReachedReady = false   // user asked to retry — clear the cold-attempt latch.
            self.teardown(notify: false)
            self.reconnectAttempt = 0
            self.openSession()
        }
    }

    // All `private` methods below assume they run on `queue`.

    /// "Connect" == POST /api/session. Emits .connecting while in flight; on success stores +
    /// persists the sessionId, emits .ready, synthesizes onMessage(.ready), and starts polling.
    private func openSession() {
        teardown(notify: false)
        emit(.connecting)

        guard let url = makeAPIURL(path: "/api/session") else {
            emit(.failed("Bad server URL"))
            return
        }

        if let monitor = pathMonitor {
            Self.logPath(monitor.currentPath, label: "at-session snapshot")
        }

        var body: [String: Any] = ["deviceId": deviceId, "model": model, "thinking": thinking]
        if let resumeSessionId { body["resumeSessionId"] = resumeSessionId }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            emit(.failed("Encode error"))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        NSLog("[PINCH-HTTP] POST %@ resume=%@", url.absoluteString, resumeSessionId ?? "nil")

        let captured = bodyData
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            // Completion runs on `queue` (the session's underlying queue).
            guard let self else { return }
            _ = captured
            if let nsErr = error as NSError? {
                NSLog("[PINCH-HTTP] session error domain=%@ code=%ld desc=%@",
                      nsErr.domain, nsErr.code, nsErr.localizedDescription)
                self.lastErrorMessage = nsErr.localizedDescription
                self.handleSessionFailure()
                return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 {
                NSLog("[PINCH-HTTP] session → %ld (auth)", code)
                self.shouldStayConnected = false
                self.emit(.failed("Auth failed — check your token."))
                return
            }
            if code == 426 {
                NSLog("[PINCH-HTTP] session → 426 (protocol mismatch)")
                self.shouldStayConnected = false
                self.emit(.failed("Protocol version mismatch — update the app."))
                return
            }
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["sessionId"] as? String else {
                NSLog("[PINCH-HTTP] session → %ld (unexpected/undecodable)", code)
                self.lastErrorMessage = "HTTP \(code)"
                self.handleSessionFailure()
                return
            }

            let resumed = (json["resumed"] as? Bool) ?? false
            NSLog("[PINCH-HTTP] session OK sessionId=%@ resumed=%@", sid, resumed ? "true" : "false")

            // Success → adopt the session, persist it as resume, reset backoff + debounce.
            self.sessionId = sid
            self.resumeSessionId = sid
            self.pollCursor = 0
            self.appliedHighWater = 0
            self.reconnectAttempt = 0
            self.everReachedReady = true
            self.consecutivePollFailures = 0
            self.pollDegraded = false
            self.emit(.connected)
            self.emit(.ready)

            // Synthesize the `ready` ServerMsg so the Store populates mode/project/models
            // exactly as the old WS `ready` frame did. We decode the response body through the
            // SAME ServerMsg decoder by reshaping it into a `ready`-typed object.
            if let readyMsg = self.makeReadyMessage(from: json) {
                Task { @MainActor [weak self] in self?.onMessage?(readyMsg) }
            }

            self.startPolling()
        }
        task.resume()
    }

    /// Reshape the /api/session JSON ({sessionId, mode, project, models, resumed, ...}) into a
    /// `{"type":"ready", ...}` object and decode it via the existing ServerMsg decoder, so the
    /// Store's handle(.ready) path is identical to the old WebSocket flow.
    private func makeReadyMessage(from json: [String: Any]) -> ServerMsg? {
        var obj = json
        obj["type"] = "ready"
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let msg = try? JSONDecoder().decode(ServerMsg.self, from: data) else {
            NSLog("[PINCH-HTTP] could not synthesize ready from session response")
            return nil
        }
        return msg
    }

    /// A session POST failed (network error / bad response). Tear down and back off if we still
    /// want to be connected; otherwise go quietly disconnected.
    private func handleSessionFailure() {
        teardown(notify: false)
        guard shouldStayConnected else { emit(.disconnected); return }
        scheduleReconnect()
    }

    /// Stop the poll loop and forget the live session. Optionally notify .disconnected.
    private func teardown(notify: Bool) {
        pollTask?.cancel(); pollTask = nil
        sessionId = nil
        if notify { emit(.disconnected) }
    }

    // MARK: - Poll loop (replaces WS receive loop + heartbeat)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000) // ~1.2s short-poll cadence
            }
        }
    }

    /// One poll: GET /api/poll?sessionId=X&cursor=N → {cursor, events:[ServerMsg...]}.
    /// Decodes each event with the existing ServerMsg decoder and delivers via onMessage on the
    /// main actor; advances the cursor to the returned high-water. HTTP 410 (session_gone) →
    /// drop sessionId+resume and re-POST /api/session.
    private func pollOnce() async {
        // Snapshot the bits we need on `queue` to stay data-race-free.
        let snapshot: (sid: String, cursor: Int, tok: String, url: URL)? = await withCheckedContinuation { cont in
            queue.async {
                guard let sid = self.sessionId,
                      var comps = self.makeAPIComponents(path: "/api/poll") else {
                    cont.resume(returning: nil); return
                }
                comps.queryItems = [
                    URLQueryItem(name: "sessionId", value: sid),
                    URLQueryItem(name: "cursor", value: String(self.pollCursor)),
                ]
                guard let url = comps.url else { cont.resume(returning: nil); return }
                cont.resume(returning: (sid, self.pollCursor, self.token, url))
            }
        }
        guard let snapshot else { return }

        var req = URLRequest(url: snapshot.url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(snapshot.tok)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let data: Data
        let code: Int
        do {
            let (d, response) = try await session.data(for: req)
            data = d
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            let nsErr = error as NSError
            NSLog("[PINCH-HTTP] poll error domain=%@ code=%ld desc=%@",
                  nsErr.domain, nsErr.code, nsErr.localizedDescription)
            // Transient poll error — keep the loop alive; the next tick retries. Don't flip the
            // pill to disconnected on the first miss; only surface "reconnecting" after several
            // consecutive failures (debounce), so a single slow poll can't make it flap.
            notePollFailure()
            return
        }

        if code == 410 {
            // session_gone — the backend lost our session. Drop it + resume id and re-create.
            NSLog("[PINCH-HTTP] poll → 410 session_gone, re-creating session")
            queue.async {
                self.sessionId = nil
                self.resumeSessionId = nil
                guard self.shouldStayConnected else { return }
                self.openSession()   // also cancels this poll task via teardown()
            }
            return
        }
        if code == 401 || code == 403 {
            NSLog("[PINCH-HTTP] poll → %ld (auth)", code)
            queue.async {
                self.shouldStayConnected = false
                self.teardown(notify: false)
                self.emit(.failed("Auth failed — check your token."))
            }
            return
        }
        guard code == 200 else {
            NSLog("[PINCH-HTTP] poll → %ld (unexpected)", code)
            notePollFailure()
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[PINCH-HTTP] poll → undecodable body")
            notePollFailure()
            return
        }

        // A clean 200 with a parseable body == alive. Reset the failure debounce and, if we
        // had previously degraded to "reconnecting", announce the single recovery (.ready).
        notePollSuccess()

        let highWater = json["cursor"] as? Int
        let rawEvents = (json["events"] as? [Any]) ?? []

        // The backend returns events ordered by index and reports `cursor` = nextIndex (one
        // PAST the last event), so over the WHOLE returned run the last event's index is
        // (highWater - 1), the one before (highWater - 2), … and the first raw event's index is
        // (highWater - rawEvents.count). We index off the RAW array (not the decoded one) so a
        // skipped/malformed event doesn't shift the indices of the ones after it. This is ring-
        // buffer safe — it never assumes the run started at our requested cursor. If the backend
        // omitted a high-water (shouldn't happen) we fall back to our applied mark.
        let firstRawIndex: Int
        if let highWater {
            firstRawIndex = highWater - rawEvents.count
        } else {
            firstRawIndex = appliedHighWater
        }

        for (rawOffset, raw) in rawEvents.enumerated() {
            let index = firstRawIndex + rawOffset
            guard let eventData = try? JSONSerialization.data(withJSONObject: raw),
                  let msg = try? JSONDecoder().decode(ServerMsg.self, from: eventData) else {
                continue   // malformed event — skip, don't kill the loop (its index is burned).
            }
            // IDEMPOTENT APPLY: drop anything we've already delivered. The same index can
            // never reach the Store twice → no double-append, no double-speak.
            let alreadyApplied: Bool = await withCheckedContinuation { cont in
                queue.async {
                    if index < self.appliedHighWater {
                        cont.resume(returning: true)
                    } else {
                        self.appliedHighWater = index + 1
                        cont.resume(returning: false)
                    }
                }
            }
            if alreadyApplied { continue }

            // Keep resume id fresh if the server re-announces ready over the poll channel.
            if case let .ready(ready) = msg {
                queue.async { self.resumeSessionId = ready.sessionId }
            }
            await MainActor.run { [weak self] in self?.onMessage?(msg) }
        }

        // Advance the poll cursor to the returned high-water (monotonic). Next poll asks for
        // `index >= highWater`, i.e. only events newer than everything we've now seen.
        if let highWater {
            queue.async { if highWater > self.pollCursor { self.pollCursor = highWater } }
        }
    }

    /// Record a failed poll. After `pollFailureThreshold` in a row, surface a single
    /// `.reconnecting` (deduped by emit's coalescing) so the pill shows a degraded — but not
    /// dead — state. We DON'T tear the session down; the loop keeps retrying and a later 410
    /// (session_gone) is the only thing that triggers a real re-create.
    private func notePollFailure() {
        queue.async {
            self.consecutivePollFailures += 1
            guard self.consecutivePollFailures >= self.pollFailureThreshold else { return }
            self.pollDegraded = true
            // Soft "reconnecting" — stays .isAlive so Send still works while the path
            // recovers. Use a FIXED attempt value so emit()'s coalescing collapses every
            // subsequent failed tick into nothing (the pill shows "reconnecting" once, not a
            // ticking counter).
            self.emit(.reconnecting(attempt: 1))
        }
    }

    /// Record a successful poll. Resets the failure debounce, and if we had degraded, emits a
    /// single `.ready` so the pill flips back to connected exactly once on recovery.
    private func notePollSuccess() {
        queue.async {
            self.consecutivePollFailures = 0
            if self.pollDegraded {
                self.pollDegraded = false
                self.emit(.ready)
            }
        }
    }

    // MARK: - Sending (ClientMsg → HTTP)

    /// Public send — marshals onto `queue` so it's serialized with the session lifecycle.
    func send(_ msg: ClientMsg) {
        queue.async { self.sendRaw(msg) }
    }

    /// Update the agent config (model + thinking level). Always records the values so the NEXT
    /// /api/session body carries them; if a session is already live, also pushes them now via
    /// POST /api/config {sessionId, model, thinking}. `thinking` is the enum rawValue
    /// ("off"/"low"/"medium"/"high"). Mirrors the send/POST pattern of the other intents.
    func updateConfig(model: String, thinking: String) {
        queue.async {
            self.model = model
            self.thinking = thinking
            // Only push to the backend if we have a live session; otherwise the values are
            // already staged for the next /api/session create.
            guard self.sessionId != nil else { return }
            self.postJSON(path: "/api/config", body: ["model": model, "thinking": thinking])
        }
    }

    /// Map each ClientMsg to its HTTP request. All POSTs use dataTask (NOT WebSocketTask).
    /// .auth / .ping are no-ops: auth IS the session POST, and polling IS the heartbeat.
    private func sendRaw(_ msg: ClientMsg) {
        switch msg {
        case .auth, .ping:
            return   // no-op on HTTP transport.

        case let .prompt(text):
            postJSON(path: "/api/prompt", body: ["text": text])

        case let .permissionDecision(requestId, decision, note, remember):
            var body: [String: Any] = ["requestId": requestId, "decision": decision.rawValue]
            if let note { body["note"] = note }
            if let remember { body["remember"] = remember }
            postJSON(path: "/api/decision", body: body)

        case let .setMode(mode):
            postJSON(path: "/api/mode", body: ["mode": mode.rawValue])

        case .cancel:
            postJSON(path: "/api/cancel", body: [:])

        case let .selectProject(projectId):
            postJSON(path: "/api/select-project", body: ["projectId": projectId])

        case .listProjects:
            getProjects()
        }
    }

    /// POST {base}{path} with {sessionId, ...body}. Best-effort; failures surface via the poll
    /// loop / connection state, mirroring the old fire-and-forget WS send.
    private func postJSON(path: String, body: [String: Any]) {
        guard let sessionId else {
            NSLog("[PINCH-HTTP] %@ skipped — no session yet", path)
            return
        }
        guard let url = makeAPIURL(path: path) else { return }
        var payload = body
        payload["sessionId"] = sessionId
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let task = session.dataTask(with: req) { _, response, error in
            if let nsErr = error as NSError? {
                NSLog("[PINCH-HTTP] %@ error domain=%@ code=%ld", path, nsErr.domain, nsErr.code)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                NSLog("[PINCH-HTTP] %@ → %ld", path, http.statusCode)
            }
        }
        task.resume()
    }

    /// GET {base}/api/projects → {projects:[ProjectRef]} → deliver onMessage(.projects(list)).
    private func getProjects() {
        guard let url = makeAPIURL(path: "/api/projects") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let nsErr = error as NSError? {
                NSLog("[PINCH-HTTP] projects error domain=%@ code=%ld", nsErr.domain, nsErr.code)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                NSLog("[PINCH-HTTP] projects → %ld", code)
                return
            }
            // Decode {projects:[ProjectRef]} and deliver as a synthesized .projects message,
            // reusing the ServerMsg decoder so the Store path is identical to the WS flow.
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["projects"] else {
                NSLog("[PINCH-HTTP] projects → undecodable body")
                return
            }
            let wrapper: [String: Any] = ["type": "projects", "projects": list]
            guard let wrapped = try? JSONSerialization.data(withJSONObject: wrapper),
                  let msg = try? JSONDecoder().decode(ServerMsg.self, from: wrapped) else {
                NSLog("[PINCH-HTTP] projects → could not synthesize message")
                return
            }
            Task { @MainActor [weak self] in self?.onMessage?(msg) }
        }
        task.resume()
    }

    // MARK: - URL construction

    /// Build {base}{path} from the user's serverURL, forcing scheme https and stripping any
    /// trailing /ws (the user's setting is `wss://host` → use `https://host`).
    private func makeAPIComponents(path: String) -> URLComponents? {
        guard var comps = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        // Force https regardless of ws/wss/http/https in the stored setting.
        comps.scheme = "https"
        // Start from the base host path, stripping a trailing slash and any /ws suffix.
        var base = comps.path
        if base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/ws") { base.removeLast(3) }
        comps.path = base + path
        comps.query = nil
        return comps
    }

    private func makeAPIURL(path: String) -> URL? {
        makeAPIComponents(path: path)?.url
    }

    // MARK: - Reconnect (exponential backoff + jitter)

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let attempt = reconnectAttempt

        // If we keep failing before ever reaching `ready`, it's almost certainly auth / version
        // / bad host. Stop retrying and tell the user, rather than hammering forever.
        if !everReachedReady && attempt > maxColdAttempts {
            shouldStayConnected = false
            emit(.failed("Can't reach server: \(lastErrorMessage)"))
            return
        }

        emit(.reconnecting(attempt: attempt))

        // base 0.8s, doubling, capped at 30s, plus up to ±30% jitter.
        let capped = min(pow(2.0, Double(attempt - 1)) * 0.8, 30.0)
        let jitter = Double.random(in: 0.7...1.3)
        let delay = capped * jitter

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.queue.async {
                guard self.shouldStayConnected else { return }
                self.openSession()
            }
        }
    }

    /// Emit a connection state to the UI, COALESCING identical consecutive states so the pill
    /// never re-renders (or flaps) on a state that didn't actually change. Assumes it runs on
    /// `queue` (all callers do), where `lastEmittedState` is confined.
    private func emit(_ state: ConnectionState) {
        if lastEmittedState == state { return }
        lastEmittedState = state
        Task { @MainActor [weak self] in self?.onState?(state) }
    }

    // MARK: - Resume persistence

    /// Persist (or clear) the resume id so it survives app relaunch. UserDefaults is plenty here
    /// — the session id is an opaque server handle, not a secret, and the bearer token (the
    /// actual credential) still gates every resume.
    private static func persistResume(_ id: String?, key: String) {
        if let id {
            UserDefaults.standard.set(id, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Network-path diagnostics

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            Self.logPath(path, label: "path update")
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
        Self.logPath(monitor.currentPath, label: "startup snapshot")
    }

    private static func logPath(_ path: NWPath, label: String) {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        var types: [String] = []
        if path.usesInterfaceType(.wifi) { types.append("wifi") }
        if path.usesInterfaceType(.cellular) { types.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { types.append("wiredEthernet") }
        if path.usesInterfaceType(.other) { types.append("other") }
        if path.usesInterfaceType(.loopback) { types.append("loopback") }
        let typeList = types.isEmpty ? "none" : types.joined(separator: ",")
        let ifaceNames = path.availableInterfaces.map { "\($0.name)(\($0.type))" }
        let ifaceList = ifaceNames.isEmpty ? "none" : ifaceNames.joined(separator: ",")
        NSLog("[PINCH-NET] %@ status=%@ usesTypes=[%@] expensive=%@ constrained=%@ availableInterfaces=[%@]",
              label,
              status,
              typeList,
              path.isExpensive ? "true" : "false",
              path.isConstrained ? "true" : "false",
              ifaceList)
    }
}

// MARK: - URLSessionTaskDelegate (connectivity diagnostic only)

extension WSClient: URLSessionTaskDelegate {
    // Fires only when waitsForConnectivity is true AND the OS has no usable path yet, so it's
    // parking the task until one appears. Seeing this (instead of an instant -1009) confirms the
    // config is working and the watch genuinely has no path for this app at request time.
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        NSLog("[PINCH-NET] task waiting for connectivity (no usable path yet) for %@",
              task.originalRequest?.url?.absoluteString ?? "?")
    }
}
