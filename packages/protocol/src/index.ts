/**
 * Pinch wire protocol v1 — the contract between the watch client and the backend.
 *
 * Human-readable spec: ../PROTOCOL.md
 * The Swift watch app mirrors these shapes as Codable structs (kept in sync by hand).
 *
 * We validate every inbound frame against these Zod schemas at the WS boundary, so a
 * malformed or hostile frame is rejected before it reaches the agent. Outbound frames
 * are constructed through the `srv` helpers so they always match the schema.
 */
import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

/** Permission posture. `bypassPermissions` === "dangerously skip permissions". */
export const PermissionMode = z.enum([
  "default",
  "acceptEdits",
  "plan",
  "bypassPermissions",
]);
export type PermissionMode = z.infer<typeof PermissionMode>;

export const AgentState = z.enum([
  "idle",
  "thinking",
  "running_tool",
  "waiting_permission",
  "error",
]);
export type AgentState = z.infer<typeof AgentState>;

export const Risk = z.enum(["low", "medium", "high"]);
export type Risk = z.infer<typeof Risk>;

export const PermissionKind = z.enum(["command", "edit", "write", "other"]);
export type PermissionKind = z.infer<typeof PermissionKind>;

const ProjectRef = z.object({
  id: z.string(),
  name: z.string(),
  path: z.string().optional(),
  branch: z.string().optional(),
  dirty: z.boolean().optional(),
});
export type ProjectRef = z.infer<typeof ProjectRef>;

/* ───────────────────────────── Client → Server ───────────────────────────── */

export const AuthMsg = z.object({
  type: z.literal("auth"),
  token: z.string().min(1),
  protocolVersion: z.number().int(),
  deviceId: z.string().optional(),
  resumeSessionId: z.string().optional(),
});

export const PromptMsg = z.object({
  type: z.literal("prompt"),
  text: z.string().min(1).max(8000),
});

export const PermissionDecisionMsg = z.object({
  type: z.literal("permission_decision"),
  requestId: z.string(),
  decision: z.enum(["allow", "deny"]),
  note: z.string().max(2000).optional(),
  remember: z.boolean().optional(),
});

export const SetModeMsg = z.object({
  type: z.literal("set_mode"),
  mode: PermissionMode,
});

export const CancelMsg = z.object({ type: z.literal("cancel") });

export const ListProjectsMsg = z.object({ type: z.literal("list_projects") });

export const SelectProjectMsg = z.object({
  type: z.literal("select_project"),
  projectId: z.string(),
});

export const PingMsg = z.object({
  type: z.literal("ping"),
  t: z.number().optional(),
});

export const ClientMsg = z.discriminatedUnion("type", [
  AuthMsg,
  PromptMsg,
  PermissionDecisionMsg,
  SetModeMsg,
  CancelMsg,
  ListProjectsMsg,
  SelectProjectMsg,
  PingMsg,
]);
export type ClientMsg = z.infer<typeof ClientMsg>;

/* ───────────────────────────── Server → Client ───────────────────────────── */

export const ReadyMsg = z.object({
  type: z.literal("ready"),
  protocolVersion: z.number().int(),
  sessionId: z.string(),
  mode: PermissionMode,
  project: ProjectRef.optional(),
  models: z.array(z.string()).optional(),
  resumed: z.boolean().optional(),
});

export const ProjectsMsg = z.object({
  type: z.literal("projects"),
  projects: z.array(ProjectRef),
});

export const StatusMsg = z.object({
  type: z.literal("status"),
  state: AgentState,
  detail: z.string().optional(),
});

export const AssistantDeltaMsg = z.object({
  type: z.literal("assistant_delta"),
  text: z.string(),
});

export const AssistantMessageMsg = z.object({
  type: z.literal("assistant_message"),
  text: z.string(),
});

export const ThinkingDeltaMsg = z.object({
  type: z.literal("thinking_delta"),
  text: z.string(),
});

export const ToolUseMsg = z.object({
  type: z.literal("tool_use"),
  id: z.string(),
  name: z.string(),
  title: z.string(),
  subtitle: z.string().optional(),
  input: z.unknown().optional(),
});

export const ToolResultMsg = z.object({
  type: z.literal("tool_result"),
  id: z.string(),
  ok: z.boolean(),
  summary: z.string().optional(),
});

export const PermissionRequestMsg = z.object({
  type: z.literal("permission_request"),
  requestId: z.string(),
  tool: z.string(),
  title: z.string(),
  detail: z.string().optional(),
  risk: Risk,
  kind: PermissionKind,
  diff: z.string().optional(),
  command: z.string().optional(),
});

