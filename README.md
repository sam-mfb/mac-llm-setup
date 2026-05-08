# mac-llm-setup

Configures an Apple Silicon Mac as an always-on Ollama inference node reachable
over Tailscale. Designed for a closed-lid laptop on AC power — never sleeps,
auto-restarts after power loss, locks the screen when the display blanks.

## Setup

```bash
bash setup-ollama-tailscale.sh
```

Re-runnable: the script enforces a known good state in **both directions**.
Running it on a clean Mac sets everything up; running it again confirms
each piece is in place; flipping a flag from `1` to `0` and re-running
actively undoes what that flag had previously applied (uninstalls the
GUI cask, restores stock `pmset`, removes LaunchAgents, etc.).

See the script header for env-var overrides (`OLLAMA_VERSION`, `INSTALL_GUI`,
`AWAKE_ON_AC`, `DISPLAY_SLEEP_MIN`, `LOCK_ON_SLEEP`, `EXCLUDE_BACKUPS`,
`INSTALL_HEALTHCHECK`, `INSTALL_AUTOUPDATE`, etc.).

`OLLAMA_VERSION` pins to an exact ollama release (default in the script
header). On every run the script enforces that version — upgrading or
downgrading via a local brew tap as needed — and `brew pin`s the result so
the weekly auto-upgrade can't drift it. Set `OLLAMA_VERSION=latest` (or
empty) to track upstream instead.

## Logs

| What                  | Path                                                |
| --------------------- | --------------------------------------------------- |
| Ollama (server)       | `~/Library/Logs/ollama.log`                         |
| Ollama (application)  | `~/.ollama/logs/server.log`                         |
| Health check          | `~/Library/Logs/com.user.ollama-healthcheck.log`    |
| Weekly brew upgrade   | `~/Library/Logs/com.user.brew-weekly-upgrade.log`   |

## Common operations

```bash
launchctl kickstart -k gui/$(id -u)/com.user.ollama   # restart the daemon
curl http://127.0.0.1:11434/api/tags                  # list installed models
curl http://127.0.0.1:11434/api/ps                    # show what's loaded
ollama run gemma:best                                 # interactive chat with the alias
launchctl list | grep -E 'ollama|brew-weekly'         # see installed agents
```

## What gets installed

- Homebrew formulas/casks: `ollama` (formula), `tailscale-app` (cask).
  `ollama-app` (cask) is installed only when `INSTALL_GUI=1`; with the
  default `INSTALL_GUI=0` the cask is actively uninstalled if found.
- A symlink at `$(brew --prefix)/bin/tailscale` pointing at the CLI inside
  the Tailscale.app bundle, so `tailscale` works from any shell.
- LaunchAgents in `~/Library/LaunchAgents/`:
  - `com.user.ollama.plist` — runs `ollama serve` directly with
    `OLLAMA_HOST`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_MAX_LOADED_MODELS` baked
    into `EnvironmentVariables`. Replaces both `homebrew.mxcl.ollama`
    and the legacy `com.user.ollama-env` agent (both are torn down on run).
  - `com.user.ollama-healthcheck.plist` — probes `/api/tags` every 60s and
    runs `launchctl kickstart -k` if it stops responding.
  - `com.user.brew-weekly-upgrade.plist` — Sunday 04:00 `brew update && brew upgrade ollama`.
- pmset (AC profile): `sleep 0`, `displaysleep N`, `disablesleep 1`,
  `autorestart 1`, `womp 1`, `powernap 0`.
- Screen lock immediately on display sleep (`com.apple.screensaver`).
- Time Machine and Spotlight skip `~/.ollama/models` (model weights are large
  and re-downloadable).
- macOS auto-update schedule + auto-install of security responses.
