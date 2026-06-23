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

/// One undelivered prompt in the durable outbox (see WSClient.outbox).
private struct OutboxItem: Codable, Sendable {
    let id: String
    let text: String
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
    /// Per-prompt delivery confirmation: (promptId, delivered). The Store flips the user bubble
    /// from "sending" to "sent" once its /api/prompt POST returns 2xx.
    var onDelivery: (@MainActor (String, Bool) -> Void)?

    private var session: URLSession!
    /// A SEPARATE, fail-fast URLSession for SENDS (prompts). waitsForConnectivity=false + short
    /// timeouts so a prompt on a dying path ERRORS quickly (then the outbox retries) instead of
    /// parking until the app suspends and the request dies in flight — the reported LTE bug.
    private var sendSession: URLSession!

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

    /// The ACTIVE agent slot. Each agent the watch runs is an isolated backend session with its OWN
    /// persisted resume id, poll cursor, and outbox — all keyed by (deviceId, slot). The original
    /// single-agent state lives under the legacy "default" slot (no suffix) so an app already in the
    /// field keeps resuming its one session unchanged after this update. Set via setActiveSlot /
    /// switchAgent; everything that persists below resolves its key through this.
    private var agentSlot = "default"
    private func slotSuffix(_ slot: String) -> String { slot == "default" ? "" : ".\(slot)" }

    /// The agent session to resume on the next /api/session. PERSISTED to UserDefaults so it
    /// survives the watchOS app being suspended-then-killed (the common case: the screen sleeps,
    /// watchOS reclaims us AND frequently terminates the process, so the next launch builds a
    /// fresh client). Without persistence, every relaunch sent a nil resumeSessionId → the
    /// backend spun a brand-new agent session and the whole conversation + context was lost.
    /// Keyed per (server, deviceId, slot) so switching servers/agents doesn't cross wires.
    private var resumeSessionId: String? {
        didSet { Self.persistResume(resumeSessionId, key: resumeKey) }
    }
    private var resumeKey: String { "pinch.resumeSessionId.\(deviceId)\(slotSuffix(agentSlot))" }
    /// Persisted poll cursor for the resume session, so a relaunch continues where it left off
    /// instead of replaying the whole event log (the duplicate-bubble bug). Paired with
    /// `resumeSessionId` — both are keyed per (device, slot) and written together on a live session.
    private var resumeCursorKey: String { "pinch.resumeCursor.\(deviceId)\(slotSuffix(agentSlot))" }

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
    private let pollFailureThreshold = 2
    /// The last state we actually emitted, so we can COALESCE: identical states are never
    /// re-emitted (stops the pill flapping connected/reconnecting/connected on every tick).
    private var lastEmittedState: ConnectionState?
    /// True once the poll loop has degraded to "reconnecting" so we know to announce the
    /// recovery (a single .ready emission) when polls start succeeding again.
    private var pollDegraded = false

