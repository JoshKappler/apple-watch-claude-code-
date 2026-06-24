//
//  Store.swift
//  PinchStore — the single source of truth the whole UI binds to.
//
//  Owns: the WSClient (connection), Speaker (TTS+haptic), ShakeDetector (cancel).
//  Voice input uses Apple's system dictation (presented via Dictation.present) — there is no
//  in-app SpeechRecognizer because SFSpeechRecognizer does not function on watchOS.
//  Holds connection state, the transcript, the current permission
//  request, mode, and projects. Exposes intent methods the views call: send / approve /
//  decline / setMode / cancel / selectProject.
//
//  Connection is foreground-only (watchOS reclaims the socket on suspend), so the views
//  call onActive()/onBackground() from scenePhase.
//

import Foundation
import SwiftUI

// MARK: - Model + thinking-level config (state contract for the picker UI)

/// A selectable Claude model. `id` is the API model id sent to the backend; `label` is the
/// short name shown in the picker.
struct PinchModel: Identifiable, Hashable {
    let id: String      // API model id
    let label: String
}

/// Reasoning EFFORT — the same scale the Claude Code terminal CLI exposes (the user-facing label
/// is "Effort"). `rawValue` is what we send to the backend, which maps each level to an
/// extended-reasoning budget. Ordered low → max.
enum ThinkingLevel: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }
}

/// One agent in the multi-agent switcher. An agent is a SEPARATE backend session on the Mac (all
/// spawned at the project root); the watch drives exactly one at a time — the "focused" one.
/// `id` is a local slot id ("default" for the original agent, else a UUID); the transport keys each
/// agent's resume/cursor/outbox by it. `label` is what the switcher shows — the focused folder (or
/// root) name, updated whenever the agent's project is known. Codable so the list survives relaunch.
struct AgentSlot: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    /// Folder/root basename this agent is scoped to — drives the switcher's per-project SECTION
    /// header and grouping. Set once the agent's project is known (`ready`/select); nil until then.
    var projectName: String? = nil
    /// Full project root path — the stable GROUP KEY, so two different dirs that share a basename
    /// don't merge and the group survives a relabel. nil until known.
    var projectPath: String? = nil
    /// A 1-3 word summary of what this agent is doing, derived WATCH-SIDE from its FIRST prompt (no
    /// backend, no LLM). nil until the first prompt is sent; once set it's the row's primary label.
    var title: String? = nil
}

/// A single switcher row, with its display label already resolved (title, else an "Agent N"
/// enumerator). Precomputed in the store so the SwiftUI list stays a trivial ForEach.
struct AgentRowItem: Identifiable {
    let id: String      // the agent slot id
    let label: String
}

/// One project's worth of agents — a labeled section in the switcher, which is how the projects get
/// their separators. `id` is the stable group key (project path, else name).
struct AgentGroup: Identifiable {
    let id: String
    let name: String
    let rows: [AgentRowItem]
}

/// The contract names the store type `Store`; the concrete ObservableObject is `PinchStore`.
/// This alias lets the UI agent's `Store.availableModels` resolve while every existing
/// `@EnvironmentObject … PinchStore` binding keeps working unchanged.
typealias Store = PinchStore

// MARK: - Transcript model

/// One renderable item in the scrolling transcript.
enum TranscriptItem: Identifiable {
    /// Delivery state of a user prompt, shown so a message is never SILENTLY lost: it reads
    /// "sending" until the backend confirms its POST (2xx), then "sent". `failed` is a terminal
    /// failure (e.g. auth). Drives the small status glyph on the user bubble.
    enum Delivery: Sendable { case sending, sent, failed }

    case user(id: UUID = UUID(), text: String, delivery: Delivery = .sent)
    case assistant(id: UUID = UUID(), text: String)
    case tool(ServerMsg.ToolUse, ok: Bool?)   // ok flips when the matching tool_result lands
    case notice(id: UUID = UUID(), text: String, warn: Bool)

    var id: String {
        switch self {
        case let .user(id, _, _): return "u-\(id)"
        case let .assistant(id, _): return "a-\(id)"
        case let .tool(use, _): return "t-\(use.id)"
        case let .notice(id, _, _): return "n-\(id)"
        }
    }
}

@MainActor
final class PinchStore: ObservableObject {

    // Connection.
    @Published var connection: ConnectionState = .disconnected
    @Published var agentState: AgentState = .idle

    // Session info from `ready`.
    @Published var sessionId: String?
    @Published var currentProject: ProjectRef?
    @Published var models: [String] = []

