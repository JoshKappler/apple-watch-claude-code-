/**
 * Real Claude Agent SDK session wrapper.
 *
 * Bridges the SDK's streaming event loop to the Pinch protocol. The SDK is
 * imported LAZILY via dynamic import() inside `start()` — so mock mode and the
 * rest of the server compile and run even if the (heavy) SDK package or an API
 * key is unavailable. Nothing at module scope touches the SDK.
 *
 * Design notes:
 *  - Streaming-input mode: `prompt` is an async generator we push user turns
 *    into (a queue + a resolver). This unlocks follow-up turns and q.interrupt().
 *  - includePartialMessages:true gives us raw SSE deltas → assistant_delta /
 *    thinking_delta. Whole `assistant` text blocks → assistant_message (TTS).
 *  - canUseTool parks a Promise in the approval registry, emits permission_request,
 *    resolves on the client's decision, and honors opts.signal (abort → deny).
 *  - bypassPermissions: we do NOT pass canUseTool (nothing asks).
 */
import { srv, type PermissionMode } from "@pinch/protocol";
import { log } from "./log.js";
import { generateAgentTitle } from "./titler.js";
import {
  permissionMeta,
  summarizeTool,
  thinkingConfig,
  type AgentSession,
  type SessionDeps,
  type ThinkingLevel,
} from "./sessionTypes.js";

/** Minimal local mirror of the SDK's streaming-input user message shape. */
interface SdkUserMessage {
  type: "user";
  message: { role: "user"; content: string };
  parent_tool_use_id: null;
}

/** Permission result the SDK's canUseTool must return. */
type PermissionResult =
  | { behavior: "allow"; updatedInput?: Record<string, unknown> }
  | { behavior: "deny"; message: string; interrupt?: boolean };

/**
 * Coalesce streaming SSE deltas into ~this many chars per emitted frame.
 *
 * Each frame the SDK streams becomes ONE entry in the session's bounded event-log ring
 * (sessionRegistry: EVENT_BUFFER_LIMIT). Unbatched, a single extended-thinking turn emits
 * hundreds–thousands of token-sized `thinking_delta` frames; they overflow the ring and trim the
 * turn's OWN earliest frames — the `status("thinking")` and first `thinking_delta` that drive the
 * watch's "thinking" indicator — before the watch ever polls them. The result is the
 * "connected but no thought process" symptom. Batching collapses a whole turn to well under the
 * ring size while still streaming progressively (one frame per ~sentence). Pairs with the
 * poll-gap signal in sessionRegistry.readEvents as belt-and-suspenders.
 */
const DELTA_FLUSH_CHARS = 256;

/**
 * Appended to the Claude Code preset system prompt for every session. Orients the
 * agent to the fact that it is talking to someone on an Apple Watch: replies are
 * READ ALOUD (TTS) and shown on a ~tiny screen, so Markdown/punctuation tricks
 * don't render and brevity matters. This shapes COMMUNICATION, plus one standing
 * work rule (the origin-main git default — no worktrees / no branch switching); the
 * rest of the coding work (tools, edits, rigor) is unchanged. Static string →
 * prompt-cached with the rest of the preset.
 */
const WATCH_SYSTEM_APPEND = `You are being driven from an Apple Watch. The person speaks to you by voice, and your replies are read aloud and shown on a tiny watch screen. This changes how you should communicate (not how you do the work):

- Write plain spoken text. There is NO Markdown rendering: asterisks, backticks, headers, bullet characters, tables, and emoji are not formatting here — they get read aloud literally or shown as raw symbols. Don't use them for emphasis or structure.
- Be as brief as possible while still answering completely. Lead with the answer or the result. Cut preamble, restated questions, and filler. One or two sentences is usually the right length; a glanceable screen can't hold a wall of text.
- When you genuinely need steps or choices, say them as a short numbered sequence in prose ("First… Second…", or "Option 1… Option 2…") so the person can answer by voice.
- Stay high-level. Report the general shape of what you did and anything important, risky, or irreversible — not a play-by-play. The person does NOT want file names or paths, code, raw command output, or a rundown of which files, languages, or tools were involved; leave all of that out unless they ask for it, or unless it is something they need to decide on. After multi-step work, a sentence or two on the overall result plus any risk is plenty. Spell out whatever you do say the way you would aloud.

Their words reach you through Apple's voice dictation, so expect transcription errors in what you receive: homophones and mangled technical terms (git heard as "get", npm as "MPM", Claude as "cloud", file and function names split or misspelled), missing punctuation, and stray capitalization. Read for intent rather than the literal characters — infer the obvious technical meaning from context instead of acting on a garbled word.

Do all coding, tool use, and verification exactly as rigorously as you normally would; only the wording of what you say back to the person should follow the rules above.

One standing work rule, the same in every project: keep git dead simple. Always commit and push to the repository's primary branch on origin, which is normally main. Never create git worktrees, never switch to or create another branch, never change which branch is primary, and never force-push or hard-reset — several agents may share one working tree and must not move it out from under each other. When a task is done and the code builds, commit everything and push it to origin. Only depart from this if the person explicitly tells you to for a specific task.`;

