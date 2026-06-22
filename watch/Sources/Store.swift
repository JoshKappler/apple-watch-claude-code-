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

// MARK: - Transcript model

/// One renderable item in the scrolling transcript.
enum TranscriptItem: Identifiable {
    case user(id: UUID = UUID(), text: String)
    case assistant(id: UUID = UUID(), text: String)
    case tool(ServerMsg.ToolUse, ok: Bool?)   // ok flips when the matching tool_result lands
    case notice(id: UUID = UUID(), text: String, warn: Bool)

    var id: String {
        switch self {
        case let .user(id, _): return "u-\(id)"
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

    // Conversation.
    @Published var transcript: [TranscriptItem] = []
    @Published var thinkingActive = false          // subtle "extended thinking" indicator

    // The message being composed (dictation appends here; the composer + caret editor bind to it).
    @Published var draft = ""

    // Permission gate.
    @Published var pendingPermission: ServerMsg.PermissionRequest?

    // Mode + projects.
    @Published var mode: PermissionMode = .default
    @Published var projects: [ProjectRef] = []
    @Published var projectsLoading = false
    private var wantProjects = false   // re-request once `ready` if asked before the socket was up

    // Sub-systems (exposed so views can bind: mic state, speaking pulse, etc.).
    let speaker = Speaker()
    let shake = ShakeDetector()
    let push = PushRegistration()

    private var ws: WSClient?

    // Streaming assembly: deltas accumulate into the last assistant bubble until a full
    // assistant_message (or turn boundary) replaces/finalizes it.
    private var streamingAssistantIndex: Int?

    // Settings (mirrored from @AppStorage by the views via configure()).
    private var serverURLString = ""
    private var token = ""

    init() {
        shake.onShake = { [weak self] in self?.handleShake() }
        push.onReengage = { [weak self] in self?.onActive() }
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
            client.onState = { [weak self] state in self?.connection = state }
            client.onMessage = { [weak self] msg in self?.handle(msg) }
            self.ws = client
        }
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

    // MARK: - Intents (called by views)

    /// SEND — the double-tap / Send-button action. Adds the user bubble and ships a prompt.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .ready = connection else { return }
        transcript.append(.user(text: trimmed))
        ws?.send(.prompt(text: trimmed))
        Haptics.click()
    }

    /// Fold a dictation result into the draft (used by the mic button and the Action button).
    func appendDictated(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = draft.isEmpty ? t : draft + " " + t
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
        guard case .ready = connection else { return }
        ws?.send(.cancel)
        speaker.stop()
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
        Haptics.click()
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
            mode = ready.mode
            currentProject = ready.project
            models = ready.models ?? []
            if ready.resumed {
                appendNotice("Reconnected — session resumed.", warn: false)
            }
            if wantProjects {
                wantProjects = false
                ws?.send(.listProjects)
            }

        case let .projects(list):
            projects = list
            projectsLoading = false
            wantProjects = false

        case let .status(state, _):
            agentState = state
            thinkingActive = (state == .thinking)
            if state == .error { Haptics.failure() }

        case let .assistantDelta(text):
            appendAssistantDelta(text)

        case let .assistantMessage(text):
            finalizeAssistant(text)
            speaker.speak(text)            // speak aloud + haptic (per spec)

        case .thinkingDelta:
            thinkingActive = true          // subtle indicator only; we don't show raw thinking text

        case let .toolUse(use):
            transcript.append(.tool(use, ok: nil))

        case let .toolResult(result):
            updateToolResult(id: result.id, ok: result.ok)

        case let .permissionRequest(req):
            pendingPermission = req
            agentState = .waiting_permission
            Haptics.permissionNeeded()

        case let .modeChanged(newMode):
            mode = newMode

        case let .turnComplete(stopReason):
            streamingAssistantIndex = nil
            thinkingActive = false
            if stopReason == .end_turn { Haptics.success() }
            if stopReason == .error { Haptics.failure() }

        case let .notice(level, message):
            appendNotice(message, warn: level == .warn)

        case let .error(message, fatal):
            appendNotice(message, warn: true)
            Haptics.failure()
            if fatal { connection = .failed(message) }

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

    private func finalizeAssistant(_ text: String) {
        if let idx = streamingAssistantIndex,
           idx < transcript.count,
           case let .assistant(id, _) = transcript[idx] {
            // Replace the accumulated deltas with the authoritative full block.
            transcript[idx] = .assistant(id: id, text: text)
        } else {
            transcript.append(.assistant(text: text))
        }
        streamingAssistantIndex = nil
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
        transcript.append(.notice(text: text, warn: warn))
    }

    func clearTranscript() {
        transcript.removeAll()
        streamingAssistantIndex = nil
    }
}
