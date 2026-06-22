/**
 * Durable session records — the missing piece that lets a watch resume its Claude
 * CONTEXT across a backend restart (or a swept idle session).
 *
 * The live `SessionState` (agent + event log) lives only in memory, so a backend
 * restart or the idle sweep wipes it. When that happens the watch still POSTs its
 * persisted `resumeSessionId`, but `resumableSession()` finds nothing → a brand-new
 * agent spins up and the whole conversation is forgotten. That's the "it forgets
 * all context when it reconnects" bug.
 *
 * The Agent SDK, however, persists every conversation's transcript to disk under its
 * OWN session id and can reload it via `options.resume`. So if we durably remember the
 * mapping {our session id → SDK session id + project/model/thinking/mode/device}, we
 * can REVIVE a session after a restart by constructing a fresh agent with
 * `resume: <sdkSessionId>` — the SDK replays the transcript and Claude keeps its context.
 *
 * This is a tiny JSON file (write-through, in-memory cached). It holds no secrets: the
 * SDK session id is an opaque local handle and the bearer token still gates every resume.
 */
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { PermissionMode } from "@pinch/protocol";
import { log } from "./log.js";
import type { ThinkingLevel } from "./sessionTypes.js";

/** One durable record: enough to rebuild an agent that resumes the same SDK transcript. */
export interface PersistedSession {
  /** Our session handle (the `s_…` id the watch persists + sends as resumeSessionId). */
  ourId: string;
  /** The Agent SDK's own session id — what `options.resume` needs to reload the transcript. */
  sdkId: string;
  /** Project id (→ cwd). The SDK keys transcripts by cwd, so revive MUST use the same project. */
  projectId: string;
  model: string;
  thinking: ThinkingLevel;
  mode: PermissionMode;
  deviceId: string | undefined;
  updatedAt: number;
}

/** Records older than this are pruned on load (the SDK's own transcripts age out too). */
const MAX_AGE_MS = 7 * 24 * 60 * 60_000; // 7 days

/** backend/.pinch-sessions.json — anchored to the package root so it survives `tsc` (which only
 *  rewrites dist/) and process restarts. NOT in dist/, NOT committed (see .gitignore). */
const FILE = fileURLToPath(new URL("../.pinch-sessions.json", import.meta.url));

/** In-memory cache; the file is the durable mirror. Lazily loaded on first access. */
let cache: Record<string, PersistedSession> | null = null;

function load(): Record<string, PersistedSession> {
  if (cache) return cache;
  let parsed: Record<string, PersistedSession> = {};
  try {
    const raw = readFileSync(FILE, "utf8");
    const obj = JSON.parse(raw) as Record<string, PersistedSession>;
    const now = Date.now();
    for (const [id, rec] of Object.entries(obj)) {
      // Prune stale entries and anything malformed.
      if (rec && typeof rec.sdkId === "string" && now - (rec.updatedAt ?? 0) < MAX_AGE_MS) {
        parsed[id] = rec;
      }
    }
  } catch {
    // Missing or corrupt file → start empty. Not an error: first run has no records.
    parsed = {};
  }
  cache = parsed;
  return cache;
}

/** Atomic-ish write (temp + rename) so a crash mid-write can't corrupt the file. */
function flush(): void {
  if (!cache) return;
  try {
    const tmp = `${FILE}.tmp`;
    writeFileSync(tmp, JSON.stringify(cache), "utf8");
    renameSync(tmp, FILE);
  } catch (err) {
    log.warn({ err }, "could not persist session records");
  }
}

/** Insert/update the record for a session. Called whenever the SDK (re)reports its id. */
export function saveSessionRecord(rec: PersistedSession): void {
  const all = load();
  all[rec.ourId] = { ...rec, updatedAt: Date.now() };
  flush();
}

/** Look up a durable record by our session id (for revive after a restart/sweep). */
export function getSessionRecord(ourId: string): PersistedSession | undefined {
  return load()[ourId];
}

/** Forget a record (e.g. the user cleared context / started a fresh session). */
export function deleteSessionRecord(ourId: string): void {
  const all = load();
  if (all[ourId]) {
    delete all[ourId];
    flush();
  }
}