/**
 * Async generator you can push into. Resolves the seeded prompt first, then any
 * follow-up turns. Ends only when `close()` is called.
 */
class UserTurnQueue {
  private queue: SdkUserMessage[] = [];
  private resolver: ((v: IteratorResult<SdkUserMessage>) => void) | null = null;
  private closed = false;

  push(text: string): void {
    const msg: SdkUserMessage = {
      type: "user",
      message: { role: "user", content: text },
      parent_tool_use_id: null,
    };
    if (this.resolver) {
      const r = this.resolver;
      this.resolver = null;
      r({ value: msg, done: false });
    } else {
      this.queue.push(msg);
    }
  }

  close(): void {
    this.closed = true;
    if (this.resolver) {
      const r = this.resolver;
      this.resolver = null;
      r({ value: undefined as unknown as SdkUserMessage, done: true });
    }
  }

  async *iterate(): AsyncGenerator<SdkUserMessage> {
    while (true) {
      const next = this.queue.shift();
      if (next) {
        yield next;
        continue;
      }
      if (this.closed) return;
      const result = await new Promise<IteratorResult<SdkUserMessage>>(
        (resolve) => {
          this.resolver = resolve;
        },
      );
      if (result.done) return;
      yield result.value;
    }
  }
}

export class ClaudeSession implements AgentSession {
  private readonly deps: SessionDeps;
  private readonly turns = new UserTurnQueue();
  private readonly abort = new AbortController();
  private mode: PermissionMode;
  /** Active model id; applied at query creation and via setModel() mid-session. */
  private model: string;
  /** Active thinking level; applied via the SDK `thinking` option / setMaxThinkingTokens(). */
  private thinking: ThinkingLevel;
  // `Query` from the SDK, kept loosely typed so this file never imports SDK types.
  // Mutating methods are only available in streaming-input mode (which we use).
  private query:
    | (AsyncGenerator<unknown> & {
        interrupt(): Promise<void>;
        setPermissionMode(mode: PermissionMode): Promise<void>;
        setModel(model?: string): Promise<void>;
        setMaxThinkingTokens(
          maxThinkingTokens: number | null,
        ): Promise<void>;
        close(): void;
      })
    | null = null;
  private started = false;
  private _sessionId: string | undefined;
  /** Coalescing buffer for streaming deltas (see DELTA_FLUSH_CHARS). */
  private deltaBuf = "";
  private deltaKind: "thinking" | "text" | null = null;
  /**
   * Tool names the user chose "Always allow" for — auto-approved for the rest of this session
   * (granularity is per tool NAME: allowing one Edit allows all Edits until the session ends).
   * In-memory only, so a fresh session starts asking again.
   */
  private readonly rememberedTools = new Set<string>();
  /**
   * Last MAIN-THREAD occupancy (NUMERATOR) we emitted for the usage ring, cached so a reconnect can
   * repaint the ring (resendContext) instead of leaving a cold-launched watch empty until the next
   * turn. The DENOMINATOR stays the static `contextWindowFor` value (the CLI-matched 200k) on
   * purpose — that scale is already validated; the long-standing inaccuracy was the numerator
   * reading subagent/mid-tool frames, not the window.
   */
  private lastContextUsed = 0;

