/**
 * Scripted mock session — same AgentSession interface, zero SDK, zero API key.
 *
 * Emits a believable turn with small timers so it feels live in the simulator:
 *   status thinking → assistant_delta chunks → tool_use(Read) → tool_result
 *   → permission_request(Edit + diff) → on allow: tool_result + assistant_message
 *   → turn_complete(end_turn) → status idle
 *
 * This is decision #12 in docs/DECISIONS.md: verify the whole system end-to-end
 * before any credentials exist, and a safe demo mode.
 */
import { srv, type PermissionMode } from "@pinch/protocol";
import { log } from "./log.js";
import {
  renderDiff,
  type AgentSession,
  type SessionDeps,
  type ThinkingLevel,
} from "./sessionTypes.js";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Mirror of session.ts `contextWindowFor`: the effective context window the CLI meters
 * against — a flat 200k for every current model (the 1M window is an opt-in beta the
 * session never enables), so the mock's usage ring reads at the same scale as the real one.
 */
function mockContextWindowFor(_model: string): number {
  return 200_000;
}

const SAMPLE_DIFF = renderDiff(
  "settings.tsx",
  '  return <div className="settings">',
  '  return (\n    <div className="settings">\n      {loading && <Spinner />}',
);

export class MockSession implements AgentSession {
  private readonly deps: SessionDeps;
  private mode: PermissionMode;
  private cancelled = false;
  private running = false;
  private turn = 0;
  /** Fake running context occupancy so the watch's usage ring fills across turns. */
  private contextUsed = 12_000;
  readonly sessionId: string;

  constructor(deps: SessionDeps) {
    this.deps = deps;
    this.mode = deps.initialMode;
    this.sessionId = deps.resume ?? `mock_${Date.now().toString(36)}`;
    deps.onSessionId?.(this.sessionId);
  }

  async start(prompt: string): Promise<void> {
    void this.runTurn(prompt);
  }

  sendFollowUp(text: string): void {
    void this.runTurn(text);
  }

  async interrupt(): Promise<void> {
    this.cancelled = true;
    this.deps.approvals.cancelAll("cancelled");
  }

  async cancel(): Promise<void> {
    this.cancelled = true;
    this.deps.approvals.cancelAll("cancelled");
  }

  setMode(mode: PermissionMode): void {
    this.mode = mode;
  }

  setConfig(_cfg: { model?: string; thinking?: ThinkingLevel }): void {
    // Mock has no real model/thinking; accept and ignore for interface parity.
  }

  resendContext(): void {
    // Repaint the ring on reconnect with the fake running occupancy (interface parity with the
    // real session, and keeps the mock's ring honest across an app reopen).
    this.deps.send(
      srv.context(this.contextUsed, mockContextWindowFor(this.deps.model)),
    );
  }

  compact(): void {
    // Fake the real session's compaction so the watch's Compact button is exercisable end-to-end in
    // mock mode: shrink the running occupancy, report it, and surface the same notice + clean turn.
    this.deps.send(srv.status("thinking"));
    const before = this.contextUsed;
    this.contextUsed = Math.max(8_000, Math.round(this.contextUsed * 0.3));
    this.deps.send(
      srv.context(this.contextUsed, mockContextWindowFor(this.deps.model)),
    );
    const pct = before > 0 ? Math.round((1 - this.contextUsed / before) * 100) : 0;
    this.deps.send(srv.notice("info", `Context compacted — ${pct}% smaller.`));
    this.deps.send(srv.turnComplete("end_turn"));
    this.deps.send(srv.status("idle"));
  }

