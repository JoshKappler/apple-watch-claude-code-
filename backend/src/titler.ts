/**
 * Agent auto-titler — turns an agent's FIRST prompt into a 1-3 word label for the watch's switcher.
 *
 * One-shot, cheap, fire-and-forget. It runs through the SAME Agent SDK the real session uses (NOT a
 * raw Anthropic client) on purpose: in the default `subscription` auth mode there is no API key — the
 * SDK authenticates via the Mac's Claude Code keychain login, so a direct SDK/HTTP call would have no
 * credentials. We force the cheap Haiku model, no tools, a single turn, and a hard timeout so a slow
 * or wedged title call can never affect the real turn. Any failure resolves to `null` (the watch keeps
 * its own instant first-words title).
 */
import { log } from "./log.js";

/** The cheap model used only for titling — independent of the session's PINCH_MODEL. */
const TITLE_MODEL = "claude-haiku-4-5-20251001";

const TITLE_SYSTEM =
  "You label developer tasks for a tiny watch screen. Given the user's message, reply with ONLY a " +
  "1 to 3 word title in Title Case that names the task — no punctuation, no quotes, no preamble, no " +
  "trailing period. Examples: 'Crown Haptics', 'Fix Login Bug', 'Resume Parser'.";

/** Hard ceiling so a wedged title call never lingers. */
const TITLE_TIMEOUT_MS = 12_000;

export async function generateAgentTitle(opts: {
  prompt: string;
  cwd: string;
  /** The session's abort signal — a cancelled/destroyed session kills the title call too. */
  signal?: AbortSignal;
}): Promise<string | null> {
  const text = opts.prompt.trim();
  if (!text) return null;
  if (opts.signal?.aborted) return null;

  const ac = new AbortController();
  const onAbort = () => ac.abort();
  opts.signal?.addEventListener("abort", onAbort, { once: true });
  const timer = setTimeout(() => ac.abort(), TITLE_TIMEOUT_MS);

  try {
    const { query } = await import("@anthropic-ai/claude-agent-sdk");
    const q = query({
      // Cap the input — a title only needs the gist, and the first prompt can be long dictation.
      prompt: text.slice(0, 2000),
      options: {
        cwd: opts.cwd,
        model: TITLE_MODEL,
        systemPrompt: TITLE_SYSTEM,
        maxTurns: 1,
        // `tools: []` is the switch that makes this a PURE text completion. (allowedTools is only the
        // auto-approve permission list — with it the SDK still hands the model the full toolset and it
        // runs the whole agentic loop, grepping the repo, instead of just answering.) settingSources:[]
        // skips loading the project's CLAUDE.md / skills / connectors, and thinking is off — both keep
        // it fast and on-task.
        tools: [],
        settingSources: [],
        thinking: { type: "disabled" },
        abortController: ac,
      },
    }) as AsyncIterable<Record<string, unknown>>;

    // Prefer the final `result` text; fall back to accumulated assistant text blocks.
    let out = "";
    for await (const m of q) {
      const mt = (m as { type?: string }).type;
      if (mt === "result") {
        const r = (m as { result?: unknown }).result;
        if (typeof r === "string" && r.trim()) out = r;
      } else if (mt === "assistant") {
        const content = (m as { message?: { content?: unknown } }).message?.content;
        if (Array.isArray(content)) {
          for (const block of content as Array<Record<string, unknown>>) {
            if (block.type === "text" && typeof block.text === "string" && !out) out += block.text;
          }
        }
      }
    }
    return cleanTitle(out);
  } catch (err) {
    if (!ac.signal.aborted) log.warn({ err }, "agent titler failed");
    return null;
  } finally {
    clearTimeout(timer);
    opts.signal?.removeEventListener("abort", onAbort);
  }
}

/**
 * Normalize the model's reply into a clean ≤3-word label, or null if it doesn't look like one (a
 * refusal, a sentence, empty) — in which case the caller keeps the watch's own derived title.
 */
function cleanTitle(raw: string): string | null {
  const cleaned = raw
    .replace(/[\r\n]+/g, " ")
    .replace(/["'`*_#]/g, "") // stray quotes / markdown
    .trim()
    .replace(/[.!?,;:]+$/, ""); // trailing punctuation
  if (!cleaned) return null;
  const title = cleaned.split(/\s+/).slice(0, 3).join(" ");
  // A real label is short; anything long is a sentence/refusal — reject it.
  if (title.length === 0 || title.length > 40) return null;
  return title;
}
