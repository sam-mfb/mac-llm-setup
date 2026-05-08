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
OLLAMA_VERSION="${OLLAMA_VERSION:-0.23.2}"             # exact ollama version to pin to. Set to "latest" (or "") to track upstream instead.
# Models to pull (space-separated; idempotent). Set to "" to skip all pulls.
PULL_MODELS="${PULL_MODELS:-gemma4:31b-it-q8_0 gemma4:31b-mlx-bf16 gemma4:31b-it-q4_K_M gemma4:26b-mlx-bf16 gemma4:26b-a4b-it-q8_0 gemma4:26b-a4b-it-q4_K_M}"
AWAKE_ON_AC="${AWAKE_ON_AC:-1}"               # 1 = on AC, never sleep (incl. lid closed); 0 = restore stock pmset; both need sudo
DISPLAY_SLEEP_MIN="${DISPLAY_SLEEP_MIN:-10}"  # blank the display after N minutes on AC (0 = never)
LOCK_ON_SLEEP="${LOCK_ON_SLEEP:-1}"           # 1 = require password as soon as display sleeps; 0 = remove the override
INSTALL_GUI="${INSTALL_GUI:-0}"               # 0 = CLI/server only (recommended); 1 = also install the Ollama menu-bar GUI app (cask)
EXCLUDE_BACKUPS="${EXCLUDE_BACKUPS:-1}"       # 1 = skip Time Machine + Spotlight on ~/.ollama/models; 0 = remove those exclusions
INSTALL_HEALTHCHECK="${INSTALL_HEALTHCHECK:-1}"  # 1 = LaunchAgent that probes /api/tags every 60s; 0 = remove it if present
INSTALL_AUTOUPDATE="${INSTALL_AUTOUPDATE:-1}"    # 1 = enable macOS auto security updates + weekly brew upgrade; 0 = disable both
# -------------------------------------------------------------------------

bold() { printf "\n\033[1m%s\033[0m\n" "$*"; }
info() { printf "  → %s\n" "$*"; }

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it first: https://brew.sh" >&2
  exit 1
fi

if [[ "$OLLAMA_VERSION" == "latest" || -z "$OLLAMA_VERSION" ]]; then
  bold "1/6  Installing Ollama (tracking latest)"
else
  bold "1/6  Installing Ollama (pinned to $OLLAMA_VERSION)"
fi

# Detect what's installed: regular `ollama` formula, or any `ollama@X.Y.Z`
# left over from a previous pinned run.
CURRENT_OLLAMA_FORMULA=""
CURRENT_OLLAMA_VERSION=""
while read -r _f; do
  [[ "$_f" =~ ^ollama(@.*)?$ ]] || continue
  CURRENT_OLLAMA_FORMULA="$_f"
  CURRENT_OLLAMA_VERSION="$(brew list --versions "$_f" 2>/dev/null | awk 'NR==1{print $2}')"
  break
done < <(brew list --formula 2>/dev/null || true)

if [[ "$OLLAMA_VERSION" == "latest" || -z "$OLLAMA_VERSION" ]]; then
  # Track-latest mode. Drop any pinned ollama@X.Y.Z and unpin the regular
  # formula so the weekly `brew upgrade` can move it forward.
  if [[ -n "$CURRENT_OLLAMA_FORMULA" && "$CURRENT_OLLAMA_FORMULA" != "ollama" ]]; then
    info "removing pinned $CURRENT_OLLAMA_FORMULA in favor of latest ollama"
    brew unpin "$CURRENT_OLLAMA_FORMULA" 2>/dev/null || true
    brew uninstall "$CURRENT_OLLAMA_FORMULA"
    CURRENT_OLLAMA_FORMULA=""
  fi
  brew unpin ollama 2>/dev/null || true
  if [[ "$CURRENT_OLLAMA_FORMULA" == "ollama" ]]; then
    info "ollama already installed at $CURRENT_OLLAMA_VERSION (tracking latest)"
  else
    brew install ollama
  fi
else
  # Pinned mode. Install ollama@$OLLAMA_VERSION via a local tap, then pin.
  # `brew upgrade` skips pinned formulas, so the weekly auto-upgrade is a
  # no-op for ollama without any extra work.
  DESIRED_FORMULA="ollama@${OLLAMA_VERSION}"
  PIN_TAP="local/ollama-pin"

  if [[ "$CURRENT_OLLAMA_FORMULA" == "$DESIRED_FORMULA" && "$CURRENT_OLLAMA_VERSION" == "$OLLAMA_VERSION" ]]; then
    info "$DESIRED_FORMULA already installed at $CURRENT_OLLAMA_VERSION"
  else
    if [[ -n "$CURRENT_OLLAMA_FORMULA" ]]; then
      info "replacing $CURRENT_OLLAMA_FORMULA ($CURRENT_OLLAMA_VERSION) with $DESIRED_FORMULA"
      brew unpin "$CURRENT_OLLAMA_FORMULA" 2>/dev/null || true
      brew uninstall "$CURRENT_OLLAMA_FORMULA"
    fi

    if ! brew tap | grep -qx "$PIN_TAP"; then
      info "creating local tap $PIN_TAP for pinned ollama versions"
      brew tap-new "$PIN_TAP" >/dev/null
    fi
    PIN_TAP_PATH="$(brew --repository "$PIN_TAP")"
    if [[ ! -f "$PIN_TAP_PATH/Formula/${DESIRED_FORMULA}.rb" ]]; then
      info "extracting ollama $OLLAMA_VERSION formula into $PIN_TAP"
      brew extract --version="$OLLAMA_VERSION" ollama "$PIN_TAP" >/dev/null
    fi

    info "installing $PIN_TAP/$DESIRED_FORMULA"
    brew install "$PIN_TAP/$DESIRED_FORMULA"
  fi

  brew pin "$DESIRED_FORMULA" 2>/dev/null || true
  info "ollama pinned at $OLLAMA_VERSION"
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

