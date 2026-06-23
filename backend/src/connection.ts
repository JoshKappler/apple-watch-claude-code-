/**
 * Per-connection WebSocket handler.
 *
 * Owns one WebSocket: the auth handshake, inbound frame routing, the app-level +
 * ws-level heartbeat, and attachment to a shared session. One Connection ≈ one
 * watch attached to one agent session.
 *
 * Session state, the indexed event buffer, the agent wiring, resume, and the
 * idle sweep all live in sessionRegistry.ts now — shared with the HTTP API. This
 * file is just the WS transport: it attaches a live socket to a session, and the
 * registry's pushEvent() forwards each outbound agent frame down that socket.
 *
 * Auth model (matches PROTOCOL.md + security posture in DECISIONS.md):
 *  - The upgrade handler may pre-authenticate via the Authorization header.
 *  - Otherwise the FIRST frame MUST be `auth`; no other frame is processed first.
 *  - Token compared in constant time; protocolVersion validated (close 4426).
 */
import { timingSafeEqual } from "node:crypto";
import type { WebSocket } from "ws";
import {
  CloseCode,
  PROTOCOL_VERSION,
  parseClientMsg,
  srv,
  type ClientMsg,
  type PermissionMode,
  type ServerMsg,
} from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { projectRegistry } from "./projects.js";
import {
  createSession,
  defaultProject,
  ensureSessionSweep,
  pushEvent,
  resumableSession,
  sessions,
  trySocketSend,
  type SessionState,
} from "./sessionRegistry.js";

/** ws-level ping cadence and the missed-pong budget before terminate(). */
const WS_PING_INTERVAL_MS = 25_000;
const MAX_MISSED_PONGS = 2;

/** Constant-time token comparison that tolerates length differences. */
function tokensMatch(provided: string, expected: string): boolean {
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) {
    // Still run a compare to keep timing uniform, then fail.
    timingSafeEqual(a, a);
    return false;
  }
  return timingSafeEqual(a, b);
}

export interface ConnectionOpts {
  ws: WebSocket;
  /** True if the upgrade handler already validated the bearer header. */
  preAuthed: boolean;
}

export class Connection {
  private readonly ws: WebSocket;
  private authed: boolean;
  private state: SessionState | null = null;
  private deviceId: string | undefined;
  private missedPongs = 0;
  private wsPingTimer: NodeJS.Timeout | null = null;
  private closed = false;

  constructor(opts: ConnectionOpts) {
    this.ws = opts.ws;
    this.authed = opts.preAuthed;

    this.ws.on("message", (data) => this.onMessage(data));
    this.ws.on("close", () => this.onClose());
    this.ws.on("error", (err) => log.warn({ err }, "ws error"));
    this.ws.on("pong", () => {
      this.missedPongs = 0;
    });

    this.startWsHeartbeat();
    ensureSessionSweep();
  }

  /* ───────────────────────────── inbound ───────────────────────────── */

  private onMessage(data: unknown): void {
    const raw = typeof data === "string" ? data : String(data);
    const msg = parseClientMsg(raw);
    if (!msg) {
      // Unknown/malformed frame: ignore per forward-compat rule.
      log.debug("ignored malformed/unknown client frame");
      return;
    }

    // Before auth completes, only `auth` is processed.
    if (!this.authed && msg.type !== "auth") {
      log.warn({ type: msg.type }, "frame before auth; ignoring");
      return;
    }

    switch (msg.type) {
      case "auth":
        void this.handleAuth(msg);
        break;
      case "prompt":
        void this.handlePrompt(msg.text);
        break;
      case "permission_decision":
        this.handlePermissionDecision(msg);
        break;
      case "set_mode":
        this.handleSetMode(msg.mode);
        break;
      case "cancel":
        void this.handleCancel();
        break;
      case "compact":
        this.handleCompact();
        break;
      case "list_projects":
        void this.handleListProjects();
        break;
      case "select_project":
        void this.handleSelectProject(msg.projectId);
        break;
      case "ping":
        this.rawSend(srv.pong(msg.t));
        break;
    }
  }

  private async handleAuth(
    msg: Extract<ClientMsg, { type: "auth" }>,
  ): Promise<void> {
    if (this.authed && this.state) {
      // Already authed (header path or duplicate). Ignore re-auth.
      return;
    }

    if (!tokensMatch(msg.token, config.token)) {
      log.warn("auth failed: bad token");
      this.fatalClose(CloseCode.AUTH_FAILED, "auth failed");
      return;
    }
    if (msg.protocolVersion !== PROTOCOL_VERSION) {
      log.warn(
        { got: msg.protocolVersion, want: PROTOCOL_VERSION },
        "protocol mismatch",
      );
      this.rawSend(
        srv.error(
          `protocol mismatch: server ${PROTOCOL_VERSION}, client ${msg.protocolVersion}`,
          true,
        ),
      );
      this.fatalClose(CloseCode.PROTOCOL_MISMATCH, "protocol mismatch");
      return;
    }

    this.authed = true;
    this.deviceId = msg.deviceId;
    await this.attachSession(msg.resumeSessionId);
  }