  constructor(deps: SessionDeps) {
    this.deps = deps;
    this.mode = deps.initialMode;
    this.model = deps.model;
    this.thinking = deps.thinking ?? "off";
    this._sessionId = deps.resume;
  }

  get sessionId(): string | undefined {
    return this._sessionId;
  }

  async start(prompt: string): Promise<void> {
    if (this.started) {
      this.sendFollowUp(prompt);
      return;
    }

    // LAZY import — nothing above module scope touches the SDK.
    const { query } = await import("@anthropic-ai/claude-agent-sdk");

    const options: Record<string, unknown> = {
      cwd: this.deps.cwd,
      model: this.model,
      systemPrompt: {
        type: "preset",
        preset: "claude_code",
        append: this.systemAppend(),
      },
      includePartialMessages: true,
      abortController: this.abort,
      permissionMode: this.mode,
      // REQUIRED so the session may run in (or switch to) bypassPermissions at all.
      // Without it the SDK rejects permissionMode:'bypassPermissions' and
      // setPermissionMode('bypassPermissions') with:
      //   "Cannot set permission mode to bypassPermissions because the session
      //    was not launched with --dangerously-skip-permissions"
      // (sdk.d.ts: Options.allowDangerouslySkipPermissions — "Must be set to true
      //  when using permissionMode: 'bypassPermissions'").
      allowDangerouslySkipPermissions: true,
      // Extended-thinking budget (off/low/medium/high → SDK ThinkingConfig).
      thinking: thinkingConfig(this.thinking),
    };
    // Opt into the user's settings so the account's claude.ai cloud connectors (Gmail, Drive, …)
    // auto-load and the watch gets the same tools as the CLI. Without this the SDK runs isolated
    // with no connectors (the default that left the watch tool-less). Gated by config.loadConnectors
    // (PINCH_LOAD_CONNECTORS); the kill-switch exists because loading user settings can also pull in
    // user hooks/skills that bloat a turn.
    if (this.deps.loadUserSettings) options.settingSources = ["user"];
    if (this.deps.resume) options.resume = this.deps.resume;
    // bypassPermissions: nothing asks → do NOT wire canUseTool.
    if (this.mode !== "bypassPermissions") {
      options.canUseTool = this.makeCanUseTool();
    }

    // Construct the query BEFORE committing `started`/turns. The lazy import above and this
    // query() construction are the only setup steps that can throw; doing them first means a
    // setup failure leaves us fully re-startable (started stays false, no turn enqueued), so
    // handlePrompt can 500 and the watch's outbox retries cleanly instead of dropping the prompt.
    // (turns.iterate() is a live generator — it simply parks until the first push below, so
    // wiring it into query() before pushing is safe.)
    const q = query({
      prompt: this.turns.iterate(),
      options,
    }) as ClaudeSession["query"];

    this.started = true;
    this.query = q;
    this.turns.push(prompt);
    void this.consume();

    // Auto-title this agent from its FIRST prompt, fire-and-forget, so the switcher names it after
    // what it's doing. Fresh sessions only — a RESUME (revive) already carries its title on the
    // watch, and re-titling from a mid-conversation prompt would be wrong. Never blocks the turn.
    if (this.deps.autoTitle && !this.deps.resume) void this.titleFromFirstPrompt(prompt);
  }

  /** Generate + emit this agent's title from its first prompt (see titler.ts). Best-effort. */
  private async titleFromFirstPrompt(prompt: string): Promise<void> {
    const title = await generateAgentTitle({
      prompt,
      cwd: this.deps.cwd,
      signal: this.abort.signal,
    });
    if (title && !this.abort.signal.aborted) this.deps.send(srv.agentTitle(title));
  }

  sendFollowUp(text: string): void {
    this.turns.push(text);
  }

