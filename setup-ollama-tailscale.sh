#!/usr/bin/env bash
# setup-ollama-tailscale.sh
# Sets up Ollama + Tailscale on a fresh Mac for a local inference cluster.
# Assumes Homebrew is already installed.
#
# Usage:    bash setup-ollama-tailscale.sh
# Tweak:    DEFAULT_MODEL=qwen2.5:7b DISPLAY_SLEEP_MIN=15 bash setup-ollama-tailscale.sh
# Headless: INSTALL_GUI=0 bash setup-ollama-tailscale.sh
# Sleeper:  AWAKE_ON_AC=0 bash setup-ollama-tailscale.sh    # keep stock pmset settings

set -euo pipefail

# --- Config (override via env vars) --------------------------------------
OLLAMA_BIND="${OLLAMA_BIND:-0.0.0.0:11434}"            # listens on all interfaces (Tailscale + LAN + localhost)
OLLAMA_KEEP_ALIVE_VAL="${OLLAMA_KEEP_ALIVE_VAL:--1}"   # -1 = pin loaded model in memory forever
OLLAMA_MAX_LOADED="${OLLAMA_MAX_LOADED:-1}"            # 1 = only one model resident at a time
DEFAULT_MODEL="${DEFAULT_MODEL:-gemma4:26b-mlx-bf16}"  # set to "" to skip pulling a model
AWAKE_ON_AC="${AWAKE_ON_AC:-1}"               # 1 = on AC, never sleep (incl. lid closed); needs sudo
DISPLAY_SLEEP_MIN="${DISPLAY_SLEEP_MIN:-10}"  # blank the display after N minutes on AC (0 = never)
LOCK_ON_SLEEP="${LOCK_ON_SLEEP:-1}"           # 1 = require password as soon as display sleeps
INSTALL_GUI="${INSTALL_GUI:-0}"               # 0 = CLI/server only (recommended); 1 = also install the Ollama menu-bar GUI app (cask)
EXCLUDE_BACKUPS="${EXCLUDE_BACKUPS:-1}"       # 1 = skip Time Machine + Spotlight on ~/.ollama/models
INSTALL_HEALTHCHECK="${INSTALL_HEALTHCHECK:-1}"  # 1 = LaunchAgent that probes /api/tags every 60s
INSTALL_AUTOUPDATE="${INSTALL_AUTOUPDATE:-1}"    # 1 = enable macOS auto security updates + weekly brew upgrade
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
  # Ensure the GUI app is absent — remove it if found so it can't race our LaunchAgent for port 11434.
  if brew list --cask ollama-app >/dev/null 2>&1; then
    info "removing ollama-app cask (CLI LaunchAgent owns the server)"
    # Kill the running app and its embedded server before uninstalling.
    pkill -x "Ollama" 2>/dev/null || true
    pkill -f "Ollama.app/Contents/Resources/ollama" 2>/dev/null || true
    # Suppress SMAppService / login-item registration so it doesn't re-register on next open.
    launchctl disable "gui/$(id -u)/com.ollama.Ollama" 2>/dev/null || true
    osascript -e 'tell application "System Events" to delete (login items where name is "Ollama")' 2>/dev/null || true
    brew uninstall --cask ollama-app
    info "ollama-app removed"
  else
    info "ollama-app not installed — nothing to remove"
  fi
fi

bold "2/6  Installing Tailscale (GUI app)"
if brew list --cask tailscale-app >/dev/null 2>&1; then
  info "already installed"
else
  brew install --cask tailscale-app
fi

bold "3/6  Configuring Ollama (bind=$OLLAMA_BIND keep_alive=$OLLAMA_KEEP_ALIVE_VAL max_loaded=$OLLAMA_MAX_LOADED)"

OLLAMA_BIN="$(brew --prefix)/bin/ollama"
if [[ ! -x "$OLLAMA_BIN" ]]; then
  echo "  ! ollama binary not found at $OLLAMA_BIN" >&2
  exit 1
fi

# Stop brew's ollama service so it doesn't compete with our LaunchAgent.
# We manage ollama ourselves so env vars are baked into the plist (no
# launchctl-setenv race that left OLLAMA_KEEP_ALIVE / OLLAMA_MAX_LOADED_MODELS
# unset for ollama after a reboot).
if brew services list 2>/dev/null | awk '$1=="ollama"{print $2}' | grep -q started; then
  brew services stop ollama >/dev/null
  info "stopped brew's ollama service (replaced with com.user.ollama)"
