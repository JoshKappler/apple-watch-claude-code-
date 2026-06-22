# Status — what's done, what's verified, what needs you

_Built autonomously while you were getting the charging cable. Everything below is on `main`._

## One line
The whole system is written and the server side is **verified working end-to-end**. To actually talk to
a repo from your wrist you need to do three things only you can do: add an API key, sign the watch app in
Xcode with your Apple Developer account, and run the Cloudflare tunnel login once.

---

## What's built and verified ✅

| Piece | State | Evidence |
|---|---|---|
| **Wire protocol** (`packages/protocol`) | Done | builds clean; 22 message types; Swift mirror matches exactly |
| **Backend** (`backend`) | Done + **verified** | typechecks; runs; **smoke test passes** the full round-trip; bad token → 4401 |
| **Simulator** (`simulator`) | Done + **verified** | typechecks; production build = 25 KB gzipped |
| **watchOS app** (`watch`) | Source complete | 21 Swift files; all pass `swiftc -parse`; needs Xcode to compile/sign (see below) |
| **Infra** (`infra`) | Done | Cloudflare Tunnel + launchd + Fly.io cloud mode + token gen + security; scripts pass `bash -n` |

The smoke test (`scripts/smoke-test.mjs`) drove a real WebSocket session against the backend and confirmed:
`auth → ready → prompt → thinking → streaming text → Read tool → permission request → (allow) → Edit tool
→ spoken result → turn_complete → idle`. That's the entire interaction loop, including the async
permission approval that the watch's ✓/✗ taps drive. It ran in **mock mode**, so no API key was needed to
prove the plumbing.

## Try it right now (no watch, no API key)
```bash
npm install
PINCH_MOCK=1 PINCH_TOKEN=test-token npm run dev          # backend on ws://localhost:8787/ws
# in another shell:
PINCH_TOKEN=test-token node scripts/smoke-test.mjs        # watch it round-trip
npm run sim                                                # or open the browser watch and click around
```

---

## What needs you (the parts I can't do autonomously)

1. **Anthropic API key** — to use the real agent instead of mock. `cd backend && cp .env.example .env`,
   set `ANTHROPIC_API_KEY`, set `PINCH_PROJECTS` to the absolute path(s) of the repo(s) you want it to
   work in, set `PINCH_MOCK=0`. (Run `./setup.sh` to scaffold `.env` + generate your `PINCH_TOKEN`.)
2. **Xcode + your Apple Developer account** — to put the app on your Ultra. `brew install xcodegen`, then
   `cd watch && xcodegen generate && open Pinch.xcodeproj`. Set your **Team**, change the bundle id to one
   you own, Run on the watch. This Mac only has Command Line Tools (no watchOS SDK), so I couldn't compile
   or sign it — but the source is complete, parses clean, and the protocol mirror is exact. Full details
   in `watch/README.md`.
3. **Cloudflare tunnel login (once)** — to get the public URL for cellular. `cloudflared login`, then
   `cloudflared tunnel create pinch` and follow `infra/cloudflared/README.md`. Until then the browser
   simulator works over `ws://localhost` on your LAN.
4. **(Optional) APNs key** — to enable the "long task finished, come look" push. The watch registers and
   posts its token to `<server>/register-push`; wiring the send side needs an APNs `.p8`. Stubbed and
   documented in `watch/Sources/PushRegistration.swift`.

Full from-zero walkthrough: **`docs/SETUP.md`**.

---

## Control map (Apple Watch Ultra)
| Control | Action |
|---|---|
| **Double-tap (pinch)** | **Send message** — `.handGestureShortcut(.primaryAction)`, Ultra 2+/watchOS 11 |
| Hold mic button | Push-to-talk dictation |
| Digital Crown | Scroll transcript / scrub a diff |
| **Wrist shake** | **Cancel** the in-flight turn |
| Tap ✓ / ✗ | Approve / decline an edit or command |
| Mode menu → bypass | "Dangerously skip permissions" (guarded confirm) |

## Honest caveats (all from the research, all documented)
- **Double-tap is Series 9 / Ultra 2 and later only.** On an original Ultra the on-screen Send button is
  the path (the app feature-detects and degrades).
- **Watch TTS can be silent without AirPods/Bluetooth.** So every spoken reply is paired with a haptic,
  and there's a speaker toggle. If you want to reliably *hear* replies, wear AirPods.
- **No background WebSocket on watchOS.** The socket lives while the app is foreground; it reconnects and
  resumes the session on reopen, and APNs is the re-engagement path for long tasks.
- **The Action button is not used by default** — third-party Action-button support is gated behind a
  workout/dive session model. Push-to-talk is the on-screen mic + double-tap instead. An optional
  workout-framed intent is included but off by default for anyone who wants the physical button.
- **Agent SDK is v0.3.x (pre-1.0).** Its surface can still move; the version is pinned. `zod` is on v4 to
  satisfy the SDK's peer dependency.
- **This is remote code execution as a service.** The bearer token is the only thing between the public
  internet and an agent that can run `bash` in your repos. Treat the token like an SSH key; revoke it if a
  device is lost. Optionally put Cloudflare Access in front. See `infra/SECURITY.md`.

## Cost shape
- Mac + Cloudflare Tunnel = **$0** infra (you already pay for the watch's cellular plan and your Anthropic
  usage). Always-on cloud mode (Fly.io) is ~$2–20/mo and only sees pushed code.

## Repo map
`backend/` server · `watch/` watchOS app · `simulator/` browser test client · `packages/protocol/` wire
contract · `infra/` deploy · `docs/` PLAN, DECISIONS, SETUP, STATUS · `scripts/smoke-test.mjs` verifier.