  /** Create a fresh session, or re-attach to an existing one for resume. */
  private async attachSession(resumeId?: string): Promise<void> {
    const existing = resumableSession(resumeId, this.deviceId);
    if (existing) {
      // Evict any stale socket still attached to this session (e.g. a half-dead
      // foreground socket the watch dropped on screen sleep without a clean close).
      if (existing.socket && existing.socket !== this.ws) {
        try {
          existing.socket.close(1000, "superseded");
        } catch {
          /* ignore */
        }
      }
      existing.socket = this.ws;
      existing.deviceId = this.deviceId ?? existing.deviceId;
      existing.lastActiveAt = Date.now();
      this.state = existing;
      const ref = config.mock
        ? {
            id: existing.project.id,
            name: existing.project.name,
            path: existing.project.root,
          }
        : await projectRegistry.toRef(existing.project);
      this.rawSend(
        srv.ready({
          sessionId: existing.sessionId,
          mode: existing.mode,
          project: ref,
          models: [config.model],
          resumed: true,
        }),
      );
      this.rawSend(srv.notice("info", "Reconnected; resumed session."));
      this.replayBuffer();
      return;
    }

    const proj = defaultProject();
    if (!proj) {
      this.rawSend(srv.error("no projects configured", true));
      this.fatalClose(CloseCode.INTERNAL, "no projects");
      return;
    }

    const state = createSession(proj, "default", {
      deviceId: this.deviceId,
      socket: this.ws,
      http: false,
    });
    this.state = state;

    const ref = config.mock
      ? { id: proj.id, name: proj.name, path: proj.root }
      : await projectRegistry.toRef(proj);
    this.rawSend(
      srv.ready({
        sessionId: state.sessionId,
        mode: state.mode,
        project: ref,
        models: [config.model],
        resumed: false,
      }),
    );
  }

  private async handlePrompt(text: string): Promise<void> {
    const state = this.state;
    if (!state) return;
    await state.agent.start(text);
  }

  private handlePermissionDecision(
    msg: Extract<ClientMsg, { type: "permission_decision" }>,
  ): void {
    const state = this.state;
    if (!state) return;
    const ok = state.approvals.decide(msg.requestId, {
      decision: msg.decision,
      note: msg.note,
      remember: msg.remember,
    });
    if (!ok) log.debug({ requestId: msg.requestId }, "stale permission decision");
  }

  private handleSetMode(mode: PermissionMode): void {
    const state = this.state;
    if (!state) return;
    state.mode = mode;
    state.agent.setMode(mode);
    // Logged frame: poll clients see mode changes too.
    pushEvent(state, srv.modeChanged(mode));
  }

  private async handleCancel(): Promise<void> {
    const state = this.state;
    if (!state) return;
    await state.agent.interrupt();
    pushEvent(state, srv.status("idle"));
    pushEvent(state, srv.turnComplete("cancelled"));
  }

  private handleCompact(): void {
    const state = this.state;
    if (!state) return;
    state.agent.compact();
  }

  private async handleListProjects(): Promise<void> {
    const refs = config.mock
      ? projectRegistry.list().map((p) => ({ id: p.id, name: p.name, path: p.root }))
      : await projectRegistry.listRefs();
    this.rawSend(srv.projects(refs));
  }

  private async handleSelectProject(projectId: string): Promise<void> {
    const project = projectRegistry.get(projectId);
    if (!project) {
      this.rawSend(srv.notice("warn", `unknown project: ${projectId}`));
      return;
    }
    // Allowlist guard: belt-and-suspenders even though the id came from registry.
    if (!config.mock && !projectRegistry.isPathAllowed(project.root)) {
      this.rawSend(srv.error("project path not allowed", false));
      return;
    }

    const old = this.state;
    if (old) {
      await old.agent.cancel();
      for (const [key, s] of sessions) if (s === old) sessions.delete(key);
    }

    const state = createSession(project, old?.mode ?? "default", {
      deviceId: this.deviceId,
      socket: this.ws,
      http: false,
    });
    this.state = state;

    const ref = config.mock
      ? { id: project.id, name: project.name, path: project.root }
      : await projectRegistry.toRef(project);
    this.rawSend(
      srv.ready({
        sessionId: state.sessionId,
        mode: state.mode,
        project: ref,
        models: [config.model],
        resumed: false,
      }),
    );
  }

  /* ───────────────────────────── outbound ───────────────────────────── */

  /** Connection-level frame straight to this socket (ready/pong/notice/etc). */
  private rawSend(msg: ServerMsg): void {
    if (this.closed) return;
    trySocketSend(this.ws, msg);
  }

  /** Replay the per-session event log to a freshly reconnected watch. */
  private replayBuffer(): void {
    if (!this.state) return;
    for (const e of this.state.eventLog) this.rawSend(e.msg);
  }

  /* ───────────────────────────── heartbeat ───────────────────────────── */

  private startWsHeartbeat(): void {
    this.wsPingTimer = setInterval(() => {
      if (this.closed) return;
      if (this.missedPongs >= MAX_MISSED_PONGS) {
        log.warn("dead socket: terminating after missed pongs");
        this.ws.terminate();
        return;
      }
      this.missedPongs += 1;
      try {
        this.ws.ping();
      } catch {
        this.ws.terminate();
      }
    }, WS_PING_INTERVAL_MS);
    // Don't keep the process alive solely for the heartbeat.
    this.wsPingTimer.unref?.();
  }

  /* ───────────────────────────── lifecycle ───────────────────────────── */

  private fatalClose(code: number, reason: string): void {
    this.closed = true;
    if (this.wsPingTimer) clearInterval(this.wsPingTimer);
    try {
      this.ws.close(code, reason);
    } catch {
      this.ws.terminate();
    }
  }

  private onClose(): void {
    this.closed = true;
    if (this.wsPingTimer) clearInterval(this.wsPingTimer);
    // Detach the socket but KEEP the session alive for resume. A reconnecting
    // watch (resumeSessionId) re-attaches and gets the buffered catch-up. Stamp the
    // detach time so the idle sweep retires it if the watch never comes back.
    if (this.state && this.state.socket === this.ws) {
      this.state.socket = null;
      this.state.lastActiveAt = Date.now();
    }
    log.info({ sessionId: this.state?.sessionId }, "connection closed");
  }
}
