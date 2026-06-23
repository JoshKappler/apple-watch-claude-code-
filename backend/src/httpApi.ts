/**
 * HTTP request/response + polling API for the watchOS client.
 *
 * On the physical Apple Watch, plain HTTPS works but URLSessionWebSocketTask is
 * refused by the OS — so the watch transport moved to HTTP. This module exposes
 * the SAME session lifecycle as the WS path (create/resume, prompt, decisions,
 * mode, cancel, projects) but drives a SOCKETLESS session: outbound ServerMsgs
 * land in the session's indexed event log, and the client drains them via /poll.
 *
 * All routes live under /api/ so they never collide with /ws or /health. Every
 * request requires `Authorization: Bearer <token>` (same constant-time check as
 * the WS upgrade). Bad/missing token → 401; unknown /api path → 404.
 *
 * The agent wiring, session map, resume rule, event log, and idle sweep are all
 * shared with the WS path via sessionRegistry.ts — nothing here is duplicated.
 */
import type { IncomingMessage, ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { z } from "zod";
import { srv, PROTOCOL_VERSION } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { projectRegistry } from "./projects.js";
import {
  attachAgent,
  createSession,
  defaultProject,
  ensureSessionSweep,
  pushEvent,
  readEvents,
  resumableSession,
  reviveSession,
  sessions,
  type SessionState,
} from "./sessionRegistry.js";

/** Constant-time bearer check (mirrors wsServer's upgrade check). */
function bearerMatches(header: string | string[] | undefined): boolean {
  const h = Array.isArray(header) ? header[0] : header;
  if (!h) return false;
  const m = /^Bearer\s+(.+)$/i.exec(h.trim());
  if (!m || !m[1]) return false;
  const provided = Buffer.from(m[1]);
  const expected = Buffer.from(config.token);
  if (provided.length !== expected.length) {
    timingSafeEqual(provided, provided);
    return false;
  }
  return timingSafeEqual(provided, expected);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

/** Read + JSON-parse a request body (cap at 64KB; prompts are <=8000 chars). */
async function readJsonBody(req: IncomingMessage): Promise<unknown> {
  const MAX = 64 * 1024;
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    size += buf.length;
    if (size > MAX) throw new Error("body too large");
    chunks.push(buf);
  }
  if (chunks.length === 0) return {};
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Model ids the watch may send. Default stays config.model (env PINCH_MODEL). */
const ModelId = z.enum([
  "claude-opus-4-8",
  "claude-sonnet-4-6",
  "claude-haiku-4-5-20251001",
  "claude-fable-5",
]);

/** Watch-facing reasoning effort level (mapped to an SDK ThinkingConfig in sessionTypes). */
const ThinkingLevel = z.enum(["off", "low", "medium", "high", "xhigh", "max"]);

/** Optional model + thinking fields shared by POST /api/session and /api/config. */
const ConfigFields = z.object({
  model: ModelId.optional(),
  thinking: ThinkingLevel.optional(),
});

/** Resolve a ProjectRef for the response (mock skips git lookups). */
async function projectRef(state: SessionState) {
  return config.mock
    ? { id: state.project.id, name: state.project.name, path: state.project.root }
    : projectRegistry.toRef(state.project);
}

/**
 * Try to handle an /api/* request. Returns true if it owned the request (and has
 * already written a response); false to let the caller fall through to other
 * handlers (/health, the 426 default).
 */
export async function handleApiRequest(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<boolean> {
  let url: URL;
  try {
    url = new URL(req.url ?? "/", "http://localhost");
  } catch {
    return false;
  }
  if (!url.pathname.startsWith("/api/")) return false;

  // Auth on every /api route. A bad/missing bearer → 401 (never reveal routes).
  if (!bearerMatches(req.headers["authorization"])) {
    sendJson(res, 401, { error: "unauthorized" });
    return true;
  }

  ensureSessionSweep();
  const route = `${req.method ?? "GET"} ${url.pathname}`;

  try {
    switch (route) {
      case "POST /api/session":
        await handleSession(req, res);
        return true;
      case "POST /api/prompt":
        await handlePrompt(req, res);
        return true;
      case "GET /api/poll":
        handlePoll(url, res);
        return true;
      case "POST /api/decision":
        await handleDecision(req, res);
        return true;
      case "POST /api/mode":
        await handleMode(req, res);
        return true;
      case "POST /api/config":
        await handleConfig(req, res);
        return true;
      case "POST /api/cancel":
        await handleCancel(req, res);
        return true;
      case "POST /api/restart":
        await handleRestart(req, res);
        return true;
      case "GET /api/projects":
        await handleProjects(res);
        return true;
      case "POST /api/select-project":
        await handleSelectProject(req, res);
        return true;
      default:
        sendJson(res, 404, { error: "not_found" });
        return true;
    }
  } catch (err) {
    if (err instanceof SyntaxError || (err as Error)?.message === "body too large") {
      sendJson(res, 400, { error: "bad_request" });
      return true;
    }
    log.error({ err, route }, "api handler error");
    sendJson(res, 500, { error: "internal" });
    return true;
  }
}

/**
 * Look up a session by id, refreshing its idle clock. Sends 410 (session_gone)
 * and returns null if unknown/expired so the client knows to re-create.
 */
function requireSession(
  sessionId: string | undefined,
  res: ServerResponse,
): SessionState | null {
  const state = sessionId ? sessions.get(sessionId) : undefined;
  if (!state) {
    sendJson(res, 410, { error: "session_gone" });
    return null;
  }
  state.lastActiveAt = Date.now();
  return state;
}

/* ───────────────────────────── routes ───────────────────────────── */

/** POST /api/session → create OR resume a socketless session. */
async function handleSession(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const deviceId = asString(body.deviceId);
  const resumeSessionId = asString(body.resumeSessionId);

  // Optional model/thinking. Invalid values → 400 (don't silently ignore).
  const cfg = ConfigFields.safeParse(body);
  if (!cfg.success) {
    sendJson(res, 400, { error: "bad_config" });
    return;
  }

  // Resume order: first try the live in-memory session; if it's gone (backend restarted or the
  // idle sweep retired it), try to REVIVE it from the durable record so Claude keeps its context.
  let existing = resumableSession(resumeSessionId, deviceId);
  let revived = false;
  if (!existing && resumeSessionId) {
    existing = reviveSession(resumeSessionId, deviceId);
    revived = existing !== null;
  }
  if (existing) {
    existing.deviceId = deviceId ?? existing.deviceId;
    existing.http = true; // now driven over HTTP
    existing.lastActiveAt = Date.now();
    // Apply any model/thinking sent alongside the resume to the live session.
    if (cfg.data.model || cfg.data.thinking) {
      if (cfg.data.model) existing.model = cfg.data.model;
      if (cfg.data.thinking) existing.thinking = cfg.data.thinking;
      existing.agent.setConfig({
        model: cfg.data.model,
        thinking: cfg.data.thinking,
      });
    }
    if (revived) {
      // Drop a breadcrumb the watch can show. Index starts at 0 in the fresh log, which is
      // exactly why we must tell the client to reset its cursor (below) — otherwise its stale,
      // higher cursor would swallow every new event until our index caught back up to it.
      pushEvent(existing, srv.notice("info", "Reconnected — context restored."));
    }
    sendJson(res, 200, {
      sessionId: existing.sessionId,
      mode: existing.mode,
      project: await projectRef(existing),
      models: [existing.model],
      resumed: true,
      // On a revive the event log was rebuilt empty, so the client must reset its poll cursor to
      // 0. On a normal in-memory resume the log is intact → keep the client's saved cursor (no
      // replay, no duplicate bubbles).
      resetCursor: revived,
      protocolVersion: PROTOCOL_VERSION,
    });
    return;
  }

  const proj = defaultProject();
  if (!proj) {
    sendJson(res, 503, { error: "no_projects" });
    return;
  }

  const state = createSession(proj, "default", {
    deviceId,
    socket: null,
    http: true,
    model: cfg.data.model,
    thinking: cfg.data.thinking,
  });
  sendJson(res, 200, {
    sessionId: state.sessionId,
    mode: state.mode,
    project: await projectRef(state),
    models: [state.model],
    resumed: false,
    resetCursor: false, // brand-new session: the watch zeroes its cursor on resumed:false anyway
    protocolVersion: PROTOCOL_VERSION,
  });
}

/** POST /api/prompt → inject a prompt into the session's agent. */
async function handlePrompt(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const text = asString(body.text);
  if (!text) {
    sendJson(res, 400, { error: "missing_text" });
    return;
  }
  // Idempotency: the watch persists prompts to a durable outbox and re-sends any it
  // never got a 2xx for (a POST that parked/dropped during an LTE handoff, or one
  // whose ack died with a suspended app). Dedup by the client-generated promptId so
  // an at-least-once retry can't run the same turn twice. (Backwards-compatible: an
  // older client that omits promptId just isn't deduped, same as before.)
  const promptId = asString(body.promptId);
  if (promptId) {
    if (state.seenPromptIds.has(promptId)) {
      sendJson(res, 202, { ok: true, duplicate: true });
      return;
    }
    state.seenPromptIds.add(promptId);
    // Bound the set (Set preserves insertion order → evict the oldest).
    if (state.seenPromptIds.size > 64) {
      const oldest = state.seenPromptIds.values().next().value;
      if (oldest !== undefined) state.seenPromptIds.delete(oldest);
    }
  }
  // Await ACCEPTANCE only: start() resolves once the turn is wired up (it fire-and-forgets the
  // turn's actual streaming via consume()), so this does not block for the whole turn. If setup
  // throws, un-poison the promptId so the watch's retry can re-deliver, and return 500 so the
  // prompt stays in the outbox instead of being dropped on a phantom 202.
  try {
    await state.agent.start(text);
  } catch (err) {
    if (promptId) state.seenPromptIds.delete(promptId);
    log.error({ err, sessionId: state.sessionId }, "agent.start failed");
    sendJson(res, 500, { error: "start_failed" });
    return;
  }
  sendJson(res, 202, { ok: true });
}

/**
 * GET /api/poll?sessionId=X&cursor=N → events with index >= N plus the new
 * high-water `cursor`. `cursor` is the value the client got from its previous
 * poll; it must be sent back verbatim so each poll returns a strictly newer,
 * non-overlapping range. A missing/NaN/negative cursor is clamped to 0 (full
 * replay) — only the very first poll should omit it.
 */
function handlePoll(url: URL, res: ServerResponse): void {
  const state = requireSession(
    url.searchParams.get("sessionId") ?? undefined,
    res,
  );
  if (!state) return;
  const cursorParam = url.searchParams.get("cursor");
  const parsed = cursorParam !== null ? Number.parseInt(cursorParam, 10) : 0;
  const cursor = Number.isFinite(parsed) && parsed >= 0 ? parsed : 0;
  const { cursor: hi, events, gap } = readEvents(state, cursor);
  sendJson(res, 200, { cursor: hi, events, gap });
}

/** POST /api/decision → resolve a parked permission request. */
async function handleDecision(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const requestId = asString(body.requestId);
  const decision = body.decision === "allow" ? "allow" : body.decision === "deny" ? "deny" : undefined;
  if (!requestId || !decision) {
    sendJson(res, 400, { error: "bad_decision" });
    return;
  }
  const note = asString(body.note);
  const remember = body.remember === true;
  const ok = state.approvals.decide(requestId, { decision, note, remember });
  if (!ok) log.debug({ requestId }, "stale permission decision (http)");
  sendJson(res, 200, { ok: true });
}

/** POST /api/mode → change permission posture mid-session. */
async function handleMode(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const mode = body.mode;
  if (
    mode !== "default" &&
    mode !== "acceptEdits" &&
    mode !== "plan" &&
    mode !== "bypassPermissions"
  ) {
    sendJson(res, 400, { error: "bad_mode" });
    return;
  }
  state.mode = mode;
  state.agent.setMode(mode);
  pushEvent(state, srv.modeChanged(mode));
  sendJson(res, 200, { ok: true });
}

/**
 * POST /api/config { sessionId, model?, thinking? } → change the live session's
 * model/thinking. Applies to subsequent turns (and the running query when one is
 * live). 200 {ok:true} on success, 404 if the session is unknown.
 */
async function handleConfig(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const sessionId = asString(body.sessionId);
  // 404 for an unknown session per spec (requireSession would send 410).
  const state = sessionId ? sessions.get(sessionId) : undefined;
  if (!state) {
    sendJson(res, 404, { error: "session_gone" });
    return;
  }
  const cfg = ConfigFields.safeParse(body);
  if (!cfg.success) {
    sendJson(res, 400, { error: "bad_config" });
    return;
  }
  state.lastActiveAt = Date.now();
  if (cfg.data.model) state.model = cfg.data.model;
  if (cfg.data.thinking) state.thinking = cfg.data.thinking;
  state.agent.setConfig({ model: cfg.data.model, thinking: cfg.data.thinking });
  sendJson(res, 200, { ok: true });
}

/** POST /api/cancel → soft-stop the current turn. */
async function handleCancel(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  await state.agent.interrupt();
  pushEvent(state, srv.status("idle"));
  pushEvent(state, srv.turnComplete("cancelled"));
  sendJson(res, 200, { ok: true });
}

/**
 * Set once a restart has been kicked off, so a double-tap from the watch can't spawn two parallel
 * rebuilds (which would race on dist/ and double-bind the port). Lives only for this process's
 * lifetime — which is the point: the process is about to be replaced by a fresh one.
 */
let restartInitiated = false;

/**
 * POST /api/restart → rebuild + relaunch THIS backend process so backend code changes made from
 * the watch go live (the running `node dist/index.js` holds the old code; a rebuild alone isn't
 * enough — the process must be replaced). Delegates to the detached `infra/restart-backend.sh`,
 * which builds FIRST while this process keeps serving and only kills + relaunches if the build
 * SUCCEEDS — so a typo in a watch-driven edit can never strand the watch with a dead tether. After
 * the swap the watch's next poll 410s and revives the SAME session, so the conversation is kept.
 */
async function handleRestart(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const sessionId = asString(body.sessionId);
  const state = sessionId ? sessions.get(sessionId) : undefined;

  if (restartInitiated) {
    sendJson(res, 202, { ok: true, already: true });
    return;
  }
  restartInitiated = true;

  // Breadcrumb the watch can show during the rebuild window (the old process is still serving,
  // so this poll still reaches the client before the swap). The revived session starts a fresh
  // log, so this notice is naturally transient.
  if (state) {
    pushEvent(state, srv.notice("info", "Restarting backend — reconnecting shortly…"));
    state.lastActiveAt = Date.now();
  }

  // Resolve the script from this file: backend/dist/httpApi.js → ../../ = repo root.
  const here = dirname(fileURLToPath(import.meta.url));
  const repoRoot = resolve(here, "../..");
  const script = resolve(repoRoot, "infra/restart-backend.sh");

  log.warn(
    { pid: process.pid, script },
    "restart requested from watch — rebuilding + relaunching backend",
  );

  // Ack BEFORE spawning so the watch gets its 202. We do NOT exit here: the restarter kills this
  // process itself, but only after a successful build (so a build failure keeps the tether alive).
  sendJson(res, 202, { ok: true });

  const child = spawn("bash", [script, String(process.pid)], {
    cwd: repoRoot,
    detached: true,
    stdio: "ignore",
    env: process.env,
  });
  child.on("error", (err) => {
    // Couldn't even launch the script (missing bash / script) — nothing was torn down, so let the
    // user retry.
    restartInitiated = false;
    log.error({ err, script }, "failed to spawn restart script");
  });
  child.unref();
}

/** GET /api/projects → the project registry. */
async function handleProjects(res: ServerResponse): Promise<void> {
  const projects = config.mock
    ? projectRegistry.list().map((p) => ({ id: p.id, name: p.name, path: p.root }))
    : await projectRegistry.listRefs();
  sendJson(res, 200, { projects });
}

/** POST /api/select-project → swap the session's project (new agent). */
async function handleSelectProject(
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = (await readJsonBody(req)) as Record<string, unknown>;
  const state = requireSession(asString(body.sessionId), res);
  if (!state) return;
  const projectId = asString(body.projectId);
  const project = projectId ? projectRegistry.get(projectId) : undefined;
  if (!project) {
    pushEvent(state, srv.notice("warn", `unknown project: ${projectId ?? ""}`));
    sendJson(res, 404, { error: "unknown_project" });
    return;
  }
  if (!config.mock && !projectRegistry.isPathAllowed(project.root)) {
    sendJson(res, 403, { error: "path_not_allowed" });
    return;
  }

  // Tear down the old agent, but keep the SAME sessionId + event log so the
  // client's poll cursor and id stay valid: swap the project + agent in place.
  await state.agent.cancel();
  attachAgent(state, project, state.mode);
  sendJson(res, 200, { ok: true });
}
