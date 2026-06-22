/**
 * Shared session registry — the transport-agnostic home for agent sessions.
 *
 * Extracted from connection.ts so a session can exist with NO socket attached.
 * Both transports drive the same sessions:
 *   - WS (connection.ts): attaches a live socket; pushEvent() forwards each
 *     outbound ServerMsg straight to ws.send AND appends it to the event log.
 *   - HTTP (httpApi.ts): no socket; the client reads the event log via /api/poll.
 *
 * The event log is a per-session ring buffer with a MONOTONIC index. Every
 * outbound agent frame (status, assistant_*, tool_*, permission_request,
 * mode_changed, turn_complete, notice, error) is appended with an incrementing
 * index; /poll returns all entries whose index >= the client's cursor plus the
 * new high-water mark. `ready`/`pong` are connection-level frames and never go
 * through this sink, so they're naturally excluded from the poll stream.
 *
 * The agent wiring (project → SessionDeps → mock/real AgentSession) lives here
 * so it's shared, not duplicated per transport.
 */
import { randomUUID } from "node:crypto";
import type { WebSocket } from "ws";
import type { PermissionMode, ServerMsg } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { ApprovalRegistry } from "./approvals.js";
import { projectRegistry, type Project } from "./projects.js";
import type {
  AgentSession,
  SessionDeps,
  ThinkingLevel,
} from "./sessionTypes.js";
import { createMockSession } from "./mockSession.js";
// session.js imports the SDK only lazily (inside start()), so importing the
// factory here does NOT pull the SDK in at module scope.
import { createClaudeSession } from "./session.js";
import { getSessionRecord, saveSessionRecord } from "./sessionStore.js";

/** Max buffered events retained per session (ring buffer / replay window). */
export const EVENT_BUFFER_LIMIT = 500;

/**
 * How long a detached (no live socket AND no recent poll) session is kept alive
 * for resume before it's swept. The watch reconnects within seconds of waking.
 * This stops abandoned sessions (and their live agent processes) from leaking.
 */
const SESSION_IDLE_TTL_MS = 30 * 60_000; // 30 min (WS resume window)
/**
 * HTTP (watch) sessions get the SAME generous window as WS. The watch's poll loop stops
 * the instant its screen sleeps / wrist drops, but the agent turn keeps running server-side
 * and its events buffer in the event log — so when the watch wakes seconds-to-minutes later
 * it resumes from its cursor and gets the answer. A short TTL here was DESTROYING in-flight
 * turns (sweep → destroySession → agent.cancel()) whenever you looked away for 2 min, so the
 * reply never arrived. 30 min covers any realistic turn + glance-away.
 */
const HTTP_IDLE_TTL_MS = 30 * 60_000; // 30 min (was 2 min — killed turns when the watch slept)
const SESSION_SWEEP_INTERVAL_MS = 60_000; // 1 min

/** One indexed entry in a session's event log. */
export interface LoggedEvent {
  index: number;
  msg: ServerMsg;
}

/**
 * Session state that must SURVIVE a socket/poll gap so a reconnecting watch can
 * resume. Keyed by our session id (and the SDK's id once known). Holds the live
 * agent + an indexed replay buffer shared by both transports.
 */
export interface SessionState {
  sessionId: string;
  agent: AgentSession;
  approvals: ApprovalRegistry;
  project: Project;
  mode: PermissionMode;
  /** Active model id for this session (defaults to config.model). */
  model: string;
  /** Active extended-thinking level for this session (defaults to "off"). */
  thinking: ThinkingLevel;
  /** Monotonic-indexed ring buffer of outbound agent frames (poll + WS replay). */
  eventLog: LoggedEvent[];
  /** Next index to assign. Never reset, even as the ring trims old entries. */
  nextIndex: number;
  /** The currently attached WS socket (if any). Null for HTTP-only sessions. */
  socket: WebSocket | null;
  /**
   * Device that owns this session. Resume requires a matching deviceId so a
   * session id leaked off one watch can't be hijacked by another device on the
   * same token. `undefined` only for pre-deviceId clients (back-compat).
   */
  deviceId: string | undefined;
  /** Bumped on attach/detach/poll; used by the idle sweep to retire dead sessions. */
  lastActiveAt: number;
  /** True once created via the HTTP API (uses the shorter idle TTL). */
  http: boolean;
}

/** Module-level registry of live sessions, so resume works across transports. */
export const sessions = new Map<string, SessionState>();

/**
 * Append an outbound agent frame to a session's indexed log and, if a live WS
 * socket is attached, push it down that socket. THE shared event sink: the WS
 * path gets live frames, the HTTP path reads them back from the log via /poll.
 */