  /**
   * Compact the conversation IN PLACE. Implemented by feeding the `/compact` slash command into the
   * streaming input: the claude_code preset runs compaction on the live session, summarizing the
   * history so the context window frees up while the session (and Claude's memory of the summary)
   * keeps going — unlike clearContext, which spins a brand-new, memory-less session. The SDK emits a
   * `compact_boundary` system message when it's done (handled in handleCompactBoundary) to surface a
   * notice + the new usage. The closing `result` frame completes the turn via handleResult.
   *
   * No-op before the first turn — there's no context to compact, and starting one just to compact
   * nothing would be confusing. We tell the watch instead of silently doing nothing.
   */
  compact(): void {
    if (!this.started) {
      this.deps.send(
        srv.notice("info", "Nothing to compact yet — send a message first."),
      );
      return;
    }
    // Follow-up turns don't re-emit a thinking status, so push one ourselves for immediate feedback
    // (the watch's working indicator + timer key off it; handleResult's idle clears them).
    this.deps.send(srv.status("thinking"));
    this.deps.send(srv.notice("info", "Compacting context…"));
    this.turns.push("/compact");
  }

  /**
   * The system-prompt append for this session: the static watch-orientation block, plus a soft
   * focus line when a folder hint is set. The agent's cwd is always the project root, so the hint
   * only STEERS it toward one subfolder; it keeps full access to everything under the root.
   */
  private systemAppend(): string {
    const hint = this.deps.folderHint;
    if (!hint) return WATCH_SYSTEM_APPEND;
    return `${WATCH_SYSTEM_APPEND}

The person has set your focus to the "${hint}" directory inside the project root. Work primarily there — cd into it for commands and prefer files under it — unless a task clearly needs something elsewhere under the root. You still have full access to the whole root.`;
  }

  async interrupt(): Promise<void> {
    // Soft stop: end the current turn but keep the session alive.
    this.deps.approvals.cancelAll("cancelled");
    try {
      await this.query?.interrupt();
    } catch (err) {
      log.warn({ err }, "interrupt failed");
    }
  }

  async cancel(): Promise<void> {
    // Hard teardown: abort, close the queue, close the query.
    this.deps.approvals.cancelAll("cancelled");
    this.abort.abort();
    this.turns.close();
    try {
      this.query?.close();
    } catch (err) {
      log.debug({ err }, "query close failed");
    }
  }

  setMode(mode: PermissionMode): void {
    this.mode = mode;
    // setPermissionMode returns a Promise; swallow rejections so a failed switch
    // never crashes the turn. The next query() (resume) also carries the mode.
    this.query?.setPermissionMode(mode).catch((err) => {
      log.warn({ err }, "setPermissionMode failed");
    });
  }

  /**
   * Apply a new model and/or thinking level. Stored on the session so the NEXT
   * turn always uses them, and pushed to the live query immediately when one is
   * running (setModel / setMaxThinkingTokens are streaming-input-only methods).
   */
  setConfig(cfg: { model?: string; thinking?: ThinkingLevel }): void {
    if (cfg.model && cfg.model !== this.model) {
      this.model = cfg.model;
      this.query?.setModel(cfg.model).catch((err) => {
        log.warn({ err }, "setModel failed");
      });
    }
    if (cfg.thinking && cfg.thinking !== this.thinking) {
      this.thinking = cfg.thinking;
      const tc = thinkingConfig(this.thinking);
      // setMaxThinkingTokens(0) disables; any positive value enables that budget.
      const tokens =
        tc.type === "enabled" ? (tc.budgetTokens ?? 0) : 0;
      this.query?.setMaxThinkingTokens(tokens).catch((err) => {
        log.warn({ err }, "setMaxThinkingTokens failed");
      });
    }
  }