    // Context-window occupancy for the usage ring around the gear icon. Set by `context`
    // frames the backend emits each turn from the model's token usage; reset on a fresh session.
    @Published var contextUsed = 0
    @Published var contextWindow = 0

    /// 0…1 fill for the ring. 0 when there's no reading yet (the ring stays hidden).
    var contextFraction: Double {
        guard contextWindow > 0 else { return 0 }
        return min(1, max(0, Double(contextUsed) / Double(contextWindow)))
    }

    // Conversation.
    @Published var transcript: [TranscriptItem] = []
    @Published var thinkingActive = false          // subtle "extended thinking" indicator
    @Published var turnStartedAt: Date?            // when the current thinking/tool turn began (live timer)

    // The message being composed (dictation appends here; the composer + inline editor bind to it).
    @Published var draft = ""

    // Caret position (character offset into `draft`) lifted into the store so the MIC button can
    // INSERT dictated text at the caret when the input is expanded/editing. InlineDraftEditor
    // reads/writes this so it stays in sync with what the crown is moving.
    @Published var caretIndex = 0

    // Crown ownership for the draft box. When true, the draft box is EXPANDED and owns the
    // Digital Crown (moving the caret in EDIT mode, or scrolling the draft text in SCROLL mode);
    // the transcript must yield crown focus. When false, the crown scrolls the chat transcript.
    // TranscriptView reads this to decide whether its ScrollView should hold crown focus.
    @Published var inputOwnsCrown = false

    // Chrome collapse: a vertical swipe hides the composer (draft box + edit/mic) so the
    // transcript text fills the whole screen — max reading space on a tiny display. The
    // Send button stays mounted even collapsed so the hardware double-pinch still works.
    // Scrolling is the crown's job, so swallowing vertical swipes for this is safe.
    @Published var chromeCollapsed = false

    // Permission gate.
    @Published var pendingPermission: ServerMsg.PermissionRequest?