export function pushEvent(state: SessionState, msg: ServerMsg): void {
  state.eventLog.push({ index: state.nextIndex, msg });
  state.nextIndex += 1;
  if (state.eventLog.length > EVENT_BUFFER_LIMIT) state.eventLog.shift();
  if (state.socket) trySocketSend(state.socket, msg);
}

/**
 * Read logged events the client hasn't seen yet, plus the new high-water cursor.
 *
 * Contract (must stay exact to avoid duplicate delivery on the watch):
 *  - `cursor` is the NEXT index the client wants — i.e. the high-water it got
 *    from the previous poll. We return only events with `index >= cursor`.
 *  - The returned `cursor` is `nextIndex` (one past the last assigned index), so
 *    the client stores it and the NEXT poll fetches strictly newer events. No
 *    range ever overlaps a previous one.
 *  - A negative/NaN cursor is clamped to 0 by the caller; a cursor already at or
 *    beyond `nextIndex` yields an empty list (nothing newer yet) — we never
 *    replay the log for an up-to-date client.
 */
export function readEvents(
  state: SessionState,
  cursor: number,
): { cursor: number; events: ServerMsg[] } {
  const events: ServerMsg[] = [];
  // Up-to-date (or ahead-of-log) client: return nothing, just the high-water.
  if (cursor < state.nextIndex) {
    for (const e of state.eventLog) {
      if (e.index >= cursor) events.push(e.msg);
    }
  }
  return { cursor: state.nextIndex, events };
}

/**
 * Wire a fresh agent (+ approval registry) onto an existing state, for the given
 * project/mode. The agent's outbound `send` is bound to THIS state's pushEvent,
 * so every frame it emits is logged into this state's event log (and forwarded
 * live if a socket is attached). Used by createSession and by project swaps,
 * which keep the same sessionId / event log but need a new agent.
 */
export function attachAgent(
  state: SessionState,
  project: Project,
  mode: PermissionMode,
  resume?: string,
): void {
  const approvals = new ApprovalRegistry();
  state.approvals = approvals;
  state.project = project;
  state.mode = mode;

  const deps: SessionDeps = {
    send: (m) => pushEvent(state, m),
    approvals,
    cwd: project.root,
    model: state.model,
    thinking: state.thinking,
    // Set only on REVIVE: hands the SDK the prior conversation's id so it reloads that
    // transcript from disk and Claude keeps its full context across a backend restart/sweep.
    resume,
    initialMode: mode,
    onSessionId: (sdkId) => {
      // Map the SDK's own session id alongside ours so resume:sdkId works.
      if (sdkId && !sessions.has(sdkId)) sessions.set(sdkId, state);
      // Durably remember {our id → SDK id + project/model/thinking/mode/device}. This is the
      // ONLY thing that survives a process restart, so it's what lets a reconnecting watch
      // revive this exact conversation instead of getting a blank, context-free session.
      saveSessionRecord({
        ourId: state.sessionId,
        sdkId,
        projectId: state.project.id,
        model: state.model,
        thinking: state.thinking,
        mode: state.mode,
        deviceId: state.deviceId,
        updatedAt: Date.now(),
      });
    },
  };

  state.agent = config.mock ? createMockSession(deps) : createClaudeSession(deps);
}

/**
 * REVIVE a session that's no longer in memory (backend restarted, or it was swept) using its
 * durable record. Rebuilds a SessionState under the SAME session id with a fresh event log, and
 * wires an agent that RESUMES the SDK transcript (so context is preserved). Returns null if there's
 * no record, the device doesn't match, or the project is gone — in which case the caller falls
 * back to creating a brand-new session. The agent itself stays lazy (no SDK load until a prompt),
 * so reviving an idle session is cheap.
 */
