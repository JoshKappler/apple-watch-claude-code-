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
    this.started = true;
    this.turns.push(prompt);

    // LAZY import — nothing above module scope touches the SDK.
    const { query } = await import("@anthropic-ai/claude-agent-sdk");

    const options: Record<string, unknown> = {
      cwd: this.deps.cwd,
      model: this.model,
      systemPrompt: { type: "preset", preset: "claude_code" },
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
    if (this.deps.resume) options.resume = this.deps.resume;
    // bypassPermissions: nothing asks → do NOT wire canUseTool.
    if (this.mode !== "bypassPermissions") {
      options.canUseTool = this.makeCanUseTool();
    }

    this.query = query({
      prompt: this.turns.iterate(),
      options,
    }) as ClaudeSession["query"];

    void this.consume();
  }

  sendFollowUp(text: string): void {
    this.turns.push(text);
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
    } catch (err) {
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

    if (type === "system" && (m as { subtype?: string }).subtype === "init") {
      const sid = (m as { session_id?: string }).session_id;
      if (sid) {
        this._sessionId = sid;
        this.deps.onSessionId?.(sid);
      }
      return;
    }

    if (type === "partial_assistant") {
      this.handlePartial((m as { stream_event?: unknown }).stream_event);
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

  /** Raw Anthropic SSE event → streaming deltas. */
  private handlePartial(event: unknown): void {
    if (!event || typeof event !== "object") return;
    const ev = event as { type?: string; delta?: { type?: string; text?: string; thinking?: string } };
    if (ev.type !== "content_block_delta" || !ev.delta) return;
    if (ev.delta.type === "text_delta" && ev.delta.text) {
      this.deps.send(srv.assistantDelta(ev.delta.text));
    } else if (ev.delta.type === "thinking_delta" && ev.delta.thinking) {
      this.deps.send(srv.thinkingDelta(ev.delta.thinking));
    }
  }

  /** Whole assistant message: text blocks (TTS) + tool_use blocks. */
  private handleAssistant(m: Record<string, unknown>): void {
    const message = m.message as { content?: unknown } | undefined;
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
