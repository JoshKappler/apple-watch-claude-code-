#!/usr/bin/env bash
# Pinch backend self-restart — spawned (detached) by POST /api/restart (httpApi.handleRestart) so
# you can apply backend code changes you made FROM the watch without touching the Mac.
#
# Order is deliberate: we BUILD FIRST, while the OLD backend ($1 = its pid) keeps serving on the
# same port, and only kill + relaunch if the build SUCCEEDS. A failed build leaves the running
# tether untouched, so a typo in a watch-driven edit can never strand the watch with no backend to
# reach. Detached + nohup so this script (and the new process) outlive the backend that spawned it.
#
# Args: $1 = pid of the currently-running backend to replace (optional but expected).
set -uo pipefail

OLD_PID="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="/tmp/pinch-backend.log"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /opt/homebrew/bin/node)}"
# Make npm/node resolvable even when the backend was GUI-launched with a minimal PATH (npm lives
# next to node — e.g. /opt/homebrew/bin). Harmless when the dir is already on PATH.
export PATH="$(dirname "$NODE_BIN"):$PATH"

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
say(){ printf '[restart %s] %s\n' "$(ts)" "$1" >>"$LOG" 2>&1; }

say "rebuild requested (old pid=${OLD_PID:-unknown})"

# 1. Build the whole TS workspace (protocol + backend). The OLD backend keeps serving meanwhile;
#    overwriting dist/ under a running node is safe — it already loaded the old modules into memory.
if ! ( cd "$REPO_ROOT" && npm run build ) >>"$LOG" 2>&1; then
  say "build FAILED — keeping the old backend alive, NOT restarting"
  exit 1
fi
say "build OK"

# 2. Build succeeded → stop the old process and wait for it to release the port (~up to 10s).
if [[ -n "$OLD_PID" ]]; then
  kill "$OLD_PID" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 0.2; done
fi

# 3. Relaunch detached from backend/ (so dotenv finds backend/.env), exactly like start-pinch.command.
cd "$REPO_ROOT/backend"
nohup "$NODE_BIN" dist/index.js >>"$LOG" 2>&1 &
say "new backend started (pid=$!) on the same port"