  /** Build the async permission callback the SDK awaits. */
  private makeCanUseTool() {
    return async (
      toolName: string,
      input: Record<string, unknown>,
      opts: { signal: AbortSignal; toolUseID: string },
    ): Promise<PermissionResult> => {
      // acceptEdits: auto-approve edits/writes; everything else still asks.
      // NOTE: an "allow" MUST echo back `updatedInput` — without it the SDK runs
      // the tool with empty input and the Edit/Write silently fails.
      if (
        this.mode === "acceptEdits" &&
        (toolName === "Edit" ||
          toolName === "MultiEdit" ||
          toolName === "Write")
      ) {
        return { behavior: "allow", updatedInput: input };
      }

      // "Always allow" chosen earlier this session for this tool → auto-approve, don't ask again.
      if (this.rememberedTools.has(toolName)) {
        return { behavior: "allow", updatedInput: input };
      }

      const meta = permissionMeta(toolName, input);
      const { requestId, wait } = this.deps.approvals.create();

      this.deps.send(srv.status("waiting_permission"));
      this.deps.send(
        srv.permissionRequest({
          requestId,
          tool: toolName,
          title: meta.title,
          detail: meta.detail,
          risk: meta.risk,
          kind: meta.kind,
          diff: meta.diff,
          command: meta.command,
        }),
      );

      // Race the client's decision against an abort (wrist-shake cancel).
      const aborted = new Promise<PermissionResult>((resolve) => {
        if (opts.signal.aborted) {
          resolve({ behavior: "deny", message: "aborted", interrupt: true });
          return;
        }
        opts.signal.addEventListener(
          "abort",
          () =>
            resolve({
              behavior: "deny",
              message: "aborted",
              interrupt: true,
            }),
          { once: true },
        );
      });

      const decided = wait.then<PermissionResult>((outcome) => {
        // `updatedInput: input` is REQUIRED — an allow without it makes the SDK
        // run the tool with empty input, so Edit/Write/Bash silently no-op.
        if (outcome.decision === "allow") {
          // "Always allow" → remember this tool so the rest of the session won't re-ask.
          if (outcome.remember) this.rememberedTools.add(toolName);
          return { behavior: "allow", updatedInput: input };
        }
        return {
          behavior: "deny",
          message: outcome.note ?? "Denied on the watch.",
        };
      });

      const result = await Promise.race([decided, aborted]);
      this.deps.send(srv.status("running_tool"));
      return result;
    };
  }

  /** Drain the SDK message stream and translate each event to a protocol frame. */
  private async consume(): Promise<void> {
    if (!this.query) return;
    try {
      this.deps.send(srv.status("thinking"));
      for await (const raw of this.query) {
        this.handleMessage(raw as Record<string, unknown>);
      }
      // Stream ended cleanly — emit any tail the last block didn't flush.
      this.flushDeltas();
    } catch (err) {
      // Flush buffered deltas before the terminal frames so partial thinking/text isn't lost
      // behind a cancelled/error frame.
      this.flushDeltas();
      if (this.abort.signal.aborted) {
        // Expected on cancel — surface a clean cancelled turn.
        this.deps.send(srv.turnComplete("cancelled"));
        this.deps.send(srv.status("idle"));
        return;
      }
      log.error({ err }, "agent stream error");
      this.deps.send(srv.error(messageOf(err), false));
      this.deps.send(srv.turnComplete("error"));
      this.deps.send(srv.status("error"));
    }
  }

  private handleMessage(m: Record<string, unknown>): void {
    const type = m.type as string;

    // Streaming deltas are coalesced (see handlePartial); everything else is a DISCRETE frame
    // that must land after any buffered deltas, so flush before handling it. This keeps order
    // exact: a turn's thinking/text always precedes its tool_use / assistant message / result.
    if (type === "partial_assistant") {
      this.handlePartial((m as { stream_event?: unknown }).stream_event);
      return;
    }
    this.flushDeltas();

    if (type === "system" && (m as { subtype?: string }).subtype === "init") {
      const sid = (m as { session_id?: string }).session_id;
      if (sid) {
        this._sessionId = sid;
        this.deps.onSessionId?.(sid);
      }
      return;
    }

    if (
      type === "system" &&
      (m as { subtype?: string }).subtype === "compact_boundary"
    ) {
      this.handleCompactBoundary(m);
      return;
    }

    if (type === "assistant") {
      this.handleAssistant(m);
      return;
    }

    if (type === "user") {
      this.handleUserToolResults(m);
      return;
    }

    if (type === "result") {
      this.handleResult(m);
      return;
    }
  }

  /** Emit any buffered streaming text as ONE delta frame, preserving its kind and order. */
  private flushDeltas(): void {
    const text = this.deltaBuf;
    const kind = this.deltaKind;
    this.deltaBuf = "";
    this.deltaKind = null;
    if (!text || !kind) return;
    this.deps.send(
      kind === "thinking" ? srv.thinkingDelta(text) : srv.assistantDelta(text),
    );
  }