    /// Durable prompt outbox — the SINGLE source of truth for "messages not yet confirmed
    /// delivered." Every prompt is written here BEFORE any network attempt and removed ONLY on a
    /// 2xx from /api/prompt, so a prompt can never be silently lost (parked POST, dropped on
    /// suspend, fired on a stale "connected" state). Persisted per-device so it survives relaunch.
    private var outbox: [OutboxItem] = []
    /// Prompt ids with a POST currently in flight, so a redrain doesn't double-fire the same id
    /// while one attempt is pending. (Backend dedups by promptId, so a stray double-send is safe.)
    private var inflight: Set<String> = []
    /// At most one pending retry timer at a time (a transient send failure self-heals).
    private var outboxRetryTask: Task<Void, Never>?
    private var outboxKey: String { "pinch.outbox.\(deviceId)\(slotSuffix(agentSlot))" }

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
        // Cap the WHOLE resource load (INCLUDING time parked waiting-for-connectivity) so a poll
        // can never wedge the single-flight loop forever on a dead interface: it errors, the loop
        // ticks, the failure debounce trips, and we redrive. Default is 7 DAYS — long enough for a
        // parked poll to silently stall the loop until the app is force-quit.
        config.timeoutIntervalForResource = 25
        // Skip ngrok's free-tier browser interstitial. The watch's URLSession isn't browser-like so
        // it usually passes anyway, but this header makes it deterministic. Harmless elsewhere — a
        // direct backend or a Cloudflare tunnel just ignores an unknown header.
        config.httpAdditionalHeaders = ["ngrok-skip-browser-warning": "true"]
        // No custom delegate queue needed for dataTask completions; default session is fine,
        // but we keep a delegate for the waiting-for-connectivity diagnostic.
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)

        // SEND session: fail FAST. A prompt sent during the Wi-Fi/phone-relay → standalone-LTE
        // handoff must NOT park (parking + app-suspend = the prompt dies in flight — the reported
        // bug). Short timeouts surface the failure quickly so the durable outbox retries on a live
        // path. No delegate; completions are hopped onto `queue` explicitly.
        let sendConfig = URLSessionConfiguration.default
        sendConfig.waitsForConnectivity = false
        sendConfig.allowsCellularAccess = true
        sendConfig.allowsExpensiveNetworkAccess = true
        sendConfig.allowsConstrainedNetworkAccess = true
        sendConfig.timeoutIntervalForRequest = 12
        sendConfig.timeoutIntervalForResource = 12
        sendConfig.httpAdditionalHeaders = ["ngrok-skip-browser-warning": "true"]
        self.sendSession = URLSession(configuration: sendConfig)

        // Restore prompts that weren't confirmed delivered before the app was last killed, so they
        // re-send on the next live session instead of being lost with the process.
        if let data = UserDefaults.standard.data(forKey: "pinch.outbox.\(deviceId)"),
           let saved = try? JSONDecoder().decode([OutboxItem].self, from: data) {
            self.outbox = Array(saved.suffix(50))   // enforce the cap on restore too (keep newest)
        }
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
                Self.persistCursor(0, key: self.resumeCursorKey)
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

    /// Clear context: forget the resumed session and start a brand-new Claude conversation.
    /// Nulling `resumeSessionId` (its didSet also clears UserDefaults, so it won't resurrect on
    /// relaunch) makes the next /api/session create a FRESH context; openSession then resets
    /// pollCursor/appliedHighWater to 0 so the new session's events flow from the start.
    func newSession() {
        queue.async {
            self.shouldStayConnected = true
            self.everReachedReady = false
            self.resumeSessionId = nil
            self.teardown(notify: false)
            self.reconnectAttempt = 0
            self.openSession()
        }
    }

    /// Point this client at agent `slot` WITHOUT opening a connection yet — used at startup so the
    /// first connect targets the restored focused agent instead of the default slot. Loads the
    /// slot's persisted resume id + outbox; the next connect()/openSession resumes its session.
    func setActiveSlot(_ slot: String) {
        queue.async { self.setActiveSlotLocked(slot, resume: true) }
    }

    /// Switch the ACTIVE agent to `slot` and re-open against it now. Each agent is an isolated
    /// backend session (its own resume id / cursor / outbox, keyed by slot). With `resume` true we
    /// re-attach the slot's existing session (the watch was driving it before); with `resume` false
    /// we forget any prior session for the slot so /api/session spins up a FRESH agent at the
    /// project root. The other agents' backend sessions keep running server-side and buffer their
    /// events until we poll them again.
    func switchAgent(slot: String, resume: Bool) {
        queue.async {
            self.setActiveSlotLocked(slot, resume: resume)
            self.shouldStayConnected = true
            self.everReachedReady = false   // fresh cold-attempt budget for the new slot
            self.reconnectAttempt = 0
            self.teardown(notify: false)
            self.openSession()
        }
    }

    /// Permanently end the agent in `slot`: tell the backend to tear its session down, then forget
    /// the slot's persisted resume id / cursor / outbox. Safe for a slot that was never opened (no
    /// persisted id → just clears local keys). Does NOT touch the active slot — the Store focuses a
    /// different agent first when removing the one in focus.
    func endAgent(slot: String) {
        queue.async {
            let suffix = slot == "default" ? "" : ".\(slot)"
            let resumeKey = "pinch.resumeSessionId.\(self.deviceId)\(suffix)"
            let cursorKey = "pinch.resumeCursor.\(self.deviceId)\(suffix)"
            let outboxKey = "pinch.outbox.\(self.deviceId)\(suffix)"
            if let sid = UserDefaults.standard.string(forKey: resumeKey) {
                self.postEndSession(sessionId: sid)
            }
            UserDefaults.standard.removeObject(forKey: resumeKey)
            UserDefaults.standard.removeObject(forKey: cursorKey)
            UserDefaults.standard.removeObject(forKey: outboxKey)
        }
    }

    /// Repoint all per-slot persistence at `slot` and load its durable state. Runs on `queue`.
    /// Order matters: persist the CURRENT slot's outbox before we move the keys, then adopt the new
    /// slot's outbox/resume so nothing leaks across agents.
    private func setActiveSlotLocked(_ slot: String, resume: Bool) {
        self.persistOutbox()                 // save the outgoing slot's outbox under its current key
        self.agentSlot = slot                // from here every per-slot key resolves to `slot`
        self.outbox = Self.loadOutbox(key: self.outboxKey)
        self.inflight.removeAll()
        if resume {
            // Re-adopt the slot's stored session (didSet re-persists the same value harmlessly).
            self.resumeSessionId = UserDefaults.standard.string(forKey: self.resumeKey)
        } else {
            // Fresh agent: drop any prior session + cursor so openSession creates a new one at root.
            self.resumeSessionId = nil
            Self.persistCursor(0, key: self.resumeCursorKey)
        }
        self.pollCursor = 0
        self.appliedHighWater = 0
    }

    /// Fire-and-forget POST /api/end-session for an explicit (possibly non-active) session id.
    private func postEndSession(sessionId: String) {
        guard let url = makeAPIURL(path: "/api/end-session"),
              let data = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// Ask the backend to restart its OWN process (rebuild dist/ + relaunch `node dist/index.js`)
    /// so backend code changes go live. HTTP-only operational action — there is no ServerMsg/poll
    /// frame for it. The backend rebuilds while the old process keeps serving, then kills itself and
    /// a fresh process binds the same port; our next poll 410s and re-creates/revives the SAME
    /// session, so the conversation is preserved (the existing backend-restart path).
    func restartBackend() {
        queue.async { self.postJSON(path: "/api/restart", body: [:]) }
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
                self.failAllQueued()
                self.emit(.failed("Auth failed — check your token."))
                return
            }
            if code == 426 {
                NSLog("[PINCH-HTTP] session → 426 (protocol mismatch)")
                self.shouldStayConnected = false
                self.failAllQueued()
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
            // `resetCursor` is set by the backend when it REVIVED this session from its durable
            // record (process had restarted/swept): the rebuilt event log starts back at index 0,
            // so our saved cursor is stale and would make us swallow every new event until the
            // backend's index caught up. Honor it by zeroing the cursor even though resumed==true.
            let resetCursor = (json["resetCursor"] as? Bool) ?? false
            NSLog("[PINCH-HTTP] session OK sessionId=%@ resumed=%@ resetCursor=%@",
                  sid, resumed ? "true" : "false", resetCursor ? "true" : "false")

            // Success → adopt the session, persist it as resume, reset backoff + debounce.
            self.sessionId = sid
            self.resumeSessionId = sid
            // CURSOR HANDLING — the fix for duplicate bubbles on reconnect.
            //   • resumed + log intact (resetCursor=false): the backend kept the SAME session +
            //     event log, which still holds everything we already showed. Starting the cursor at
            //     0 would re-deliver the whole history → every assistant bubble appears twice. So
            //     CONTINUE from the last cursor we persisted (survives app relaunch); we only pull
            //     strictly-new events. No replay → no duplicates, and your own prompt bubbles (which
            //     never live in the server log) aren't clobbered by a from-zero rebuild.
            //   • fresh OR revived-with-empty-log: start at 0 and reset the mark. A fresh session's
            //     log is empty; a revived session's log was just rebuilt empty — both index from 0.
            if resumed && !resetCursor {
                let saved = Self.loadCursor(key: self.resumeCursorKey)
                self.pollCursor = saved
                self.appliedHighWater = saved
            } else {
                self.pollCursor = 0
                self.appliedHighWater = 0
                Self.persistCursor(0, key: self.resumeCursorKey)
            }
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
            self.drainLocked()   // ship any outbox prompts against the new/resumed session
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
        inflight.removeAll()   // a recreate re-drains the outbox from scratch on the new session
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
            // session_gone — the backend lost our session. Single-flight the recreate (the guard
            // means a racing prompt-410 won't double-create), and KEEP resumeSessionId so the
            // recreate can revive the SAME conversation instead of starting a fresh, context-losing
            // session.
            NSLog("[PINCH-HTTP] poll → 410 session_gone, re-creating session")
            queue.async {
                guard self.sessionId != nil, self.shouldStayConnected else { return }
                self.sessionId = nil
                self.openSession()   // also cancels this poll task via teardown()
            }
            return
        }
        if code == 401 || code == 403 {
            NSLog("[PINCH-HTTP] poll → %ld (auth)", code)
            queue.async {
                self.shouldStayConnected = false
                self.failAllQueued()
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

        // Ring-buffer gap: the backend trimmed events our cursor never reached, so some updates
        // are gone. Surface a one-shot notice (delivered OUTSIDE the indexed event loop so it
        // doesn't perturb the high-water/appliedHighWater math). Fires once — the cursor advances
        // to the high-water below, so the next poll won't be behind the trim point.
        if (json["gap"] as? Bool) == true {
            await MainActor.run { [weak self] in
                self?.onMessage?(.notice(level: .warn, message: "Some updates were missed while offline."))
            }
        }

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
        // `index >= highWater`, i.e. only events newer than everything we've now seen. Persist
        // it (only when it actually advances) so a reconnect/relaunch RESUMES here instead of
        // replaying the whole log — this is what stops the duplicate bubbles.
        if let highWater {
            queue.async {
                if highWater > self.pollCursor {
                    self.pollCursor = highWater
                    Self.persistCursor(self.pollCursor, key: self.resumeCursorKey)
                }
            }
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

        case let .prompt(id, text):
            // Prompts are durable now — enqueue to the outbox + drain (confirmed delivery), never
            // fire-and-forget. (The Store calls enqueuePrompt directly; this keeps send() correct.)
            enqueueLocked(id: id, text: text)

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

    // MARK: - Prompt outbox (durable, confirmed delivery)

    /// Queue a prompt for guaranteed-at-least-once delivery. Called by the Store on send.
    func enqueuePrompt(id: String, text: String) {
        queue.async { self.enqueueLocked(id: id, text: text) }
    }

    /// Public drain trigger. The Store calls this on the connection→.ready EDGE, which is the ONLY
    /// place the soft-recovery .ready surfaces (notePollSuccess emits it via onState, never as an
    /// onMessage(.ready) frame) — so without this an outbox drain would miss every soft recovery.
    func drainOutbox() {
        queue.async { self.drainLocked() }
    }

    private func enqueueLocked(id: String, text: String) {
        outbox.append(OutboxItem(id: id, text: text))
        // Hard cap so an extended outage can't grow the outbox without bound. If we overflow,
        // DEAD-LETTER the oldest QUEUED prompt — flip its bubble to "Not sent" so a dropped message
        // is visible, never silently gone. Skip the in-flight head: removing the item whose POST is
        // running would spawn a concurrent send and flicker its bubble failed↔sent. (At most one
        // item is ever in flight, so a droppable one always exists once count > 50.)
        while outbox.count > 50 {
            guard let dropIdx = outbox.firstIndex(where: { !inflight.contains($0.id) }) else { break }
            let dropped = outbox.remove(at: dropIdx)
            reportDelivery(dropped.id, delivered: false)
        }
        persistOutbox()
        drainLocked()
    }

    /// Terminal failure (auth / give-up): mark every queued prompt "Not sent" and clear the
    /// outbox so nothing is left spinning on "Sending…" and nothing silently re-POSTs on the next
    /// launch against credentials the user was already told failed.
    private func failAllQueued() {
        for item in outbox { reportDelivery(item.id, delivered: false) }
        outbox.removeAll()
        inflight.removeAll()
        persistOutbox()
    }

    /// Send the OLDEST queued prompt — strictly ONE at a time (FIFO). Order matters: the backend
    /// turns the first-arriving prompt into the turn and treats later ones as follow-ups, so
    /// parallel POSTs would reorder messages composed offline. Each success chains to the next via
    /// the completion handler; transient failures re-drive via scheduleOutboxRetry. Single-flight
    /// also means at most one 410 can fire at a time, so a sweep can't spawn N session re-creates.
    private func drainLocked() {
        guard sessionId != nil, inflight.isEmpty, let item = outbox.first else { return }
        inflight.insert(item.id)
        sendPromptPOST(item)
    }

    /// POST one outbox item via the fail-fast send session. Removes it from the outbox ONLY on a
    /// 2xx; on transient failure it stays queued and retries; on 410 it recreates the session and
    /// the prompt re-drains against the new one; on auth failure we surface .failed.
    private func sendPromptPOST(_ item: OutboxItem) {
        guard let sessionId, let url = makeAPIURL(path: "/api/prompt"),
              let data = try? JSONSerialization.data(withJSONObject: [
                  "sessionId": sessionId, "promptId": item.id, "text": item.text,
              ]) else {
            inflight.remove(item.id)
            scheduleOutboxRetry()   // don't strand the queue; re-drive shortly (openSession also redrains)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = sendSession.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.inflight.remove(item.id)
                if let nsErr = error as NSError? {
                    NSLog("[PINCH-HTTP] /api/prompt error id=%@ domain=%@ code=%ld desc=%@",
                          item.id, nsErr.domain, nsErr.code, nsErr.localizedDescription)
                    self.notePollFailure()       // the path is sick — degrade the pill
                    self.scheduleOutboxRetry()   // ...and try again shortly (stays queued)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200, 202:
                    self.removeFromOutbox(item.id)
                    self.reportDelivery(item.id, delivered: true)
                    self.drainLocked()          // chain: send the next queued prompt in order
                case 410:
                    // session_gone. Single-flight the recreate (the guard means a racing poll-410
                    // or a follow-up send-410 no-ops once sessionId is nil). KEEP resumeSessionId so
                    // openSession can revive the SAME conversation rather than starting fresh; the
                    // prompt stays queued and re-drains on the new session.
                    guard self.sessionId != nil else { return }
                    NSLog("[PINCH-HTTP] /api/prompt → 410; recreating session, prompt stays queued")
                    self.sessionId = nil
                    if self.shouldStayConnected { self.openSession() }
                case 401, 403:
                    NSLog("[PINCH-HTTP] /api/prompt → %ld (auth)", code)
                    self.shouldStayConnected = false
                    self.failAllQueued()        // terminal — nothing will retry; surface "Not sent"
                    self.teardown(notify: false)
                    self.emit(.failed("Auth failed — check your token."))
                default:
                    NSLog("[PINCH-HTTP] /api/prompt → %ld id=%@", code, item.id)
                    self.notePollFailure()
                    self.scheduleOutboxRetry()
                }
            }
        }
        task.resume()
    }

    private func removeFromOutbox(_ id: String) {
        outbox.removeAll { $0.id == id }
        persistOutbox()
    }

    private func persistOutbox() {
        if let data = try? JSONEncoder().encode(outbox) {
            UserDefaults.standard.set(data, forKey: outboxKey)
        }
    }

    /// Load + cap an outbox persisted under `key` (used when switching the active agent slot).
    private static func loadOutbox(key: String) -> [OutboxItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([OutboxItem].self, from: data) else { return [] }
        return Array(saved.suffix(50))
    }

    /// One pending retry at a time; a transient send failure self-heals after a short delay even
    /// without another trigger (poll-success recovery and reconnect also redrain).
    private func scheduleOutboxRetry() {
        guard !outbox.isEmpty, shouldStayConnected, outboxRetryTask == nil else { return }
        outboxRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.queue.async {
                self?.outboxRetryTask = nil
                self?.drainLocked()
            }
        }
    }

    private func reportDelivery(_ id: String, delivered: Bool) {
        Task { @MainActor [weak self] in self?.onDelivery?(id, delivered) }
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
            failAllQueued()   // we're giving up — don't leave prompts spinning on "Sending…"
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

    /// Persist / restore the poll cursor for the resume session (see resumeCursorKey).
    private static func persistCursor(_ cursor: Int, key: String) {
        UserDefaults.standard.set(cursor, forKey: key)
    }
    private static func loadCursor(key: String) -> Int {
        max(0, UserDefaults.standard.integer(forKey: key))
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
