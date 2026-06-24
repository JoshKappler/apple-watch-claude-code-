/**
 * The contract both the real (SDK) session and the mock session implement, plus
 * the small heuristics that turn raw tool calls into glanceable watch summaries.
 *
 * Keeping the interface here (rather than in session.ts) means mockSession.ts can
 * implement it without forcing the SDK module to load — the SDK is only imported
 * lazily inside the real session path.
 */
import type {
  PermissionMode,
  PermissionKind,
  Risk,
  ServerMsg,
} from "@pinch/protocol";

/** How a session pushes protocol frames back out to the connection. */
export type SendFn = (msg: ServerMsg) => void;

/**
 * Watch-facing reasoning EFFORT level (surfaced in the UI as "Effort", matching the Claude Code
 * CLI scale). `"off"` is retained for back-compat / internal defaults but the watch only sends
 * low…max. Each maps to an extended-reasoning token budget in `thinkingConfig`.
 */
export type ThinkingLevel = "off" | "low" | "medium" | "high" | "xhigh" | "max";

/**
 * SDK ThinkingConfig shape (local mirror so this file never imports SDK types).
 * `disabled` = no extended thinking; `enabled` = fixed budget in tokens.
 */
export type SdkThinkingConfig =
  | { type: "disabled" }
  | { type: "enabled"; budgetTokens?: number };

/**
 * Map a watch EFFORT level to the SDK's `thinking` option (Options.thinking, a ThinkingConfig).
 * Budgets escalate across the five CLI effort levels, all kept just under the API's ~32k
 * extended-thinking ceiling so a high setting can never exceed the limit and fail a turn:
 *   off    → disabled (no extended thinking; internal default only, not shown on the watch)
 *   low    → 4096
 *   medium → 10000
 *   high   → 16000
 *   xhigh  → 24000
 *   max    → 31999 (just under the 32k ceiling)
 * The SDK also exposes setMaxThinkingTokens(N) for mid-session changes, where 0 disables and any
 * positive value is the budget — we reuse these numbers.
 */
export function thinkingConfig(level: ThinkingLevel): SdkThinkingConfig {
  switch (level) {
    case "off":
      return { type: "disabled" };
    case "low":
      return { type: "enabled", budgetTokens: 4096 };
    case "medium":
      return { type: "enabled", budgetTokens: 10000 };
    case "high":
      return { type: "enabled", budgetTokens: 16000 };
    case "xhigh":
      return { type: "enabled", budgetTokens: 24000 };
    case "max":
      return { type: "enabled", budgetTokens: 31999 };
  }
}

/** Resolved when a parked approval gets a decision. */
export interface ApprovalGate {
  create(): {
    requestId: string;
    wait: Promise<{
      decision: "allow" | "deny";
      note?: string;
      /** "Always allow": auto-approve future calls of this tool for the session. */
      remember?: boolean;
    }>;
  };
  cancelAll(note?: string): void;
}

export interface SessionDeps {
  send: SendFn;
  approvals: ApprovalGate;
  cwd: string;
  /**
   * Soft focus folder NAME (e.g. "jobhunt"), appended to the system prompt. The agent's cwd stays
   * at the project root, so this is only a steer toward one subfolder — never a sandbox. Undefined
   * means "work across the whole root".
   */
  folderHint?: string;
  model: string;
  /** Extended-thinking level for the first turn (default "off" when omitted). */
  thinking?: ThinkingLevel;
  /** Anthropic session id to resume, if reconnecting. */
  resume?: string;
  initialMode: PermissionMode;
  /** Notified once the SDK reports its session id (for resume bookkeeping). */
  onSessionId?: (sessionId: string) => void;
  /**
   * Opt the SDK into the user's settings (settingSources: ['user']) so the account's claude.ai
   * cloud connectors (Gmail, Drive, …) auto-load — the watch then has the same connectors as the
   * CLI. Off = the isolated default (no user settings, no connectors). Set from config.loadConnectors.
   */
  loadUserSettings?: boolean;
  /**
   * Auto-title this agent from its first prompt (a cheap one-shot Haiku call). Off = skip the
   * background call; the watch keeps its own instant first-words title. Set from config.autoTitle.
   */
  autoTitle?: boolean;
}

/**
 * Uniform session surface. The connection layer talks to this and never cares
 * whether it's the real agent or the scripted mock.
 */