  /**
   * Raw Anthropic SSE event → streaming deltas, COALESCED. We accumulate same-kind delta text and
   * emit it in ~DELTA_FLUSH_CHARS chunks (and at each content-block boundary) instead of one frame
   * per token. See DELTA_FLUSH_CHARS for why: it keeps a thinking-heavy turn from overflowing the
   * event-log ring and trimming its own opening frames.
   */
  private handlePartial(event: unknown): void {
    if (!event || typeof event !== "object") return;
    const ev = event as {
      type?: string;
      delta?: { type?: string; text?: string; thinking?: string };
    };
    // End of a content block → flush so the next block (or the assistant message) starts clean.
    if (ev.type === "content_block_stop") {
      this.flushDeltas();
      return;
    }
    if (ev.type !== "content_block_delta" || !ev.delta) return;
    let kind: "thinking" | "text" | null = null;
    let chunk = "";
    if (ev.delta.type === "text_delta" && ev.delta.text) {
      kind = "text";
      chunk = ev.delta.text;
    } else if (ev.delta.type === "thinking_delta" && ev.delta.thinking) {
      kind = "thinking";
      chunk = ev.delta.thinking;
    } else {
      return;
    }
    // A kind switch (e.g. thinking → text) flushes the prior buffer first so frames stay ordered.
    if (this.deltaKind && this.deltaKind !== kind) this.flushDeltas();
    this.deltaKind = kind;
    this.deltaBuf += chunk;
    if (this.deltaBuf.length >= DELTA_FLUSH_CHARS) this.flushDeltas();
  }

  /** Whole assistant message: text blocks (TTS) + tool_use blocks. */
  private handleAssistant(m: Record<string, unknown>): void {
    const message = m.message as
      | { content?: unknown; usage?: Record<string, unknown> }
      | undefined;
    // Report context-window occupancy for the watch's usage ring ONLY from MAIN-THREAD messages.
    // A SUBAGENT's assistant message (parent_tool_use_id set / subagent_type present) carries the
    // SUBAGENT's much smaller prompt size, not the main conversation's — letting it drive the ring
    // makes it lurch down to a sub-step's occupancy. Last-write-wins is then correct: within the
    // main thread each request's input grows monotonically, so the turn's final main message holds
    // the true occupancy. (This is the long-standing inaccuracy — the ring was reading subagent and
    // mid-tool frames the whole time.)
    const isSubagent =
      m.parent_tool_use_id != null || typeof m.subagent_type === "string";
    if (!isSubagent) this.reportContext(message?.usage);
    const content = message?.content;
    if (!Array.isArray(content)) return;
    for (const block of content as Array<Record<string, unknown>>) {
      const bt = block.type as string;
      if (bt === "text" && typeof block.text === "string" && block.text.trim()) {
        this.deps.send(srv.assistantMessage(block.text));
      } else if (bt === "tool_use") {
        const id = String(block.id ?? "");
        const name = String(block.name ?? "tool");
        const input = (block.input as Record<string, unknown>) ?? {};
        const summary = summarizeTool(name, input);
        this.deps.send(srv.status("running_tool"));
        this.deps.send(
          srv.toolUse({
            id,
            name,
            title: summary.title,
            subtitle: summary.subtitle,
            input,
          }),
        );
      }
    }
  }

  /**
   * Emit a context-occupancy frame from an assistant message's usage block. Sums the
   * input + cached input tokens (the full prompt size for that request) against the
   * model's context window. No-ops when usage is missing or zero.
   */
  private reportContext(usage: Record<string, unknown> | undefined): void {
    if (!usage) return;
    const n = (k: string): number =>
      typeof usage[k] === "number" ? (usage[k] as number) : 0;
    const used =
      n("input_tokens") +
      n("cache_read_input_tokens") +
      n("cache_creation_input_tokens");
    if (used <= 0) return;
    this.lastContextUsed = used;
    const window = contextWindowFor(this.model);
    // Silent by default (pino level=info); set LOG_LEVEL=debug to watch the exact numerator the ring
    // gets, turn by turn. If the meter ever reads wrong again, compare these to the CLI's /context:
    // a mismatch is now a NUMBER you can see, not a guess — which is what cost the prior fix attempts.
    log.debug(
      { used, window, pct: Math.round((used / window) * 100), model: this.model },
      "ctx: occupancy frame",
    );
    this.deps.send(srv.context(used, window));
  }