fi
launchctl bootout "gui/$(id -u)/homebrew.mxcl.ollama" 2>/dev/null || true

# Clean up the previous PERSIST_ENV launchagent and the launchd-domain env
# vars; both are obsolete now that env is baked into our plist.
LEGACY_PLIST="$HOME/Library/LaunchAgents/com.user.ollama-env.plist"
if [[ -f "$LEGACY_PLIST" ]]; then
  launchctl unload "$LEGACY_PLIST" 2>/dev/null || true
  rm -f "$LEGACY_PLIST"
  info "removed legacy launchagent com.user.ollama-env"
fi
launchctl unsetenv OLLAMA_HOST 2>/dev/null || true
launchctl unsetenv OLLAMA_KEEP_ALIVE 2>/dev/null || true
launchctl unsetenv OLLAMA_MAX_LOADED_MODELS 2>/dev/null || true

# Install our LaunchAgent with env vars baked in via EnvironmentVariables.
# launchd spawns ollama with these vars set every time, no race possible.
PLIST_LABEL="com.user.ollama"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_PATH="$HOME/Library/Logs/ollama.log"
TMP_PLIST="$(mktemp -t ollama-plist)"
cat >"$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${OLLAMA_BIN}</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key>
    <string>${OLLAMA_BIND}</string>
    <key>OLLAMA_KEEP_ALIVE</key>
    <string>${OLLAMA_KEEP_ALIVE_VAL}</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key>
    <string>${OLLAMA_MAX_LOADED}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST
mkdir -p "$(dirname "$PLIST_PATH")" "$(dirname "$LOG_PATH")"
if [[ -f "$PLIST_PATH" ]] && cmp -s "$TMP_PLIST" "$PLIST_PATH"; then
  info "launchagent ${PLIST_LABEL} already current"
  rm -f "$TMP_PLIST"
  if ! launchctl list "$PLIST_LABEL" >/dev/null 2>&1; then
    launchctl load "$PLIST_PATH"
    info "loaded existing launchagent"
  fi
else
  mv "$TMP_PLIST" "$PLIST_PATH"
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  info "installed launchagent ${PLIST_LABEL}"
fi

# Force CLI calls in *this* script to connect via loopback regardless of bind addr.
OLLAMA_PORT="${OLLAMA_BIND##*:}"
export OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}"

# Wait for the daemon to actually bind the port.
info "waiting for ollama daemon on $OLLAMA_HOST"
for i in $(seq 1 30); do
  if curl -fsS "http://${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    info "ollama is responsive"
    break
  fi
  if [[ "$i" == "30" ]]; then
    echo "  ! ollama daemon did not become responsive within 30s" >&2
    echo "    check: tail -f \"$LOG_PATH\"" >&2
    exit 1
  fi
  sleep 1
done

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

if [[ "$AWAKE_ON_AC" == "1" ]]; then
  bold "Bonus: power policy on AC (display sleeps after ${DISPLAY_SLEEP_MIN}m, lid-close safe)"
  # sleep 0          = system never auto-sleeps on AC
  # displaysleep N   = blank display after N minutes (0 = never)
  # disablesleep 1   = block sleep entirely, including on lid close
  # autorestart 1    = boot back up after a power failure
  # womp 1           = wake on network (magic packet)
  # powernap 0       = no spurious wake/sleep cycles for background tasks
  sudo pmset -c \
    sleep 0 \
    displaysleep "$DISPLAY_SLEEP_MIN" \
    disablesleep 1 \
    autorestart 1 \
    womp 1 \
    powernap 0
  info "pmset: never sleep, lid-close safe, auto-restart on power loss, wake on network"
fi

if [[ "$LOCK_ON_SLEEP" == "1" ]]; then
  bold "Bonus: lock screen as soon as the display sleeps"
  defaults write com.apple.screensaver askForPassword -int 1
  defaults write com.apple.screensaver askForPasswordDelay -int 0
  info "screen will lock immediately on display sleep"
fi