export interface AgentSession {
  /** Begin a turn with the first user prompt. */
  start(prompt: string): Promise<void>;
  /** Queue a follow-up user turn into the live session. */
  sendFollowUp(text: string): void;
  /** Soft stop the current turn, keep the session alive (q.interrupt). */
  interrupt(): Promise<void>;
  /**
   * Compact the conversation IN PLACE — summarize the running context so the window frees up while
   * the SAME session continues (Claude keeps the summary). Unlike a fresh session (clear context),
   * the conversation isn't lost. No-op before the first turn — there's nothing to compact yet.
   */
  compact(): void;
  /** Hard teardown (abort + close). */
  cancel(): Promise<void>;
  /** Change permission posture mid-session. */
  setMode(mode: PermissionMode): void;
  /** Change model and/or thinking level; applies to the next turn (and live query if running). */
  setConfig(cfg: { model?: string; thinking?: ThinkingLevel }): void;
  /**
   * Re-emit the last-known context-occupancy frame, if any. Called on RECONNECT so the watch's
   * usage ring is repainted with the real value immediately on reopen — a cold-launched watch
   * resets its ring, and otherwise it would read empty/stale until the next turn produces usage.
   * No-op before any occupancy is known.
   */
  resendContext(): void;
  /** The Anthropic session id, once known (for resume). */
  readonly sessionId: string | undefined;
}

/* ───────────────────────────── tool summaries ───────────────────────────── */

export interface ToolSummary {
  title: string;
  subtitle?: string;
}

export interface PermissionMeta {
  kind: PermissionKind;
  risk: Risk;
  title: string;
  detail?: string;
  diff?: string;
  command?: string;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

function basename(p: string): string {
  const parts = p.split(/[\\/]/);
  return parts[parts.length - 1] || p;
}

/** Count added/removed lines for an Edit (old→new) into a "+N −M" subtitle. */
function diffStat(oldStr?: string, newStr?: string): string | undefined {
  if (oldStr === undefined && newStr === undefined) return undefined;
  const removed = oldStr ? oldStr.split("\n").length : 0;
  const added = newStr ? newStr.split("\n").length : 0;
  return `+${added} −${removed}`;
}

/**
 * Render a minimal unified-style diff. Not a real LCS diff — for tiny watch
 * cards we just show the old block as removed and the new block as added, which
 * is plenty to glance at and approve.
 */
export function renderDiff(
  file: string | undefined,
  oldStr: string | undefined,
  newStr: string | undefined,
): string {
  const name = file ? basename(file) : "file";
  const lines: string[] = [`--- a/${name}`, `+++ b/${name}`];
  if (oldStr) for (const l of oldStr.split("\n")) lines.push(`-${l}`);
  if (newStr) for (const l of newStr.split("\n")) lines.push(`+${l}`);
  return lines.join("\n");
}

/** Summarize a tool_use into a short title/subtitle for the watch. */
export function summarizeTool(name: string, input: Record<string, unknown>): ToolSummary {
  switch (name) {
    case "Read": {
      const f = str(input.file_path);
      return { title: f ? `Read ${basename(f)}` : "Read file", subtitle: f };
    }
    case "Edit":
    case "MultiEdit": {
      const f = str(input.file_path);
      return {
        title: f ? `Edit ${basename(f)}` : "Edit file",
        subtitle: diffStat(str(input.old_string), str(input.new_string)),
      };
    }
    case "Write": {
      const f = str(input.file_path);
      const content = str(input.content);
      return {
        title: f ? `Write ${basename(f)}` : "Write file",
        subtitle: content ? `${content.split("\n").length} lines` : undefined,
      };
    }
    case "Bash": {
      const cmd = str(input.command);
      return { title: "Run command", subtitle: cmd };
    }
    case "Glob":
      return { title: "Find files", subtitle: str(input.pattern) };
    case "Grep":
      return { title: "Search", subtitle: str(input.pattern) };
    case "WebFetch":
      return { title: "Fetch URL", subtitle: str(input.url) };
    case "WebSearch":
      return { title: "Web search", subtitle: str(input.query) };
    case "TodoWrite":
      return { title: "Update todos" };
    default:
      return { title: name };
  }
}

/**
 * Classify a tool call into permission kind + risk and build the approval card,
 * including a diff for edits/writes and the command line for Bash.
 */
export function permissionMeta(
  name: string,
  input: Record<string, unknown>,
): PermissionMeta {
  switch (name) {
    case "Bash": {
      const command = str(input.command) ?? "";
      const risk: Risk = /\b(rm|sudo|curl|wget|kill|dd|mkfs|:\(\)\{)/.test(command)
        ? "high"
        : /\b(git\s+push|npm\s+publish|rm\b)/.test(command)
          ? "medium"
          : "low";
      return {
        kind: "command",
        risk,
        title: "Run command",
        detail: command,
        command,
      };
    }
    case "Edit":
    case "MultiEdit": {
      const f = str(input.file_path);
      return {
        kind: "edit",
        risk: "low",
        title: f ? `Edit ${basename(f)}` : "Edit file",
        diff: renderDiff(f, str(input.old_string), str(input.new_string)),
      };
    }
    case "Write": {
      const f = str(input.file_path);
      return {
        kind: "write",
        risk: "medium",
        title: f ? `Write ${basename(f)}` : "Write file",
        diff: renderDiff(f, undefined, str(input.content)),
      };
    }
    default:
      return { kind: "other", risk: "low", title: name };
  }
}