# The cask only ships the CLI inside the app bundle, so `tailscale` isn't on
# PATH by default. Symlink it into $(brew --prefix)/bin so it works from any
# shell. Idempotent; refuses to clobber an unrelated file at the target.
TS_APP_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
TS_LINK="$(brew --prefix)/bin/tailscale"
if [[ -x "$TS_APP_BIN" ]]; then
  if [[ -L "$TS_LINK" && "$(readlink "$TS_LINK")" == "$TS_APP_BIN" ]]; then
    info "tailscale CLI already on PATH at $TS_LINK"
  elif [[ -e "$TS_LINK" || -L "$TS_LINK" ]]; then
    info "WARNING: $TS_LINK exists and isn't our symlink — leaving alone"
  else
    ln -s "$TS_APP_BIN" "$TS_LINK"
    info "symlinked tailscale CLI to $TS_LINK"
  fi
else
  info "WARNING: $TS_APP_BIN missing — can't symlink CLI onto PATH"
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

if [[ -n "$PULL_MODELS" ]]; then
  bold "5/6  Pulling models"
  for _m in $PULL_MODELS; do
    info "pulling $_m"
    ollama pull "$_m" || { info "WARNING: failed to pull $_m (continuing)"; }
  done
else
  bold "5/6  Skipping model pull (PULL_MODELS is empty)"
fi

bold "6/6  Done pulling models"

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
else
  bold "Bonus: restoring stock pmset AC profile (AWAKE_ON_AC=0)"
  # Undoes any previous AWAKE_ON_AC=1 run. restoredefaults resets the AC
  # profile to Apple's defaults; safe even if we never customized it.
  sudo pmset -c restoredefaults
  info "pmset: AC profile restored to stock"
fi

if [[ "$LOCK_ON_SLEEP" == "1" ]]; then
  bold "Bonus: lock screen as soon as the display sleeps"
  defaults write com.apple.screensaver askForPassword -int 1
  defaults write com.apple.screensaver askForPasswordDelay -int 0
  info "screen will lock immediately on display sleep"
else
  bold "Bonus: removing screen-lock override (LOCK_ON_SLEEP=0)"
  # Restore Apple's defaults by deleting the keys this script wrote.
  defaults delete com.apple.screensaver askForPassword 2>/dev/null || true
  defaults delete com.apple.screensaver askForPasswordDelay 2>/dev/null || true
  info "askForPassword / askForPasswordDelay reset to system defaults"
fi

if [[ "$EXCLUDE_BACKUPS" == "1" ]]; then
  bold "Bonus: excluding ~/.ollama/models from Time Machine + Spotlight"
  mkdir -p "$HOME/.ollama/models"
  # tmutil addexclusion is idempotent (no error if already excluded)
  tmutil addexclusion "$HOME/.ollama/models" 2>/dev/null || true
  # Drop the well-known sentinel file Spotlight respects to skip indexing
  touch "$HOME/.ollama/models/.metadata_never_index"
  info "Time Machine: ~/.ollama/models excluded; Spotlight: .metadata_never_index in place"
else
  bold "Bonus: removing ~/.ollama/models backup/index exclusions (EXCLUDE_BACKUPS=0)"
  if [[ -d "$HOME/.ollama/models" ]]; then
    tmutil removeexclusion "$HOME/.ollama/models" 2>/dev/null || true
    rm -f "$HOME/.ollama/models/.metadata_never_index"
    info "Time Machine exclusion removed; Spotlight sentinel deleted"
  else
    info "~/.ollama/models doesn't exist — nothing to undo"
  fi
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
else
  bold "Bonus: removing ollama health check (INSTALL_HEALTHCHECK=0)"
  HC_LABEL="com.user.ollama-healthcheck"
  HC_PATH="$HOME/Library/LaunchAgents/${HC_LABEL}.plist"
  if [[ -f "$HC_PATH" ]]; then
    launchctl unload "$HC_PATH" 2>/dev/null || true
    rm -f "$HC_PATH"
    info "${HC_LABEL} unloaded and removed"
  else
    info "${HC_LABEL} not installed — nothing to remove"
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
else
  bold "Bonus: disabling macOS auto-updates + weekly brew upgrade (INSTALL_AUTOUPDATE=0)"

  # Undo the softwareupdate prefs this script wrote. Deleting restores
  # Apple's defaults rather than pinning to false.
  sudo softwareupdate --schedule off >/dev/null 2>&1 || true
  sudo defaults delete /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null || true
  sudo defaults delete /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null || true
  sudo defaults delete /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall 2>/dev/null || true
  info "softwareupdate: schedule off, prefs reset to defaults"

  # Unload + delete the weekly brew upgrade LaunchAgent if present.
  BU_LABEL="com.user.brew-weekly-upgrade"
  BU_PATH="$HOME/Library/LaunchAgents/${BU_LABEL}.plist"
  if [[ -f "$BU_PATH" ]]; then
    launchctl unload "$BU_PATH" 2>/dev/null || true
    rm -f "$BU_PATH"
    info "${BU_LABEL} unloaded and removed"
  else
    info "${BU_LABEL} not installed — nothing to remove"
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
  tailscale ip -4
EOF