if [[ "$EXCLUDE_BACKUPS" == "1" ]]; then
  bold "Bonus: excluding ~/.ollama/models from Time Machine + Spotlight"
  mkdir -p "$HOME/.ollama/models"
  # tmutil addexclusion is idempotent (no error if already excluded)
  tmutil addexclusion "$HOME/.ollama/models" 2>/dev/null || true
  # Drop the well-known sentinel file Spotlight respects to skip indexing
  touch "$HOME/.ollama/models/.metadata_never_index"
  info "Time Machine: ~/.ollama/models excluded; Spotlight: .metadata_never_index in place"
fi

if [[ "$INSTALL_HEALTHCHECK" == "1" ]]; then
  bold "Bonus: ollama health check (probe /api/tags every 60s, kickstart on hang)"
  HC_LABEL="com.user.ollama-healthcheck"
  HC_PATH="$HOME/Library/LaunchAgents/${HC_LABEL}.plist"
  HC_LOG="$HOME/Library/Logs/${HC_LABEL}.log"
  TMP_HC="$(mktemp -t ollama-healthcheck-plist)"
  cat >"$TMP_HC" <<HC
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${HC_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>curl -fsS --max-time 5 http://127.0.0.1:${OLLAMA_PORT}/api/tags >/dev/null 2>&amp;1 || { echo "\$(date): /api/tags unhealthy, kickstarting ollama"; launchctl kickstart -k "gui/\$(id -u)/com.user.ollama"; }</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HC_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${HC_LOG}</string>
</dict>
</plist>
HC
  mkdir -p "$(dirname "$HC_PATH")" "$(dirname "$HC_LOG")"
  if [[ -f "$HC_PATH" ]] && cmp -s "$TMP_HC" "$HC_PATH"; then
    info "${HC_LABEL} already current"
    rm -f "$TMP_HC"
  else
    mv "$TMP_HC" "$HC_PATH"
    launchctl unload "$HC_PATH" 2>/dev/null || true
    launchctl load "$HC_PATH"
    info "installed ${HC_LABEL} (log: ${HC_LOG})"
  fi
fi

if [[ "$INSTALL_AUTOUPDATE" == "1" ]]; then
  bold "Bonus: macOS auto-updates + weekly brew upgrade"

  # macOS background update checks + auto-install of security responses.
  sudo softwareupdate --schedule on >/dev/null
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
  info "softwareupdate: scheduled, security responses auto-install"

  # Weekly LaunchAgent: Sunday 04:00 → brew update && brew upgrade ollama
  BREW_BIN="$(command -v brew)"
  BU_LABEL="com.user.brew-weekly-upgrade"
  BU_PATH="$HOME/Library/LaunchAgents/${BU_LABEL}.plist"
  BU_LOG="$HOME/Library/Logs/${BU_LABEL}.log"
  TMP_BU="$(mktemp -t brew-upgrade-plist)"
  cat >"$TMP_BU" <<BU
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${BU_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>echo "--- \$(date) ---"; ${BREW_BIN} update &amp;&amp; ${BREW_BIN} upgrade ollama</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>0</integer>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${BU_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${BU_LOG}</string>
</dict>
</plist>
BU
  mkdir -p "$(dirname "$BU_PATH")" "$(dirname "$BU_LOG")"
  if [[ -f "$BU_PATH" ]] && cmp -s "$TMP_BU" "$BU_PATH"; then
    info "${BU_LABEL} already current"
    rm -f "$TMP_BU"
  else
    mv "$TMP_BU" "$BU_PATH"
    launchctl unload "$BU_PATH" 2>/dev/null || true
    launchctl load "$BU_PATH"
    info "installed ${BU_LABEL} (Sundays 04:00, log: ${BU_LOG})"
  fi
fi

bold "Done."
cat <<EOF

Verify locally:
  curl http://127.0.0.1:${OLLAMA_PORT}/api/tags

From a Tailscale peer (after MagicDNS is on):
  curl http://\$(hostname -s).<your-tailnet>.ts.net:${OLLAMA_PORT}/api/tags

Logs:
  ollama (server stdout/err): ~/Library/Logs/ollama.log
  ollama (application):       ~/.ollama/logs/server.log
  health check:               ~/Library/Logs/com.user.ollama-healthcheck.log
  weekly brew upgrade:        ~/Library/Logs/com.user.brew-weekly-upgrade.log

Your Tailscale IPv4 (once signed in):
  /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
EOF