  private async runTurn(prompt: string): Promise<void> {
    if (this.running) {
      // Mirror the real session: queue is implicit; just chain after a beat.
      await sleep(50);
    }
    this.running = true;
    this.cancelled = false;
    const turnId = ++this.turn;
    const t = (n: number) => `${n}_${turnId}`;

    try {
      this.deps.send(srv.status("thinking"));
      // Mirror the real session's auto-title: emit a 1-3 word agent_title on the FIRST turn so the
      // watch's switcher-naming path is exercisable end-to-end in mock mode (no LLM — just the
      // prompt's first words, Title Cased).
      if (turnId === 1) {
        const title = prompt
          .trim()
          .split(/\s+/)
          .slice(0, 3)
          .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
          .join(" ");
        if (title) this.deps.send(srv.agentTitle(title));
      }
      // Grow fake context occupancy each turn so the watch's usage ring visibly fills.
      // Use the SAME per-model windows the real session reports, so the ring reads
      // honestly in mock mode too (flat 200k made it ~5x too full on 1M models).
      const window = mockContextWindowFor(this.deps.model);
      this.contextUsed = Math.min(this.contextUsed + 23_000, window);
      this.deps.send(srv.context(this.contextUsed, window));
      this.deps.send(srv.thinkingDelta("Looking at the settings page…"));
      await sleep(400);
      if (this.bail()) return;

      for (const chunk of [
        "I'll start by ",
        `reading the file related to "`,
        clip(prompt),
        '" and then make the change.',
      ]) {
        this.deps.send(srv.assistantDelta(chunk));
        await sleep(180);
        if (this.bail()) return;
      }

      // tool_use(Read) → tool_result
      this.deps.send(srv.status("running_tool"));
      this.deps.send(
        srv.toolUse({
          id: t(1),
          name: "Read",
          title: "Read settings.tsx",
          subtitle: "src/pages/settings.tsx",
          input: { file_path: "src/pages/settings.tsx" },
        }),
      );
      await sleep(500);
      if (this.bail()) return;
      this.deps.send(
        srv.toolResult({ id: t(1), ok: true, summary: "42 lines" }),
      );
      await sleep(250);
      if (this.bail()) return;

      // permission_request(Edit) — auto-allowed under acceptEdits/bypass.
      const autoAllow =
        this.mode === "acceptEdits" || this.mode === "bypassPermissions";
      let allowed = autoAllow;

      if (!autoAllow) {
        const { requestId, wait } = this.deps.approvals.create();
        this.deps.send(srv.status("waiting_permission"));
        this.deps.send(
          srv.permissionRequest({
            requestId,
            tool: "Edit",
            title: "Edit settings.tsx",
            detail: "Add a loading spinner",
            risk: "low",
            kind: "edit",
            diff: SAMPLE_DIFF,
          }),
        );
        const outcome = await wait;
        if (this.bail()) return;
        allowed = outcome.decision === "allow";
      }

      this.deps.send(srv.status("running_tool"));
      this.deps.send(
        srv.toolUse({
          id: t(2),
          name: "Edit",
          title: "Edit settings.tsx",
          subtitle: "+3 −1",
          input: { file_path: "src/pages/settings.tsx" },
        }),
      );
      await sleep(350);
      if (this.bail()) return;

      if (!allowed) {
        this.deps.send(
          srv.toolResult({ id: t(2), ok: false, summary: "declined" }),
        );
        this.deps.send(
          srv.assistantMessage(
            "Okay, I won't make that edit. Let me know what you'd like instead.",
          ),
        );
        this.deps.send(srv.turnComplete("end_turn"));
        this.deps.send(srv.status("idle"));
        return;
      }

      this.deps.send(
        srv.toolResult({ id: t(2), ok: true, summary: "applied" }),
      );
      await sleep(300);
      if (this.bail()) return;

      this.deps.send(
        srv.assistantMessage(
          "Done. I added a loading spinner to the settings page and wired it to the existing loading state.",
        ),
      );
      this.deps.send(srv.turnComplete("end_turn"));
      this.deps.send(srv.status("idle"));
    } catch (err) {
      log.error({ err }, "mock turn error");
      this.deps.send(srv.error("mock failure", false));
      this.deps.send(srv.turnComplete("error"));
      this.deps.send(srv.status("error"));
    } finally {
      this.running = false;
    }
  }

  /** If cancelled, emit a clean cancelled turn and signal the caller to stop. */
  private bail(): boolean {
    if (!this.cancelled) return false;
    this.deps.send(srv.turnComplete("cancelled"));
    this.deps.send(srv.status("idle"));
    return true;
  }
}

function clip(s: string, max = 40): string {
  const one = s.replace(/\s+/g, " ").trim();
  return one.length > max ? one.slice(0, max - 1) + "…" : one;
}

export function createMockSession(deps: SessionDeps): AgentSession {
  return new MockSession(deps);
}
