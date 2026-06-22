#!/usr/bin/env bash
# Pinch bootstrap. Friendly, idempotent, non-destructive.
# - Checks for node + cloudflared
# - Copies backend/.env.example -> backend/.env if absent (NEVER overwrites)
# - Generates a PINCH_TOKEN and drops it in if the .env's PINCH_TOKEN is empty
# - Prints next steps
#
# Safe to run repeatedly. It will not clobber an existing .env or an existing token.
set -euo pipefail

# Resolve the repo root from this script's location (path may contain spaces).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

BACKEND_DIR="$REPO_ROOT/backend"
ENV_FILE="$BACKEND_DIR/.env"
ENV_EXAMPLE="$BACKEND_DIR/.env.example"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  • %s\n' "$1"; }

bold "Pinch setup"
echo

# --- 1. tool checks ---------------------------------------------------------
bold "1. Checking tools"
if command -v node >/dev/null 2>&1; then
  ok "node $(node --version)"
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  if [[ "$node_major" -lt 20 ]]; then
    warn "Node 20+ recommended (found $(node --version))."
  fi
else
  warn "node not found. Install Node 20+ before running the backend."
fi

if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared present"
else
  warn "cloudflared not found (only needed for the Cloudflare Tunnel path)."
  info "Install with: brew install cloudflared"
fi
echo

# --- 2. backend/.env --------------------------------------------------------
bold "2. backend/.env"
if [[ -f "$ENV_FILE" ]]; then
  ok "backend/.env already exists — leaving it untouched."
else
  if [[ -f "$ENV_EXAMPLE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok "Created backend/.env from .env.example (chmod 600)."
  else
    warn "backend/.env.example not found; cannot create backend/.env."
  fi
fi
echo

# --- 3. PINCH_TOKEN ---------------------------------------------------------
bold "3. PINCH_TOKEN"
GEN_TOKEN="$REPO_ROOT/infra/scripts/gen-token.mjs"
if [[ -f "$ENV_FILE" ]] && command -v node >/dev/null 2>&1 && [[ -f "$GEN_TOKEN" ]]; then
  # Is PINCH_TOKEN present and non-empty?
  current="$(grep -E '^PINCH_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
  if [[ -n "${current//[[:space:]]/}" ]]; then
    ok "PINCH_TOKEN already set — leaving it as is."
  else
    token="$(node "$GEN_TOKEN" --raw)"
    if grep -qE '^PINCH_TOKEN=' "$ENV_FILE"; then
      # Replace the empty assignment in place (portable: rewrite via a temp file).
      tmp="$(mktemp)"
      # shellcheck disable=SC2016
      awk -v tok="$token" '
        /^PINCH_TOKEN=/ { print "PINCH_TOKEN=" tok; next }
        { print }
      ' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
    else
      printf 'PINCH_TOKEN=%s\n' "$token" >> "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    ok "Generated a PINCH_TOKEN and wrote it to backend/.env."
    info "Use the SAME token in the watch app / simulator."
  fi
else
  warn "Skipped token generation (need node + backend/.env + infra/scripts/gen-token.mjs)."
fi
echo

# --- 4. watch pairing secret (gitignored) -----------------------------------
bold "4. Watch pairing secret (watch/Sources/Secrets.swift)"
SECRETS_EXAMPLE="$REPO_ROOT/watch/Secrets.example.swift"
SECRETS_FILE="$REPO_ROOT/watch/Sources/Secrets.swift"
if [[ -f "$SECRETS_FILE" ]]; then
  ok "watch/Sources/Secrets.swift already exists — leaving it untouched."
elif [[ -f "$SECRETS_EXAMPLE" ]]; then
  cp "$SECRETS_EXAMPLE" "$SECRETS_FILE"
  # Inject PINCH_TOKEN from .env so the new Secrets.swift is ready to build.
  if [[ -f "$ENV_FILE" ]]; then
    tok="$(grep -E '^PINCH_TOKEN=' "$ENV_FILE" | head -n1 | cut -d= -f2- || true)"
    if [[ -n "${tok//[[:space:]]/}" ]]; then
      tmp="$(mktemp)"
      # shellcheck disable=SC2016
      awk -v tok="$tok" '
        /static let token =/ { print "    static let token = \"" tok "\""; next }
        { print }
      ' "$SECRETS_FILE" > "$tmp" && mv "$tmp" "$SECRETS_FILE"
      ok "Created watch/Sources/Secrets.swift (gitignored) with PINCH_TOKEN filled in."
    else
      ok "Created watch/Sources/Secrets.swift (gitignored)."
    fi
  fi
  info "Edit serverURL in it to your tunnel URL (pinch-up.sh prints one)."
else
  warn "watch/Secrets.example.swift not found; cannot create Secrets.swift."
fi
echo

# --- 5. reminders -----------------------------------------------------------
bold "5. Still needed in backend/.env"
info "ANTHROPIC_API_KEY=...      (or use PINCH_AUTH=subscription, the default)"
info "PINCH_PROJECT_ROOTS=...    (a parent dir to scan, e.g. ~/Desktop/projects —"
info "                            every child repo shows up on the watch)"
info "PINCH_PROJECTS=...         (optional: explicit ABSOLUTE repo paths to also allow)"
echo

# --- next steps -------------------------------------------------------------
bold "Next steps"
cat <<'EOF'
  1. Edit backend/.env: set PINCH_PROJECT_ROOTS (and auth — see above).
  2. Install deps:        npm install
  3. Test with the sim:   npm run sim        (open the browser "watch")
  4. Start a remote session the watch can reach, in ONE command:
       ./pinch-up.sh      (builds, runs the backend, opens a tunnel,
                           and prints the exact wss URL + token to enter)
  5. In the watch/sim, set URL = wss://<your-host>/ws and the PINCH_TOKEN.

  Stable URL across runs: reserve a domain and pass PINCH_NGROK_DOMAIN=...,
  or set up the named Cloudflare Tunnel (infra/cloudflared/README.md).

  Full walkthrough: docs/SETUP.md   •   Security: infra/SECURITY.md
EOF