  /** See AgentSession.resendContext — repaint the ring on reconnect from the cached occupancy. */
  resendContext(): void {
    if (this.lastContextUsed > 0) {
      this.deps.send(srv.context(this.lastContextUsed, contextWindowFor(this.model)));
    }
  }

  /** user message carrying tool_result blocks. */
  private handleUserToolResults(m: Record<string, unknown>): void {
    const message = m.message as { content?: unknown } | undefined;
    const content = message?.content;
    if (!Array.isArray(content)) return;
    for (const block of content as Array<Record<string, unknown>>) {
      if (block.type !== "tool_result") continue;
      const id = String(block.tool_use_id ?? "");
      const ok = block.is_error !== true;
      this.deps.send(
        srv.toolResult({ id, ok, summary: summarizeResult(block.content) }),
      );
    }
  }

  /**
   * The SDK's post-compaction marker (system/compact_boundary). Report how much the window freed
   * and refresh the usage ring with the new (smaller) occupancy so the watch reflects the compaction
   * immediately, instead of waiting for the next turn's usage to trickle in.
   */
  private handleCompactBoundary(m: Record<string, unknown>): void {
    const meta = (
      m as {
        compact_metadata?: { pre_tokens?: number; post_tokens?: number };
      }
    ).compact_metadata;
    const pre = typeof meta?.pre_tokens === "number" ? meta.pre_tokens : undefined;
    const post =
      typeof meta?.post_tokens === "number" ? meta.post_tokens : undefined;
    if (post !== undefined && post > 0) {
      this.lastContextUsed = post;
      this.deps.send(srv.context(post, contextWindowFor(this.model)));
    }
    const summary =
      pre !== undefined && post !== undefined && pre > 0
        ? `Context compacted — ${Math.round((1 - post / pre) * 100)}% smaller.`
        : "Context compacted.";
    this.deps.send(srv.notice("info", summary));
  }

  private handleResult(m: Record<string, unknown>): void {
    const subtype = String(m.subtype ?? "success");
    const sid = (m as { session_id?: string }).session_id;
    if (sid) {
      this._sessionId = sid;
      this.deps.onSessionId?.(sid);
    }
    const stop =
      subtype === "success"
        ? "end_turn"
        : subtype === "error_max_turns"
          ? "max_turns"
          : "error";
    this.deps.send(srv.turnComplete(stop));
    this.deps.send(srv.status("idle"));
  }
}

/**
 * Context-window size (tokens) for a model id, used to scale the watch's usage ring —
 * matched to what the Claude Code CLI meters against, NOT the model's raw API maximum.
 *
 * Opus 4.8 / Sonnet 4.6 / Fable 5 advertise a 1M context window over the API, but that
 * 1M is an opt-in beta. The Agent SDK session we drive here never sends the 1M-context
 * beta header, so the model's effective window is the standard 200k — the same number the
 * Claude Code CLI shows on its context meter and auto-compacts against. Scaling the ring to
 * 1M made it read ~5x too empty (a real ~250k turn showed as 25% instead of "full, compact
 * now"). Haiku 4.5 is natively a 200k model, so it lands here too.
 */
function contextWindowFor(model: string): number {
  switch (model) {
    case "claude-haiku-4-5-20251001":
    case "claude-opus-4-8":
    case "claude-sonnet-4-6":
    case "claude-fable-5":
      return 200_000;
    default:
      // Unknown/future model: assume the standard 200k window the CLI uses by default.
      return 200_000;
  }
}

/** Best-effort one-line summary of a tool_result content payload. */
function summarizeResult(content: unknown): string | undefined {
  if (typeof content === "string") return clip(content);
  if (Array.isArray(content)) {
    const text = content
      .map((c) =>
        c && typeof c === "object" && "text" in c
          ? String((c as { text: unknown }).text)
          : "",
      )
      .join(" ")
      .trim();
    return text ? clip(text) : undefined;
  }
  return undefined;
}

function clip(s: string, max = 120): string {
  const oneLine = s.replace(/\s+/g, " ").trim();
  return oneLine.length > max ? oneLine.slice(0, max - 1) + "…" : oneLine;
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Factory matching the mock session's export shape. */
export function createClaudeSession(deps: SessionDeps): AgentSession {
  return new ClaudeSession(deps);
}