export const ModeChangedMsg = z.object({
  type: z.literal("mode_changed"),
  mode: PermissionMode,
});

export const TurnCompleteMsg = z.object({
  type: z.literal("turn_complete"),
  stopReason: z.enum(["end_turn", "cancelled", "error", "max_turns"]),
});

export const NoticeMsg = z.object({
  type: z.literal("notice"),
  level: z.enum(["info", "warn"]),
  message: z.string(),
});

export const ErrorMsg = z.object({
  type: z.literal("error"),
  message: z.string(),
  fatal: z.boolean().optional(),
});

export const PongMsg = z.object({
  type: z.literal("pong"),
  t: z.number().optional(),
});

export const ServerMsg = z.discriminatedUnion("type", [
  ReadyMsg,
  ProjectsMsg,
  StatusMsg,
  AssistantDeltaMsg,
  AssistantMessageMsg,
  ThinkingDeltaMsg,
  ToolUseMsg,
  ToolResultMsg,
  PermissionRequestMsg,
  ModeChangedMsg,
  TurnCompleteMsg,
  NoticeMsg,
  ErrorMsg,
  PongMsg,
]);
export type ServerMsg = z.infer<typeof ServerMsg>;

/* WS close codes used by Pinch. */
export const CloseCode = {
  AUTH_FAILED: 4401,
  PROTOCOL_MISMATCH: 4426,
  INTERNAL: 4500,
} as const;

/** Parse + validate an inbound client frame. Returns null on malformed input. */
export function parseClientMsg(raw: string): ClientMsg | null {
  try {
    return ClientMsg.parse(JSON.parse(raw));
  } catch {
    return null;
  }
}

/** Parse + validate an inbound server frame (used by the simulator client). */
export function parseServerMsg(raw: string): ServerMsg | null {
  try {
    return ServerMsg.parse(JSON.parse(raw));
  } catch {
    return null;
  }
}

/** Typed constructors for every server frame — guarantees outbound conformance. */
export const srv = {
  ready: (m: Omit<z.infer<typeof ReadyMsg>, "type" | "protocolVersion">) =>
    ({ type: "ready", protocolVersion: PROTOCOL_VERSION, ...m }) satisfies z.infer<typeof ReadyMsg>,
  projects: (projects: ProjectRef[]) =>
    ({ type: "projects", projects }) satisfies z.infer<typeof ProjectsMsg>,
  status: (state: AgentState, detail?: string) =>
    ({ type: "status", state, detail }) satisfies z.infer<typeof StatusMsg>,
  assistantDelta: (text: string) =>
    ({ type: "assistant_delta", text }) satisfies z.infer<typeof AssistantDeltaMsg>,
  assistantMessage: (text: string) =>
    ({ type: "assistant_message", text }) satisfies z.infer<typeof AssistantMessageMsg>,
  thinkingDelta: (text: string) =>
    ({ type: "thinking_delta", text }) satisfies z.infer<typeof ThinkingDeltaMsg>,
  toolUse: (m: Omit<z.infer<typeof ToolUseMsg>, "type">) =>
    ({ type: "tool_use", ...m }) satisfies z.infer<typeof ToolUseMsg>,
  toolResult: (m: Omit<z.infer<typeof ToolResultMsg>, "type">) =>
    ({ type: "tool_result", ...m }) satisfies z.infer<typeof ToolResultMsg>,
  permissionRequest: (m: Omit<z.infer<typeof PermissionRequestMsg>, "type">) =>
    ({ type: "permission_request", ...m }) satisfies z.infer<typeof PermissionRequestMsg>,
  modeChanged: (mode: PermissionMode) =>
    ({ type: "mode_changed", mode }) satisfies z.infer<typeof ModeChangedMsg>,
  turnComplete: (stopReason: z.infer<typeof TurnCompleteMsg>["stopReason"]) =>
    ({ type: "turn_complete", stopReason }) satisfies z.infer<typeof TurnCompleteMsg>,
  notice: (level: "info" | "warn", message: string) =>
    ({ type: "notice", level, message }) satisfies z.infer<typeof NoticeMsg>,
  error: (message: string, fatal = false) =>
    ({ type: "error", message, fatal }) satisfies z.infer<typeof ErrorMsg>,
  pong: (t?: number) => ({ type: "pong", t }) satisfies z.infer<typeof PongMsg>,
};
