//
//  Protocol.swift
//  Pinch wire protocol v1 — Swift mirror of packages/protocol/src/index.ts.
//
//  Every frame is a JSON object with a `type` discriminator. Outbound (client→server)
//  frames are plain Encodable structs wrapped in `ClientMsg`. Inbound (server→client)
//  frames are decoded by peeking at `type` first, then decoding the concrete payload —
//  unknown types decode to `.unknown` and are ignored (forward-compat, per spec).
//
//  Keep this in sync with PROTOCOL.md by hand.
//

import Foundation

enum Pinch {
    static let protocolVersion = 1

    // WS close codes Pinch uses (see protocol/src/index.ts → CloseCode).
    enum CloseCode {
        static let authFailed = 4401
        static let protocolMismatch = 4426
        static let internalError = 4500
    }
}

// MARK: - Shared enums

/// Permission posture. `bypassPermissions` === "dangerously skip permissions".
enum PermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default`
    case acceptEdits
    case plan
    case bypassPermissions

    var id: String { rawValue }

    /// Human label for the UI.
    var label: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .bypassPermissions: return "Skip permissions"
        }
    }

    /// One-line description shown in the mode menu.
    var blurb: String {
        switch self {
        case .default: return "Every change asks first."
        case .acceptEdits: return "Edits auto-approve; commands still ask."
        case .plan: return "Read-only planning. No changes."
        case .bypassPermissions: return "Dangerously skips all approvals."
        }
    }

    /// SF Symbol for the mode chip.
    var symbol: String {
        switch self {
        case .default: return "hand.raised"
        case .acceptEdits: return "pencil.circle"
        case .plan: return "list.bullet.clipboard"
        case .bypassPermissions: return "exclamationmark.triangle.fill"
        }
    }
}

/// Glanceable agent state; drives the UI badge + haptics.
enum AgentState: String, Codable, Sendable {
    case idle
    case thinking
    case running_tool
    case waiting_permission
    case error
}

enum Risk: String, Codable, Sendable {
    case low, medium, high
}

enum PermissionKind: String, Codable, Sendable {
    case command, edit, write, other
}

struct ProjectRef: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var path: String?
    var branch: String?
    var dirty: Bool?
}

// MARK: - Client → Server

/// A type-erased outbound frame. Each case encodes to the exact JSON the backend expects.
/// We hand-roll `encode` so the discriminator and payload land in one flat object.
enum ClientMsg: Encodable, Sendable {
    case auth(token: String, deviceId: String?, resumeSessionId: String?)
    case prompt(id: String, text: String)
    case permissionDecision(requestId: String, decision: Decision, note: String?, remember: Bool?)
    case setMode(mode: PermissionMode)
    case cancel
    case compact
    case listProjects
    case selectProject(projectId: String)
    case ping(t: Double?)

    enum Decision: String, Encodable, Sendable { case allow, deny }

    private enum CodingKeys: String, CodingKey {
        case type, token, protocolVersion, deviceId, resumeSessionId
        case text, promptId, requestId, decision, note, remember, mode, projectId, t
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .auth(token, deviceId, resumeSessionId):
            try c.encode("auth", forKey: .type)
            try c.encode(token, forKey: .token)
            try c.encode(Pinch.protocolVersion, forKey: .protocolVersion)
            try c.encodeIfPresent(deviceId, forKey: .deviceId)
            try c.encodeIfPresent(resumeSessionId, forKey: .resumeSessionId)

        case let .prompt(id, text):
            try c.encode("prompt", forKey: .type)
            try c.encode(id, forKey: .promptId)
            try c.encode(text, forKey: .text)

        case let .permissionDecision(requestId, decision, note, remember):
            try c.encode("permission_decision", forKey: .type)
            try c.encode(requestId, forKey: .requestId)
            try c.encode(decision, forKey: .decision)
            try c.encodeIfPresent(note, forKey: .note)
            try c.encodeIfPresent(remember, forKey: .remember)

        case let .setMode(mode):
            try c.encode("set_mode", forKey: .type)
            try c.encode(mode, forKey: .mode)

        case .cancel:
            try c.encode("cancel", forKey: .type)

        case .compact:
            try c.encode("compact", forKey: .type)

        case .listProjects:
            try c.encode("list_projects", forKey: .type)

        case let .selectProject(projectId):
            try c.encode("select_project", forKey: .type)
            try c.encode(projectId, forKey: .projectId)

        case let .ping(t):
            try c.encode("ping", forKey: .type)
            try c.encodeIfPresent(t, forKey: .t)
        }
    }

    /// Serialize to a UTF-8 JSON string ready for the socket.
    func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Server → Client

/// A decoded inbound frame. Unknown `type`s become `.unknown(type)` and are ignored upstream.
enum ServerMsg: Sendable {
    case ready(Ready)
    case projects([ProjectRef])
    case status(state: AgentState, detail: String?)
    case assistantDelta(text: String)
    case assistantMessage(text: String)
    case thinkingDelta(text: String)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case permissionRequest(PermissionRequest)
    case modeChanged(mode: PermissionMode)
    case turnComplete(stopReason: StopReason)
    case notice(level: NoticeLevel, message: String)
    case error(message: String, fatal: Bool)
    case context(used: Int, window: Int)
    /// A 1-3 word title for the focused agent, generated backend-side from its first prompt. The
    /// store applies it to the focused slot, upgrading the instant watch-derived title.
    case agentTitle(title: String)
    case pong(t: Double?)
    case unknown(type: String)

    struct Ready: Sendable {
        let sessionId: String
        let mode: PermissionMode
        let project: ProjectRef?
        let models: [String]?
        let resumed: Bool
    }

    struct ToolUse: Identifiable, Sendable {
        let id: String
        let name: String
        let title: String
        let subtitle: String?
        // We deliberately do NOT decode `input` (z.unknown) — it's free-form and unused on the watch.
    }

    struct ToolResult: Identifiable, Sendable {
        let id: String
        let ok: Bool
        let summary: String?
    }

    struct PermissionRequest: Identifiable, Sendable, Equatable {
        let requestId: String
        let tool: String
        let title: String
        let detail: String?
        let risk: Risk
        let kind: PermissionKind
        let diff: String?
        let command: String?
        var id: String { requestId }
    }

    enum StopReason: String, Codable, Sendable {
        case end_turn, cancelled, error, max_turns
    }

    enum NoticeLevel: String, Codable, Sendable {
        case info, warn
    }
}

extension ServerMsg: Decodable {
    private enum K: String, CodingKey {
        case type, sessionId, mode, project, models, resumed
        case projects, state, detail, text
        case id, name, title, subtitle, ok, summary
        case requestId, tool, risk, kind, diff, command
        case stopReason, level, message, fatal, t
        case used, window
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "ready":
            self = .ready(.init(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                mode: try c.decode(PermissionMode.self, forKey: .mode),
                project: try c.decodeIfPresent(ProjectRef.self, forKey: .project),
                models: try c.decodeIfPresent([String].self, forKey: .models),
                resumed: try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
            ))

        case "projects":
            self = .projects(try c.decode([ProjectRef].self, forKey: .projects))

        case "status":
            self = .status(
                state: try c.decode(AgentState.self, forKey: .state),
                detail: try c.decodeIfPresent(String.self, forKey: .detail)
            )

        case "assistant_delta":
            self = .assistantDelta(text: try c.decode(String.self, forKey: .text))

        case "assistant_message":
            self = .assistantMessage(text: try c.decode(String.self, forKey: .text))

        case "thinking_delta":
            self = .thinkingDelta(text: try c.decode(String.self, forKey: .text))

        case "tool_use":
            self = .toolUse(.init(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                title: try c.decode(String.self, forKey: .title),
                subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle)
            ))

        case "tool_result":
            self = .toolResult(.init(
                id: try c.decode(String.self, forKey: .id),
                ok: try c.decode(Bool.self, forKey: .ok),
                summary: try c.decodeIfPresent(String.self, forKey: .summary)
            ))

        case "permission_request":
            self = .permissionRequest(.init(
                requestId: try c.decode(String.self, forKey: .requestId),
                tool: try c.decode(String.self, forKey: .tool),
                title: try c.decode(String.self, forKey: .title),
                detail: try c.decodeIfPresent(String.self, forKey: .detail),
                risk: try c.decode(Risk.self, forKey: .risk),
                kind: try c.decode(PermissionKind.self, forKey: .kind),
                diff: try c.decodeIfPresent(String.self, forKey: .diff),
                command: try c.decodeIfPresent(String.self, forKey: .command)
            ))

        case "mode_changed":
            self = .modeChanged(mode: try c.decode(PermissionMode.self, forKey: .mode))

        case "turn_complete":
            self = .turnComplete(stopReason: try c.decode(StopReason.self, forKey: .stopReason))

        case "notice":
            self = .notice(
                level: try c.decode(NoticeLevel.self, forKey: .level),
                message: try c.decode(String.self, forKey: .message)
            )

        case "error":
            self = .error(
                message: try c.decode(String.self, forKey: .message),
                fatal: try c.decodeIfPresent(Bool.self, forKey: .fatal) ?? false
            )

        case "context":
            self = .context(
                used: try c.decode(Int.self, forKey: .used),
                window: try c.decode(Int.self, forKey: .window)
            )

        case "agent_title":
            self = .agentTitle(title: try c.decode(String.self, forKey: .title))

        case "pong":
            self = .pong(t: try c.decodeIfPresent(Double.self, forKey: .t))

        default:
            // Forward-compat: ignore unknown frames rather than failing the receive loop.
            self = .unknown(type: type)
        }
    }
}