export function reviveSession(
  ourId: string,
  deviceId: string | undefined,
): SessionState | null {
  const rec = getSessionRecord(ourId);
  if (!rec) return null;
  // Same deviceId binding as resumableSession: a leaked id can't be revived onto another device.
  const deviceOk = rec.deviceId === undefined || rec.deviceId === deviceId;
  if (!deviceOk) {
    log.warn(
      { ourId, recDevice: rec.deviceId, reqDevice: deviceId },
      "revive denied: deviceId mismatch",
    );
    return null;
  }
  // The SDK keys transcripts by cwd, so we MUST restore the same project to resume correctly.
  const project = projectRegistry.get(rec.projectId);
  if (!project) {
    log.warn({ ourId, projectId: rec.projectId }, "revive failed: project no longer available");
    return null;
  }

  const state: SessionState = {
    sessionId: rec.ourId,
    agent: undefined as unknown as AgentSession, // set by attachAgent
    approvals: undefined as unknown as ApprovalRegistry, // set by attachAgent
    project,
    mode: rec.mode,
    model: rec.model,
    thinking: rec.thinking,
    eventLog: [],
    nextIndex: 0,
    socket: null,
    deviceId: deviceId ?? rec.deviceId,
    lastActiveAt: Date.now(),
    http: true,
  };

  attachAgent(state, project, rec.mode, rec.sdkId);
  sessions.set(rec.ourId, state);
  log.info(
    { ourId, sdkId: rec.sdkId, projectId: rec.projectId },
    "revived session from durable record",
  );
  return state;
}

/**
 * Build a SessionState (agent + approvals + indexed log) for a project. The
 * single agent-wiring path shared by WS and HTTP. Registers it in the map.
 */
export function createSession(
  project: Project,
  mode: PermissionMode,
  opts: {
    deviceId: string | undefined;
    socket: WebSocket | null;
    http: boolean;
    /** Optional model override; falls back to config.model. */
    model?: string;
    /** Optional thinking level; falls back to "off". */
    thinking?: ThinkingLevel;
  },
): SessionState {
  const sessionId = `s_${randomUUID().slice(0, 12)}`;

  const state: SessionState = {
    sessionId,
    agent: undefined as unknown as AgentSession, // set by attachAgent
    approvals: undefined as unknown as ApprovalRegistry, // set by attachAgent
    project,
    mode,
    model: opts.model ?? config.model,
    thinking: opts.thinking ?? "off",
    eventLog: [],
    nextIndex: 0,
    socket: opts.socket,
    deviceId: opts.deviceId,
    lastActiveAt: Date.now(),
    http: opts.http,
  };

  attachAgent(state, project, mode);
  sessions.set(sessionId, state);
  return state;
}

/** Resolve the project a fresh session should use (default, with mock fallback). */
export function defaultProject(): Project | null {
  const project = projectRegistry.default();
  if (!project && !config.mock) return null;
  return project ?? { id: "mock", name: "mock", root: process.cwd(), mtimeMs: 0 };
}

/**
 * Look up an existing session for resume, enforcing the deviceId binding. Returns
 * the session only if it exists AND belongs to this device (or is legacy state
 * with no deviceId recorded). Same rule the WS path has always used.
 */
export function resumableSession(
  resumeId: string | undefined,
  deviceId: string | undefined,
): SessionState | null {
  if (!resumeId) return null;
  const existing = sessions.get(resumeId);
  if (!existing) return null;
  const deviceOk =
    existing.deviceId === undefined || existing.deviceId === deviceId;
  if (!deviceOk) {
    log.warn(
      { resumeId, sessionDevice: existing.deviceId, reqDevice: deviceId },
      "resume denied: deviceId mismatch",
    );
    return null;
  }
  return existing;
}

/** Tear down a session and delete every key that points at it. */
export function destroySession(state: SessionState): void {
  void state.agent.cancel().catch(() => {});
  for (const [key, s] of sessions) if (s === state) sessions.delete(key);
}

/**
 * Periodically retire sessions with no live socket whose last activity is older
 * than their TTL. HTTP sessions use a short (~2 min) TTL keyed off the last poll;
 * WS sessions keep the longer resume window. Each state can be reachable under
 * two keys (our id and the SDK's id), so we cancel once and delete every key.
 */
let sweepTimer: NodeJS.Timeout | null = null;
export function ensureSessionSweep(): void {
  if (sweepTimer) return;
  sweepTimer = setInterval(() => {
    const now = Date.now();
    const dead = new Set<SessionState>();
    for (const state of sessions.values()) {
      if (state.socket !== null) continue; // a live WS owns it
      const ttl = state.http ? HTTP_IDLE_TTL_MS : SESSION_IDLE_TTL_MS;
      if (now - state.lastActiveAt > ttl) dead.add(state);
    }
    for (const state of dead) {
      destroySession(state);
      log.info(
        { sessionId: state.sessionId, http: state.http },
        "swept idle session",
      );
    }
  }, SESSION_SWEEP_INTERVAL_MS);
  sweepTimer.unref?.();
}

/** Write a frame to a socket, swallowing send errors on a dying socket. */
export function trySocketSend(ws: WebSocket, msg: ServerMsg): void {
  try {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
  } catch (err) {
    log.debug({ err }, "send failed");
  }
}
