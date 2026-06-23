#!/usr/bin/env bash
# Install the Pinch LaunchAgents (backend server + public tunnel) so they start
# at login and restart on crash. Idempotent: re-running re-installs.
#
# Two supervised agents, each RunAtLoad + KeepAlive(on-crash) + throttled:
#   com.pinch.server   node dist/index.js   (binds 127.0.0.1:$PORT)
#   com.pinch.tunnel   ngrok | cloudflared  (exposes a stable public wss URL)
#
# Tunnel selection (TUNNEL env):
#   auto         (default) cloudflared if ~/.cloudflared/config.yml exists,
#                else ngrok if PINCH_NGROK_DOMAIN is set in backend/.env
#   ngrok        force the ngrok tunnel  (needs a reserved domain + authtoken)
#   cloudflared  force the cloudflared named tunnel
#
# Usage:
#   infra/launchd/install-launchd.sh
#   TUNNEL=ngrok infra/launchd/install-launchd.sh
#
# Override any of these via env before running:
#   NODE_BIN          path to node          (default: `command -v node`)
#   CLOUDFLARED_BIN   path to cloudflared   (default: `command -v cloudflared`)
#   NGROK_BIN         path to ngrok         (default: `command -v ngrok`)
#   BACKEND_DIR       backend workspace dir (default: <repo>/backend)
#   TUNNEL_CONFIG     cloudflared config    (default: $HOME/.cloudflared/config.yml)
#   NGROK_DOMAIN      reserved ngrok domain (default: PINCH_NGROK_DOMAIN from .env)
#   NGROK_CONFIG      ngrok.yml path        (default: macOS app-support path)
#   PORT              backend port          (default: PORT from .env, else 8787)
#   LOG_DIR           log directory         (default: $HOME/Library/Logs/pinch)
set -euo pipefail

# --- locate things ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/backend/.env"

# read a KEY=value from backend/.env (no surrounding quotes expected)
env_val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true; }

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared || true)}"
NGROK_BIN="${NGROK_BIN:-$(command -v ngrok || true)}"
BACKEND_DIR="${BACKEND_DIR:-$REPO_ROOT/backend}"
TUNNEL_CONFIG="${TUNNEL_CONFIG:-$HOME/.cloudflared/config.yml}"
NGROK_DOMAIN="${NGROK_DOMAIN:-$(env_val PINCH_NGROK_DOMAIN)}"
NGROK_CONFIG="${NGROK_CONFIG:-$HOME/Library/Application Support/ngrok/ngrok.yml}"
PORT="${PORT:-$(env_val PORT)}"; PORT="${PORT:-8787}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/pinch}"
LA_DIR="$HOME/Library/LaunchAgents"

# --- pick the tunnel --------------------------------------------------------
TUNNEL="${TUNNEL:-auto}"
if [[ "$TUNNEL" == "auto" ]]; then
  if [[ -f "$TUNNEL_CONFIG" ]]; then TUNNEL="cloudflared"
  elif [[ -n "$NGROK_DOMAIN" ]]; then TUNNEL="ngrok"
  else
    echo "error: no tunnel configured." >&2
    echo "       Either set up a cloudflared named tunnel (infra/cloudflared/README.md)" >&2
    echo "       or set PINCH_NGROK_DOMAIN in backend/.env (reserve a free static domain" >&2
    echo "       at dashboard.ngrok.com), then re-run." >&2
    exit 1
  fi
fi

# --- validate ---------------------------------------------------------------
fail=0
if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  echo "error: node not found. Set NODE_BIN=/abs/path/to/node" >&2; fail=1
fi
if [[ ! -d "$BACKEND_DIR" ]]; then
  echo "error: backend dir not found: $BACKEND_DIR" >&2; fail=1
fi
if [[ ! -f "$BACKEND_DIR/dist/index.js" ]]; then
  echo "warning: $BACKEND_DIR/dist/index.js missing — build first:" >&2
  echo "         npm run build --workspace backend" >&2
  # not fatal; you may build after install and kickstart.
fi

