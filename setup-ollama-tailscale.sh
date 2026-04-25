#!/usr/bin/env bash
# setup-ollama-tailscale.sh
# Sets up Ollama + Tailscale on a fresh Mac for a local inference cluster.
# Assumes Homebrew is already installed.
#
# Usage:   bash setup-ollama-tailscale.sh
# Tweak:   DEFAULT_MODEL=qwen2.5:7b DISABLE_SLEEP=1 bash setup-ollama-tailscale.sh
# Headless: INSTALL_GUI=0 bash setup-ollama-tailscale.sh

set -euo pipefail

# --- Config (override via env vars) --------------------------------------
OLLAMA_BIND="${OLLAMA_BIND:-0.0.0.0:11434}"            # listens on all interfaces (Tailscale + LAN + localhost)
DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:26b-mlx-bf16}"  # set to "" to skip pulling a model
DISABLE_SLEEP="${DISABLE_SLEEP:-0}"           # 1 = keep machine awake on AC power (needs sudo)
INSTALL_GUI="${INSTALL_GUI:-1}"               # 1 = also install the Ollama menu-bar GUI app (cask)
ALIAS_NAME="${ALIAS_NAME:-gemma:best}"        # alias to create from DEFAULT_MODEL; set "" to skip
# -------------------------------------------------------------------------

bold() { printf "\n\033[1m%s\033[0m\n" "$*"; }
info() { printf "  → %s\n" "$*"; }

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it first: https://brew.sh" >&2
  exit 1
fi

bold "1/6  Installing Ollama"
if brew list --formula ollama >/dev/null 2>&1; then
  info "formula (CLI/server) already installed"
else
  brew install ollama
fi
if [[ "$INSTALL_GUI" == "1" ]]; then
  if brew list --cask ollama-app >/dev/null 2>&1; then
    info "GUI app already installed"
  else
    brew install --cask ollama-app
  fi
else
  info "skipping GUI app (INSTALL_GUI=0)"
fi

bold "2/6  Installing Tailscale (GUI app)"
if brew list --cask tailscale-app >/dev/null 2>&1; then
  info "already installed"
else
  brew install --cask tailscale-app
fi

bold "3/6  Configuring Ollama to listen on $OLLAMA_BIND"
current_host="$(launchctl getenv OLLAMA_HOST 2>/dev/null || true)"
service_started=0
if brew services list 2>/dev/null | awk '$1=="ollama"{print $2}' | grep -q started; then
  service_started=1
fi
if [[ "$current_host" == "$OLLAMA_BIND" && "$service_started" == "1" ]]; then
  info "already configured and running"
else
  launchctl setenv OLLAMA_HOST "$OLLAMA_BIND"
  brew services restart ollama >/dev/null
  info "ollama service (re)started"
  # Give the daemon a beat to come up before we try to pull
  sleep 2
fi

bold "4/6  Launching Tailscale"
if pgrep -x Tailscale >/dev/null 2>&1; then
  info "already running"
else
  open -a Tailscale || true
  cat <<'EOF'
  → First run only: click the Tailscale menu-bar icon and sign in.
    Then visit https://login.tailscale.com/admin/dns and turn on MagicDNS
    so peers can be reached by hostname (e.g. macbook-pro.tail1234.ts.net).
EOF
fi

if [[ -n "$DEFAULT_MODEL" ]]; then
  bold "5/6  Pulling model: $DEFAULT_MODEL"
  ollama pull "$DEFAULT_MODEL"
else
  bold "5/6  Skipping model pull (DEFAULT_MODEL is empty)"
fi

if [[ -n "$DEFAULT_MODEL" && -n "$ALIAS_NAME" ]]; then
  if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$ALIAS_NAME"; then
    bold "6/6  Alias '$ALIAS_NAME' already exists"
    info "to recreate: ollama rm $ALIAS_NAME && rerun this script"
  else
    bold "6/6  Creating alias '$ALIAS_NAME' from $DEFAULT_MODEL"
    MODELFILE="$(mktemp -t ollama-modelfile)"
    trap 'rm -f "$MODELFILE"' EXIT
    cat >"$MODELFILE" <<EOF
FROM $DEFAULT_MODEL
PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 64
EOF
    ollama create "$ALIAS_NAME" -f "$MODELFILE"
    info "alias ready: ollama run $ALIAS_NAME"
  fi
else
  bold "6/6  Skipping alias creation"
fi

if [[ "$DISABLE_SLEEP" == "1" ]]; then
  bold "Bonus: disabling sleep on AC power (sudo required)"
  sudo pmset -c sleep 0 disablesleep 1
  info "run 'sudo pmset -c disablesleep 0' to undo"
fi

bold "Done."
cat <<'EOF'

Verify locally:
  curl http://127.0.0.1:11434/api/tags

From a Tailscale peer (after MagicDNS is on):
  curl http://$(hostname -s).<your-tailnet>.ts.net:11434/api/tags

Your Tailscale IPv4 (once signed in):
  /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
EOF
