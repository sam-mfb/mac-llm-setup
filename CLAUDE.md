# CLAUDE.md

Guidance for Claude when working in this repo.

## What this repo is

A single setup script (`setup-ollama-tailscale.sh`) plus a README. The script
configures an Apple Silicon Mac as an always-on Ollama inference node reachable
over Tailscale.

## Core principle: the script enforces a known good state

The script is **not** just a one-shot installer. It is a convergence tool: no
matter what state the Mac is in when it runs, the end state is the same.

- **Clean Mac** → installs and configures everything from scratch.
- **Previously configured Mac** → confirms each piece is in the desired state
  and re-applies / resets / removes anything that has drifted.
- **Re-running after a config change** (e.g. flipping a flag from `1` to `0`)
  → the previously-applied state is undone, not just left behind.

Every step must be idempotent **and** must enforce the desired state in both
directions. "Install if missing" alone is not enough — if a flag turns a
feature off, the script must actively remove the artifacts that flag would
have created.

### What this means in practice

When adding or modifying a step, ask:

1. **What does this step create / change on the system?** (files, plists,
   `defaults` keys, `pmset` settings, brew formulas/casks, login items,
   launchd jobs, running processes, filesystem exclusions, …)
2. **What is the desired state when the controlling flag is on?** Apply it,
   idempotently. Diff before writing where possible (the existing
   `cmp -s "$TMP" "$DEST"` pattern is the model).
3. **What is the desired state when the controlling flag is off (or the
   feature is removed entirely)?** Actively reverse every artifact from (1):
   - Stop and unload LaunchAgents (`launchctl bootout` / `unload`), then
     delete the plist.
   - `brew uninstall` formulas/casks that should not be present; kill any
     running processes from them first; disable SMAppService / login items.
   - Restore `defaults` / `pmset` keys to their stock values rather than
     leaving the override in place.
   - Remove filesystem sentinels (e.g. `.metadata_never_index`) and undo
     `tmutil addexclusion` with `tmutil removeexclusion`.
4. **Does the script tolerate partial / interrupted previous runs?** Each
   step should detect leftover artifacts from older versions of the script
   (the `LEGACY_PLIST` cleanup at lines 92–100 is the model) and clean them
   up.

The `INSTALL_GUI` branch (lines 42–63) is the canonical example of a
two-direction step: when on it installs the cask; when off it kills the app,
disables the SMAppService label, removes the login item, and uninstalls the
cask. New steps should match that thoroughness.

### What this principle is not

- Not "rip out the user's unrelated config." The script only owns artifacts
  it creates or that it documents as managed (the `com.user.*` LaunchAgents,
  the specific `defaults` keys it writes, the pmset AC profile, the
  `~/.ollama/models` exclusions, the brew formulas/casks it installs). Don't
  start clearing things the script never touched.
- Not "always destroy and reinstall." Prefer idempotent enforcement (compare
  current state, change only on drift) over teardown-and-rebuild.

### Documented exception: model pruning

`PULL_MODELS` is **additive only**. Models that were pulled previously but
are no longer in the list are intentionally left in place — model weights
are large (often tens of GB), expensive to re-download, and silently
deleting them on every run is too dangerous a default. If pruning is ever
wanted, add it behind an explicit opt-in flag (e.g. `PRUNE_MODELS=1`); do
not change the default.

## Conventions

- Bash with `set -euo pipefail`. Keep it that way.
- Each numbered step prints a `bold` heading; sub-actions print via `info`.
- Plists are written to a temp file, compared with `cmp -s` against the
  installed copy, and only moved into place + reloaded on drift.
- Env-var-overridable flags at the top of the script. New flags follow the
  same `${NAME:-default}` pattern and get a one-line comment.
- README.md lists the env-var flags and the artifacts the script installs.
  Update README whenever the surface area changes.

## Out of scope for this repo

- No package manager beyond Homebrew.
- No code outside the single setup script and its README/CLAUDE files.
  Don't introduce a `lib/` or split the script unless asked.