case "$TUNNEL" in
  cloudflared)
    TUNNEL_TEMPLATE="$SCRIPT_DIR/com.pinch.tunnel.plist"
    if [[ -z "$CLOUDFLARED_BIN" || ! -x "$CLOUDFLARED_BIN" ]]; then
      echo "error: cloudflared not found. brew install cloudflared, or set CLOUDFLARED_BIN" >&2; fail=1
    fi
    if [[ ! -f "$TUNNEL_CONFIG" ]]; then
      echo "error: tunnel config not found: $TUNNEL_CONFIG" >&2
      echo "       See infra/cloudflared/README.md for the one-time setup." >&2; fail=1
    fi
    ;;
  ngrok)
    TUNNEL_TEMPLATE="$SCRIPT_DIR/com.pinch.tunnel.ngrok.plist"
    if [[ -z "$NGROK_BIN" || ! -x "$NGROK_BIN" ]]; then
      echo "error: ngrok not found. brew install ngrok/ngrok/ngrok, or set NGROK_BIN" >&2; fail=1
    fi
    if [[ -z "$NGROK_DOMAIN" ]]; then
      echo "error: no ngrok domain. Set PINCH_NGROK_DOMAIN in backend/.env (reserve one" >&2
      echo "       free at dashboard.ngrok.com), or pass NGROK_DOMAIN=foo.ngrok-free.dev" >&2; fail=1
    fi
    if [[ ! -f "$NGROK_CONFIG" ]]; then
      echo "error: ngrok config not found: $NGROK_CONFIG" >&2
      echo "       Authenticate first: ngrok config add-authtoken <token>" >&2; fail=1
    fi
    ;;
  *)
    echo "error: unknown TUNNEL=$TUNNEL (use auto|ngrok|cloudflared)" >&2; fail=1
    ;;
esac
[[ "$fail" -eq 0 ]] || exit 1

mkdir -p "$LA_DIR" "$LOG_DIR"

GUI_DOMAIN="gui/$(id -u)"

# render <template> <dest> : substitute placeholders into a plist.
render() {
  local template="$1" dest="$2"
  # Use a delimiter unlikely to appear in paths; escape & and | for sed.
  sed \
    -e "s|__NODE_BIN__|$(printf '%s' "$NODE_BIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__CLOUDFLARED_BIN__|$(printf '%s' "$CLOUDFLARED_BIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__NGROK_BIN__|$(printf '%s' "$NGROK_BIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__BACKEND_DIR__|$(printf '%s' "$BACKEND_DIR" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__TUNNEL_CONFIG__|$(printf '%s' "$TUNNEL_CONFIG" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__NGROK_DOMAIN__|$(printf '%s' "$NGROK_DOMAIN" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__NGROK_CONFIG__|$(printf '%s' "$NGROK_CONFIG" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__PORT__|$(printf '%s' "$PORT" | sed 's/[&|]/\\&/g')|g" \
    -e "s|__LOG_DIR__|$(printf '%s' "$LOG_DIR" | sed 's/[&|]/\\&/g')|g" \
    "$template" > "$dest"
}

install_one() {
  local label="$1" template="$2"
  local dest="$LA_DIR/$label.plist"
  echo "Installing $label -> $dest"
  render "$template" "$dest"

  # bootout first (ignore failure if not loaded), then bootstrap + kickstart.
  launchctl bootout "$GUI_DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$GUI_DOMAIN" "$dest"
  launchctl kickstart -k "$GUI_DOMAIN/$label"
  echo "  loaded and kickstarted."
}

echo "Tunnel: $TUNNEL"
install_one "com.pinch.server" "$SCRIPT_DIR/com.pinch.server.plist"
install_one "com.pinch.tunnel" "$TUNNEL_TEMPLATE"

echo
echo "Done. Logs: $LOG_DIR/{server,tunnel}.{out,err}.log"
if [[ "$TUNNEL" == "ngrok" ]]; then
  echo "Watch URL:  wss://$NGROK_DOMAIN/ws   (token: PINCH_TOKEN in backend/.env)"
fi
echo "Check status:  launchctl print $GUI_DOMAIN/com.pinch.server | head -n 20"
echo "Stop/remove:   infra/launchd/uninstall-launchd.sh"
