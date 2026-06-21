# Decisions (with the why)

Made autonomously from three Opus research passes (watchOS APIs, Claude Agent SDK, connectivity).
Each call lists the alternative and why it lost. Sources are in the research; this is the distilled "why."

## 1. Engine: Claude Agent SDK, not SSH-to-a-terminal
The watch could SSH into a Mac running the Claude Code CLI. Rejected: SSH gives a raw TTY — you'd be
reading ANSI-colored scrollback through a 1.9" screen and "approving" by typing. The **Agent SDK**
(`@anthropic-ai/claude-agent-sdk`) emits *structured* events: "this is assistant text," "this is a tool
call," "this needs permission." That structure is exactly what a glanceable watch UI and TTS need, and
it's the **same engine and the same tools** as the CLI, so autonomy is identical. The watch becomes a
clean remote, not a tiny terminal.

## 2. "Dangerously skip permissions" = `permissionMode: "bypassPermissions"`
The SDK exposes the real thing. Modes: `default` (ask via `canUseTool`), `acceptEdits` (edits auto, bash
asks), `plan` (read-only), `bypassPermissions` (nothing asks — the dangerous one), plus `dontAsk`/`auto`.
We surface default/acceptEdits/plan/bypass. Entering bypass requires a guarded confirm on the watch.

## 3. Remote approval via the async `canUseTool` callback
`canUseTool(toolName, input, {signal}) => Promise<PermissionResult>` — it can **await**. So the flow is:
SDK calls it → we emit `permission_request` to the watch → we park a Promise keyed by requestId → the
watch taps ✓/✗ → the WS handler resolves the Promise → we return `{behavior:"allow"}` or
`{behavior:"deny", message}`. The `signal` lets a wrist-shake cancel abort a pending approval cleanly.
This is the load-bearing integration and it's a first-class SDK capability, not a hack.

## 4. Streaming: `includePartialMessages: true`
Without it the SDK only yields whole assistant messages. With it we get `partial_assistant` →
`stream_event` (raw Anthropic SSE: `text_delta`, `thinking_delta`). We forward text deltas as
`assistant_delta` for a live-typing feel, and emit a consolidated `assistant_message` per text block
for clean TTS readback. Tool calls come from `assistant` content blocks of type `tool_use`; tool results
from `user` messages with `tool_result` blocks. `session_id` is captured from the `system`/`init` message.

## 5. Streaming-input mode (async-iterable prompt)
We pass `prompt` as an `AsyncIterable<SDKUserMessage>` rather than a one-shot string, because that's what
unlocks **follow-up turns into a live session** and **`q.interrupt()`** (graceful stop). One-shot string
prompts can only be killed with `abort()`. The watch needs both follow-ups and a soft stop, so streaming
input it is.

## 6. Cancel = `q.interrupt()` (soft) + AbortController (hard)
Wrist-shake → `interrupt()` stops the current turn but keeps the session alive (you can immediately say
something else). A disconnect/teardown uses `abort()`/`close()`.

## 7. Auth to Anthropic: `ANTHROPIC_API_KEY`
The SDK can locally reuse Claude Code OAuth creds, but Anthropic restricts subscription/claude.ai-login
auth for third-party products built on the Agent SDK. So we ship with `ANTHROPIC_API_KEY` and document it.

## 8. Transport: WebSocket; backend runs where the repos are; public via Cloudflare Tunnel
- **WebSocket** (not REST polling): the session is a live bidirectional stream of deltas, tool events,
  and permission round-trips. WS is the natural fit.
- **Backend on the Mac** by default: it sees your *actual* working tree, including uncommitted changes.
  A **cloud mode** (Fly.io machine that clones from GitHub) is also provided for always-on, accepting it
  only sees pushed code. (Vercel is unsuitable for the WS/agent process — no persistent sockets even with
  Fluid Compute; it's the wrong shape for a long-running stateful agent.)
- **Cloudflare named Tunnel** for the public URL: free, full WebSocket support, your own stable hostname,
  TLS terminated at the edge. ngrok reserved domain is the zero-config fallback. Tailscale Funnel was
  rejected for this use — current WS drop/query-strip bugs make it unreliable for a cellular client.

## 9. Cellular realities baked into the protocol
- **100s Cloudflare idle timeout** → the client sends an app-level `ping` every ~25s; the server replies
  `pong` and also runs its own ws-level ping/terminate dead-socket sweep.
- **No background WebSocket on watchOS** → the socket only lives while the app is foreground. The client
  reconnects on activation with exponential backoff + jitter, and **resumes** the agent session
  (`resumeSessionId`) so a turn that ran while disconnected isn't lost. The backend buffers events per
  session so a reconnecting watch can be caught up.
- **APNs alert push** is the re-engagement path for long tasks (a background push wakes the user to come
  look; the app reconnects in foreground). Wired as a stub — needs your Apple push key to go live.

## 10. Gesture bindings — what's actually exposed
- **Double-tap = send.** Real dev API `.handGestureShortcut(.primaryAction)`, **watchOS 11+ and Ultra 2+
  only**. We feature-detect; on Ultra 1 / older watchOS the on-screen Send button is the path. Only one
  primary action per screen, and it can't live inside a scrolling List (the system claims double-tap for
  scroll there) — so Send lives on a fixed bottom bar.
- **Digital Crown = scroll** transcript / scrub diff hunks (`.digitalCrownRotation`). Crown *press* is
  system-reserved (can't intercept) — not used for app logic.
- **Wrist shake = cancel.** No public shake event on watchOS; we detect it with CoreMotion
  `userAcceleration` magnitude over a threshold with debounce (foreground only).
- **Push-to-talk = on-screen mic button** (hold) using `SFSpeechRecognizer` + `AVAudioEngine`. The
  **Action button is NOT used** for this by default: third-party Action-button support is gated behind a
  workout/dive session model, which we won't masquerade as. (An optional workout-framed intent is
  documented for power users who want the physical button.)
- **Taps = approve/decline** permission cards, pick projects, toggle mode.
- TTS readback via `AVSpeechSynthesizer`, **always paired with a haptic** because watch TTS can be silent
  without AirPods connected.

## 11. A browser "watch simulator" is part of the build
Because there's no web runtime on watchOS and signing/installing the real app needs your Apple Developer
account interactively, the only way to verify the whole system *today* is a reference client. The
`simulator/` is a browser watch face speaking the exact same protocol (Web Speech for voice, SpeechSynthesis
for TTS). It's how the backend gets tested end-to-end now, and it doubles as a desk client.

## 12. A mock agent mode for keyless testing
The backend has a `PINCH_MOCK=1` mode that emits scripted protocol events (assistant text, a tool call, a
permission request, a result) with **no API key and no SDK call**. This let the build be verified
end-to-end before you've added your key, and it's a safe demo mode.

## Security posture (it's RCE-as-a-service)
Bearer device token validated on the WS handshake (header preferred; first-frame `auth` for the browser
sim, which can't set WS headers), constant-time compare, TLS-only, per-device revocation, project-path
allowlist with traversal rejection, rate limiting, run as a non-admin user. Optional Cloudflare Access
service-token / mTLS as an edge gate so unauthenticated traffic never reaches Node.
