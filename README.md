# mac-llm-setup

Configures an Apple Silicon Mac as an always-on Ollama inference node reachable
over Tailscale. Designed for a closed-lid laptop on AC power — never sleeps,
auto-restarts after power loss, locks the screen when the display blanks.

## Setup

```bash
bash setup-ollama-tailscale.sh
```

Re-runnable; each step is idempotent and skips work that's already done.
See the script header for env-var overrides (`DEFAULT_MODEL`, `INSTALL_GUI`,
`AWAKE_ON_AC`, `DISPLAY_SLEEP_MIN`, `LOCK_ON_SLEEP`, `EXCLUDE_BACKUPS`,
`INSTALL_HEALTHCHECK`, `INSTALL_AUTOUPDATE`, etc.).

## Logs

| What                  | Path                                                |
| --------------------- | --------------------------------------------------- |
| Ollama (brew stdout)  | `$(brew --prefix)/var/log/ollama.log`               |
| Ollama (application)  | `~/.ollama/logs/server.log`                         |
| Health check          | `~/Library/Logs/com.user.ollama-healthcheck.log`    |
| Weekly brew upgrade   | `~/Library/Logs/com.user.brew-weekly-upgrade.log`   |

## Common operations

```bash
brew services restart ollama                    # restart the daemon
curl http://127.0.0.1:11434/api/tags            # list installed models
curl http://127.0.0.1:11434/api/ps              # show what's loaded
ollama run gemma:best                           # interactive chat with the alias
launchctl list | grep -E 'ollama|brew-weekly'   # see installed agents
```

## What gets installed

- Homebrew formulas/casks: `ollama`, `ollama-app`, `tailscale-app`
- LaunchAgents in `~/Library/LaunchAgents/`:
  - `com.user.ollama-env.plist` — re-applies `OLLAMA_HOST`, `OLLAMA_KEEP_ALIVE`,
    `OLLAMA_MAX_LOADED_MODELS` at every login and kickstarts the brew service.
  - `com.user.ollama-healthcheck.plist` — probes `/api/tags` every 60s and
    runs `launchctl kickstart -k` if it stops responding.
  - `com.user.brew-weekly-upgrade.plist` — Sunday 04:00 `brew update && brew upgrade ollama`.
- pmset (AC profile): `sleep 0`, `displaysleep N`, `disablesleep 1`,
  `autorestart 1`, `womp 1`, `powernap 0`.
- Screen lock immediately on display sleep (`com.apple.screensaver`).
- Time Machine and Spotlight skip `~/.ollama/models` (model weights are large
  and re-downloadable).
- macOS auto-update schedule + auto-install of security responses.