    // Mode + projects. The permission mode is WATCH-OWNED and persisted (UserDefaults), so a choice
    // like "Skip permissions" survives app relaunches and fresh sessions instead of resetting to
    // .default every cold start. restoreSettings() loads it in init; the .ready handler re-asserts
    // it onto the backend session. didSet mirrors the model/thinking/tts persistence pattern.
    @Published var mode: PermissionMode = .default {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.mode)
        }
    }
    @Published var projects: [ProjectRef] = []
    @Published var projectsLoading = false
    private var wantProjects = false   // re-request once `ready` if asked before the socket was up

    // Multi-agent switcher. `agents` is the list shown in the upper-left hub; `focusedAgentId` is
    // the one the transport is actively driving (its slot keys the resume/cursor/outbox in WSClient).
    // Both persist so the set of running agents survives an app relaunch. The transcript of an agent
    // you switch AWAY from is parked in `transcriptStash` (in-memory) so returning restores its
    // conversation; the backend session keeps running regardless, so context is never lost.
    @Published var agents: [AgentSlot] = [AgentSlot(id: "default", label: "Agent 1")]
    @Published var focusedAgentId = "default"
    private var transcriptStash: [String: [TranscriptItem]] = [:]

    // Sub-systems (exposed so views can bind: mic state, speaking pulse, etc.).
    let speaker = Speaker()
    let shake = ShakeDetector()
    let push = PushRegistration()

    private var ws: WSClient?

    // Streaming assembly: deltas accumulate into the last assistant bubble until a full
    // assistant_message (or turn boundary) replaces/finalizes it.
    private var streamingAssistantIndex: Int?

    // TTS dedup: the bubble ids we've already spoken, so an assistant message is read aloud
    // at most once even if its event is somehow re-delivered. Cleared with the transcript.
    private var spokenAssistantIds: Set<UUID> = []

    // True once we've buzzed a real reply in the CURRENT turn (Haptics.response). Lets the
    // end-of-turn handler skip its own success() buzz when a reply already announced itself,
    // so a normal Q&A turn gives ONE clear "answered" buzz instead of two stacked taps. Reset
    // at each turn start.
    private var didBuzzReplyThisTurn = false

    // Settings (mirrored from @AppStorage by the views via configure()).
    private var serverURLString = ""
    private var token = ""

    // MARK: - Model / thinking / TTS settings (picker UI binds to these directly)

    /// The models the picker offers. Static so the UI can read `Store.availableModels`.
    static let availableModels: [PinchModel] = [
        PinchModel(id: "claude-opus-4-8", label: "Opus 4.8"),
        PinchModel(id: "claude-sonnet-4-6", label: "Sonnet 4.6"),
        PinchModel(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"),
        PinchModel(id: "claude-fable-5", label: "Fable 5"),
    ]

    // UserDefaults keys for the persisted settings.
    private enum SettingsKey {
        static let model = "pinch.model"
        static let thinking = "pinch.thinking"
        static let tts = "pinch.tts"
        static let mode = "pinch.mode"
        static let agents = "pinch.agents"
        static let focusedAgent = "pinch.focusedAgent"
    }

    /// Selected API model id. Persisted; pushed to the backend on change when connected.
    @Published var selectedModel: String = "claude-opus-4-8" {
        didSet {
            guard oldValue != selectedModel else { return }
            UserDefaults.standard.set(selectedModel, forKey: SettingsKey.model)
            pushConfig()
        }
    }

    /// Extended-thinking level. Persisted; pushed to the backend on change when connected.
    @Published var thinkingLevel: ThinkingLevel = .medium {
        didSet {
            guard oldValue != thinkingLevel else { return }
            UserDefaults.standard.set(thinkingLevel.rawValue, forKey: SettingsKey.thinking)
            pushConfig()
        }
    }

    /// Master TTS on/off. Persisted; gates ALL speech via the Speaker. Defaults OFF —
    /// the watch speaker is usually silent without AirPods anyway, and the haptic still
    /// fires, so audible readback is opt-in.
    @Published var ttsEnabled: Bool = false {
        didSet {
            guard oldValue != ttsEnabled else { return }
            UserDefaults.standard.set(ttsEnabled, forKey: SettingsKey.tts)
            speaker.setEnabled(ttsEnabled)
        }
    }

    init() {
        shake.onShake = { [weak self] in self?.handleShake() }
        push.onReengage = { [weak self] in self?.onActive() }
        restoreSettings()
    }

    /// Load the three persisted settings from UserDefaults (with the contract defaults) and
    /// apply them. Done in init BEFORE any connection so the first /api/session carries the
    /// restored model/thinking and the Speaker starts in the right enabled state.
    private func restoreSettings() {
        let d = UserDefaults.standard
        // Register defaults so a first launch reads the contract defaults rather than nil/false.
        d.register(defaults: [
            SettingsKey.model: "claude-opus-4-8",
            SettingsKey.thinking: ThinkingLevel.medium.rawValue,
            SettingsKey.tts: false,
            SettingsKey.mode: PermissionMode.default.rawValue,
        ])
        // These assignments DO fire didSet, but that's harmless during init: the persist just
        // re-writes the same stored value, and pushConfig() is a no-op while `ws` is still nil
        // (no session to push to yet — the values ride the first /api/session instead).
        selectedModel = d.string(forKey: SettingsKey.model) ?? "claude-opus-4-8"
        thinkingLevel = ThinkingLevel(rawValue: d.string(forKey: SettingsKey.thinking) ?? "medium") ?? .medium
        ttsEnabled = d.bool(forKey: SettingsKey.tts)
        speaker.setEnabled(ttsEnabled)
        // Restore the permission mode so the remembered posture (e.g. Skip permissions) is in place
        // before the first connect; the .ready handler re-asserts it onto the session.
        mode = PermissionMode(rawValue: d.string(forKey: SettingsKey.mode) ?? PermissionMode.default.rawValue) ?? .default

        // Restore the multi-agent registry. A first launch (or a decode miss) seeds the single
        // "default" agent so the app always has exactly one focused agent to drive.
        if let data = d.data(forKey: SettingsKey.agents),
           let saved = try? JSONDecoder().decode([AgentSlot].self, from: data), !saved.isEmpty {
            // Back-compat: pre-grouping slots only had `label` (which WAS the project name), so seed
            // `projectName` from it — except the "Agent N" placeholder — so they group correctly on
            // upgrade instead of waiting to be focused. A real `ready` overwrites it precisely.
            agents = saved.map { slot in
                guard slot.projectName == nil, !slot.label.isEmpty, !slot.label.hasPrefix("Agent ")
                else { return slot }
                var s = slot
                s.projectName = slot.label
                return s
            }
        } else {
            agents = [AgentSlot(id: "default", label: "Agent 1")]
        }
        focusedAgentId = d.string(forKey: SettingsKey.focusedAgent) ?? "default"
        if !agents.contains(where: { $0.id == focusedAgentId }) {
            focusedAgentId = agents.first?.id ?? "default"
        }
    }

    /// Persist the agent registry + which one is focused, so the running set survives relaunch.
    private func persistAgents() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(agents) { d.set(data, forKey: SettingsKey.agents) }
        d.set(focusedAgentId, forKey: SettingsKey.focusedAgent)
    }

    /// Rename the focused agent's row to the project it's currently scoped to (the folder hint, or
    /// the root). Called when `ready`/`select_project` tells us the agent's project, so the switcher
    /// shows "jobhunt" instead of a generic "Agent 2".
    private func updateFocusedLabel() {
        guard let project = currentProject,
              let idx = agents.firstIndex(where: { $0.id == focusedAgentId }) else { return }
        var slot = agents[idx]
        var changed = false
        // `label` stays the bare project name (legacy fallback + accessibility); `projectName`/`Path`
        // feed the switcher's grouping + section header. The TITLE (what it's doing) is set separately
        // from the first prompt and is what the row actually shows.
        if slot.label != project.name { slot.label = project.name; changed = true }
        if slot.projectName != project.name { slot.projectName = project.name; changed = true }
        if slot.projectPath != project.path { slot.projectPath = project.path; changed = true }
        if changed {
            agents[idx] = slot
            persistAgents()
        }
    }

    /// Group the running agents by project (first-appearance order preserved), so the switcher shows
    /// a labeled section per project — that's what puts a separator between different projects.
    var agentGroups: [AgentGroup] {
        var order: [String] = []
        var byKey: [String: [AgentSlot]] = [:]
        var nameByKey: [String: String] = [:]
        for a in agents {
            let key = a.projectPath ?? a.projectName ?? "—"
            if byKey[key] == nil { order.append(key); byKey[key] = []; nameByKey[key] = a.projectName ?? "Agent" }
            byKey[key]?.append(a)
        }
        return order.map { key in
            // Resolve each row's label here: the agent's auto-title, else an "Agent N" enumerator that
            // counts only UNtitled agents so two same-folder agents are never identical.
            var untitled = 0
            let rows = (byKey[key] ?? []).map { a -> AgentRowItem in
                if let t = a.title, !t.isEmpty { return AgentRowItem(id: a.id, label: t) }
                untitled += 1
                return AgentRowItem(id: a.id, label: "Agent \(untitled)")
            }
            return AgentGroup(id: key, name: nameByKey[key] ?? "Agent", rows: rows)
        }
    }

    /// Derive a short (≤3 word) title from an agent's FIRST prompt — watch-side, no LLM. Strips leading
    /// filler/stop words and keeps the first few content words so the switcher reads like a task
    /// ("Add delete button") instead of the folder name. Best-effort: empty in → empty out.
    func makeAgentTitle(from prompt: String) -> String {
        let stop: Set<String> = [
            "the", "a", "an", "to", "of", "for", "and", "or", "but", "in", "on", "at", "is", "it",
            "this", "that", "please", "can", "you", "could", "would", "i", "we", "my", "me", "want",
            "need", "hey", "ok", "okay", "so", "just", "like", "up", "with", "about", "let", "lets", "then",
        ]
        let tokens = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let content = tokens.filter { !stop.contains($0) && $0.count > 1 }
        let picked = Array((content.isEmpty ? tokens : content).prefix(3))
        guard let first = picked.first else { return "" }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + picked.dropFirst()).joined(separator: " ")
    }

    /// Apply a backend-generated (Haiku) title to the FOCUSED agent's slot, upgrading the instant
    /// watch-derived one. Trimmed; empty titles are ignored.
    private func applyAgentTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              let idx = agents.firstIndex(where: { $0.id == focusedAgentId }) else { return }
        if agents[idx].title != t {
            agents[idx].title = t
            persistAgents()
        }
    }

    /// Push the current model + thinking to the backend, but only when a session is live.
    /// (When disconnected the values are staged in WSClient and ride the next /api/session.)
    private func pushConfig() {
        guard ws != nil else { return }
        ws?.updateConfig(model: selectedModel, thinking: thinkingLevel.rawValue)
    }

    // MARK: - Configuration

    /// Push the latest settings in. Returns true if we have enough to connect.
    @discardableResult
    func configure(serverURL: String, token: String, speakerMuted: Bool) -> Bool {
        self.serverURLString = serverURL
        self.token = token
        speaker.setMuted(speakerMuted)

        guard let url = URL(string: serverURL), !token.isEmpty else { return false }

        if let ws {
            ws.configure(serverURL: url, token: token)
        } else {
            let client = WSClient(serverURL: url, token: token, deviceId: DeviceID.current)
            client.onState = { [weak self] state in
                guard let self else { return }
                // Edge-detect the transition INTO .ready and drain the outbox. This is the ONLY
                // hook that catches the soft-recovery .ready (emitted via onState, never as an
                // onMessage(.ready) frame), so a queued prompt always re-sends the instant the
                // path recovers — not just on a full session re-open.
                let wasReady: Bool
                if case .ready = self.connection { wasReady = true } else { wasReady = false }
                self.connection = state
                if case .ready = state, !wasReady { self.ws?.drainOutbox() }
            }
            client.onMessage = { [weak self] msg in self?.handle(msg) }
            client.onDelivery = { [weak self] id, delivered in
                self?.markDelivery(id: id, delivered: delivered)
            }
            self.ws = client
            // Target the restored focused agent so the first connect resumes IT, not the default slot.
            if focusedAgentId != "default" { client.setActiveSlot(focusedAgentId) }
        }
        // Seed the client with the restored model/thinking so the FIRST /api/session body
        // carries them (no-op'd network push since no session exists yet — it just stages them).
        ws?.updateConfig(model: selectedModel, thinking: thinkingLevel.rawValue)
        push.configure(serverURL: url, token: token)
        return true
    }

    var canConnect: Bool {
        URL(string: serverURLString) != nil && !token.isEmpty
    }

    // MARK: - Lifecycle (scenePhase)

    func onActive() {
        guard canConnect else { return }
        shake.start()
        ws?.connect()
        Task {
            await push.register()
        }
    }

    func onBackground() {
        // Foreground-only socket — drop it cleanly so we reconnect+resume on return.
        shake.stop()
        speaker.stop()
        ws?.disconnect()
    }

    func reconnect() {
        ws?.reconnectNow()
    }

    /// Restart the backend PROCESS on the Mac — the long-running `node dist/index.js` tether that
    /// runs the Claude Agent SDK and streams to this watch. Rebuilds dist/ and relaunches it so
    /// backend code you changed from the watch goes live (a rebuild alone isn't enough; the running
    /// process holds the old code). The connection drops briefly; the watch re-creates and REVIVES
    /// the same session afterward, so the conversation/context is preserved. See WSClient.restartBackend.
    func restartBackend() {
        appendNotice("Restarting backend… reconnecting shortly.", warn: false)
        ws?.restartBackend()
    }

    /// Clear context — wipe the on-watch transcript AND start a fresh Claude session
    /// (drops the resumed context so the next turn starts with an empty conversation).
    func clearContext() {
        Haptics.click()
        // Stop any in-flight turn on the OLD session first — otherwise its agent keeps
        // running server-side after we've moved on.
        ws?.send(.cancel)
        clearTranscript()
        // Reset the live-turn state so the "thinking… 10m" indicator + timer stop the instant
        // you clear, instead of ticking against a turn that no longer exists.
        resetTurnState()
        ws?.newSession()
    }

    /// Compact context — ask the backend to summarize the running conversation IN PLACE so the
    /// context window frees up, WITHOUT starting a new session (unlike clearContext). The on-watch
    /// transcript is kept; the backend streams back a "Compacting…" then "Context compacted" notice
    /// and a refreshed usage ring when it finishes. Safe to tap mid-conversation — it queues behind
    /// any in-flight turn.
    func compactContext() {
        ws?.send(.compact)
        Haptics.click()
    }

    /// Clear all "a turn is in progress" state so the thinking indicator + live elapsed timer
    /// stop immediately. Used by cancel() (manual stop) and by clearContext() — anything that
    /// should halt the current turn from the watch's side without waiting on a backend frame.
    private func resetTurnState() {
        agentState = .idle
        thinkingActive = false
        turnStartedAt = nil
        streamingAssistantIndex = nil
        pendingPermission = nil
    }

    // MARK: - Intents (called by views)

    /// SEND — the double-tap / Send-button action. Adds the user bubble and ships a prompt.
    /// If the socket isn't `.ready` yet (foreground socket often reconnects at the exact
    /// moment you tap), the prompt is QUEUED and auto-flushed when `ready` next lands — so the
    /// button never feels dead. Either way the user bubble appears immediately and the draft
    /// clears. Whether to flush against the live socket is decided in one place to avoid
    /// double-sending.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = UUID()
        // Title the focused agent from its FIRST prompt (once), so the switcher names it after what
        // it's doing instead of the bare folder. Only fills an empty title — later turns don't rename.
        if let idx = agents.firstIndex(where: { $0.id == focusedAgentId }),
           agents[idx].title?.isEmpty ?? true {
            let t = makeAgentTitle(from: trimmed)
            if !t.isEmpty { agents[idx].title = t; persistAgents() }
        }
        transcript.append(.user(id: id, text: trimmed, delivery: .sending))
        draft = ""
        caretIndex = 0
        // If we sent from the EXPANDED input (the draft box filling the screen), collapse it
        // back to one line so the transcript reclaims the screen and the reply is immediately
        // visible — you're done composing the moment you send.
        inputOwnsCrown = false
        // Delivery is the transport's job now: the prompt goes into a DURABLE, persisted outbox
        // and is retried until the backend confirms it (2xx). We do NOT gate on the (possibly
        // stale) connection enum — that optimistic check, plus fire-and-forget POSTs, is exactly
        // how messages were silently lost on a flaky LTE handoff. The bubble flips sending→sent
        // via onDelivery; the backend dedups by id so retries never double-run a turn.
        ws?.enqueuePrompt(id: id.uuidString, text: trimmed)
        Haptics.click()
    }

    /// Flip a user bubble's delivery state when the transport confirms (or terminally fails) its
    /// POST. Matched by the bubble's UUID, which is also the prompt's outbox id.
    private func markDelivery(id: String, delivered: Bool) {
        guard let uuid = UUID(uuidString: id),
              let idx = transcript.firstIndex(where: {
                  if case let .user(bid, _, _) = $0 { return bid == uuid }
                  return false
              }) else { return }
        if case let .user(bid, text, _) = transcript[idx] {
            transcript[idx] = .user(id: bid, text: text, delivery: delivered ? .sent : .failed)
        }
    }

    /// Fold a dictation result into the draft (used by the mic button and the Action button).
    func appendDictated(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = draft.isEmpty ? t : draft + " " + t
        caretIndex = draft.count
        Haptics.click()
    }

    /// Insert a dictation result at the current caret (used by the mic button while the input is
    /// expanded/editing) and advance the caret past it. Falls back to appendDictated when the
    /// box is collapsed (no meaningful caret on screen).
    func dictateAtCaret(_ raw: String) {
        guard inputOwnsCrown else { appendDictated(raw); return }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let c = min(max(caretIndex, 0), draft.count)
        let idx = draft.index(draft.startIndex, offsetBy: c)
        // Space-pad so inserted speech doesn't fuse onto neighbouring words.
        let needLeadSpace = c > 0 && !draft[draft.index(before: idx)].isWhitespace
        let needTrailSpace = idx < draft.endIndex && !draft[idx].isWhitespace
        let insert = (needLeadSpace ? " " : "") + t + (needTrailSpace ? " " : "")
        draft.insert(contentsOf: insert, at: idx)
        caretIndex = c + insert.count
        Haptics.click()
    }

    func approve(remember: Bool = false) {
        guard let req = pendingPermission else { return }
        ws?.send(.permissionDecision(requestId: req.requestId, decision: .allow, note: nil, remember: remember))
        pendingPermission = nil
        Haptics.success()
    }

    func decline() {
        guard let req = pendingPermission else { return }
        ws?.send(.permissionDecision(requestId: req.requestId, decision: .deny, note: nil, remember: nil))
        pendingPermission = nil
        Haptics.failure()
    }

    func setMode(_ newMode: PermissionMode) {
        ws?.send(.setMode(mode: newMode))
        // Optimistic; server confirms with mode_changed.
        mode = newMode
    }

    func cancel() {
        // Best-effort stop to the backend (no-ops cleanly if there's no live session). We do NOT
        // gate on .ready: a turn that's "thinking forever" is exactly the case where the path may
        // be flaky, and you must still be able to bail out.
        ws?.send(.cancel)
        speaker.stop()
        // Optimistically clear the working state NOW so the thinking indicator + elapsed timer
        // stop the instant you hit stop — even if the backend is wedged and never sends idle.
        resetTurnState()
        Haptics.cancelled()
    }

    func listProjects() {
        projectsLoading = true
        if case .ready = connection {
            ws?.send(.listProjects)
        } else {
            wantProjects = true   // socket not ready yet — fire as soon as `ready` lands
        }
    }

    func selectProject(_ project: ProjectRef) {
        ws?.send(.selectProject(projectId: project.id))
        currentProject = project
        updateFocusedLabel()   // relabel the focused agent's row to the folder it's now scoped to
        Haptics.click()
    }

    // MARK: - Multi-agent intents (the upper-left agent switcher)

    /// Spawn a NEW agent — a fresh backend session at the project root — and focus it. The current
    /// agent's transcript is parked so you can switch back to it; the new agent starts on a clean
    /// screen. Its backend session is created lazily by the transport's next /api/session.
    func createAgent() {
        transcriptStash[focusedAgentId] = transcript
        let id = UUID().uuidString
        agents.append(AgentSlot(id: id, label: "Agent \(agents.count + 1)"))
        focusedAgentId = id
        persistAgents()
        prepareForAgentSwitch(restoring: nil)
        ws?.switchAgent(slot: id, resume: false)
        Haptics.click()
    }

    /// Focus an existing agent: park the current transcript, restore the target's, and re-point the
    /// transport at the target's (still-running) backend session so prompts now drive it.
    func focusAgent(_ id: String) {
        guard id != focusedAgentId else { return }
        transcriptStash[focusedAgentId] = transcript
        focusedAgentId = id
        persistAgents()
        prepareForAgentSwitch(restoring: transcriptStash[id])
        ws?.switchAgent(slot: id, resume: true)
        Haptics.click()
    }

    /// Remove an agent and END its backend session. Never removes the last one. If it's the focused
    /// agent, a neighbor is focused FIRST (so the active session swaps cleanly) and only then is the
    /// old one torn down.
    func removeAgent(_ id: String) {
        guard agents.count > 1 else { return }
        if id == focusedAgentId {
            let next = agents.first(where: { $0.id != id })?.id ?? "default"
            focusAgent(next)
        }
        agents.removeAll { $0.id == id }
        transcriptStash[id] = nil
        persistAgents()
        ws?.endAgent(slot: id)
        Haptics.click()
    }

    /// Shared on-screen reset for an agent switch: swap the transcript and clear the live-turn /
    /// context state so the incoming agent doesn't inherit the outgoing one's thinking indicator,
    /// permission gate, or usage ring. The real session state lives server-side; `ready` repopulates.
    private func prepareForAgentSwitch(restoring transcript: [TranscriptItem]?) {
        self.transcript = transcript ?? []
        spokenAssistantIds.removeAll()
        resetTurnState()
        contextUsed = 0
        contextWindow = 0
        currentProject = nil
    }

    private func handleShake() {
        // Only meaningful while a turn is in flight.
        guard agentState == .thinking || agentState == .running_tool || agentState == .waiting_permission else { return }
        cancel()
    }

    // MARK: - Inbound message handling

    private func handle(_ msg: ServerMsg) {
        switch msg {
        case let .ready(ready):
            sessionId = ready.sessionId
            // Permission mode is watch-owned + persisted: re-assert our remembered mode onto the
            // (new or resumed) session instead of adopting the backend's default. This is what makes
            // "Skip permissions" stick across relaunches and fresh sessions. No-op when they match;
            // the backend confirms with mode_changed either way.
            if mode != ready.mode {
                ws?.send(.setMode(mode: mode))
            }
            currentProject = ready.project
            updateFocusedLabel()   // name the focused agent's row after the project it landed on
            models = ready.models ?? []
            if ready.resumed {
                appendNotice("Reconnected — session resumed.", warn: false)
            } else {
                // Brand-new session → empty context until the first turn reports usage.
                contextUsed = 0
                contextWindow = 0
            }
            if wantProjects {
                wantProjects = false
                ws?.send(.listProjects)
            }
            // Outbox prompts are drained by WSClient on session-open and by the onState .ready
            // edge (covers soft recovery) — no flush needed here.

        case let .projects(list):
            projects = list
            projectsLoading = false
            wantProjects = false

        case let .status(state, _):
            agentState = state
            thinkingActive = (state == .thinking)
            // Start the turn timer the moment work begins; clear it the moment we go idle.
            if (state == .thinking || state == .running_tool), turnStartedAt == nil {
                turnStartedAt = Date()
                didBuzzReplyThisTurn = false   // new turn — arm the reply buzz again
            } else if state == .idle {
                turnStartedAt = nil
            }
            if state == .error { Haptics.failure() }

        case let .assistantDelta(text):
            appendAssistantDelta(text)

        case let .assistantMessage(text):
            let bubbleId = finalizeAssistant(text)
            // Handle each assistant message AT MOST ONCE. The transport already dedupes events
            // by index (so a re-poll can't re-deliver this), but we ALSO guard here by the
            // bubble's id so nothing — replay, resume replay, or a backend double-send — can
            // double-fire. Buzz on EVERY reply (Haptics.response) independent of TTS, so you
            // feel that Claude answered even with audio readback off (the common case); the
            // Speaker handles AUDIO only and no-ops when ttsEnabled is false.
            if !spokenAssistantIds.contains(bubbleId) {
                spokenAssistantIds.insert(bubbleId)
                Haptics.response()
                didBuzzReplyThisTurn = true
                speaker.speak(text)        // speak aloud (only if enabled + a route exists)
            }

        case .thinkingDelta:
            thinkingActive = true          // subtle indicator only; we don't show raw thinking text

        case let .toolUse(use):
            transcript.append(.tool(use, ok: nil))

        case let .toolResult(result):
            updateToolResult(id: result.id, ok: result.ok)

        case let .permissionRequest(req):
            pendingPermission = req
            agentState = .waiting_permission
            // Drop any stale expanded-input crown ownership so the transcript (not a half-open
            // composer) holds the crown while the permission bar is up — the chat stays scrollable.
            inputOwnsCrown = false
            Haptics.permissionNeeded()

        case let .modeChanged(newMode):
            mode = newMode

        case let .turnComplete(stopReason):
            streamingAssistantIndex = nil
            thinkingActive = false
            turnStartedAt = nil
            // A clean turn that already buzzed its reply doesn't need a second tap; only buzz
            // success here for turns that ended WITHOUT a reply (e.g. tool-only work).
            if stopReason == .end_turn, !didBuzzReplyThisTurn { Haptics.success() }
            if stopReason == .error { Haptics.failure() }

        case let .notice(level, message):
            appendNotice(message, warn: level == .warn)

        case let .error(message, fatal):
            appendNotice(message, warn: true)
            Haptics.failure()
            if fatal { connection = .failed(message) }

        case let .context(used, window):
            contextUsed = used
            contextWindow = window

        case let .agentTitle(title):
            // Backend-generated 1-3 word title for the FOCUSED agent (it arrives on that agent's own
            // event stream). Upgrade the instant watch-derived title with the cleaner Haiku one.
            applyAgentTitle(title)

        case .pong:
            break   // heartbeat ack; nothing to do.

        case .unknown:
            break   // forward-compat: ignore.
        }
    }

    // MARK: - Transcript assembly helpers

    private func appendAssistantDelta(_ text: String) {
        if let idx = streamingAssistantIndex,
           idx < transcript.count,
           case let .assistant(id, existing) = transcript[idx] {
            transcript[idx] = .assistant(id: id, text: existing + text)
        } else {
            transcript.append(.assistant(text: text))
            streamingAssistantIndex = transcript.count - 1
        }
    }

    /// Finalize the current assistant bubble with the authoritative full text. Returns the
    /// bubble's stable id so the caller can dedupe TTS (speak each bubble at most once).
    @discardableResult
    private func finalizeAssistant(_ text: String) -> UUID {
        if let idx = streamingAssistantIndex,
           idx < transcript.count,
           case let .assistant(id, _) = transcript[idx] {
            // Replace the accumulated deltas with the authoritative full block.
            transcript[idx] = .assistant(id: id, text: text)
            streamingAssistantIndex = nil
            return id
        } else {
            let id = UUID()
            transcript.append(.assistant(id: id, text: text))
            streamingAssistantIndex = nil
            return id
        }
    }

    private func updateToolResult(id: String, ok: Bool) {
        guard let idx = transcript.firstIndex(where: {
            if case let .tool(use, _) = $0 { return use.id == id }
            return false
        }) else { return }
        if case let .tool(use, _) = transcript[idx] {
            transcript[idx] = .tool(use, ok: ok)
        }
    }

    private func appendNotice(_ text: String, warn: Bool) {
        // Collapse consecutive identical notices (e.g. a flaky watch reconnecting over and
        // over would otherwise stack "Reconnected — session resumed." lines forever).
        if case let .notice(_, lastText, lastWarn)? = transcript.last,
           lastText == text, lastWarn == warn {
            return
        }
        transcript.append(.notice(text: text, warn: warn))
    }

    func clearTranscript() {
        transcript.removeAll()
        streamingAssistantIndex = nil
        spokenAssistantIds.removeAll()
    }
}
