# `--edit` flag for run-*.sh — design

## Context

The `run-*.sh` launchers (claude, pi, goose, hermes) resolve a config dir,
seed it, then run the agent in a container. There is no quick way to open that
config dir to inspect or tweak it — you have to know the path and `cd` there by
hand, which is awkward now that the default config is an isolated, per-project
dir under `~/.docker-agent/<proj>/<agent>`. The `--edit` flag closes that gap:
it resolves and seeds the same dir the script would mount, opens it in the
user's editor, and exits without launching a container.

## Behavior

`run-<agent>.sh [config flags] [-w WORK_DIR] --edit`

1. Parse flags as normal: `--edit` respects `-i` (default), `-H`, `-c`, `-w`,
   so it targets exactly the dir the script would otherwise mount.
2. Run the existing resolve + seed flow (mkdir; seed auth/credentials; pi
   bundle via `pi-default-config/`; claude default via `claude-default-config/`).
   So the opened dir is already populated even on first use.
3. Open the resolved **host** config dir in an editor, then `exec` — no
   container, no agent.

Editor precedence: `$VISUAL` → `$EDITOR` → `nvim` → `vi`.

Target dir variable per script: `CONFIG_DIR` (claude) / `CONFIG_SRC` (pi,
goose, hermes). For claude, only the config dir is opened; the sibling
`~/.claude.json` is not (editing the dir is the intent).

## Implementation

Long flags: `getopts` handles only short options, so pre-scan argv before the
`getopts` loop to extract `--edit`. Stop scanning at the first `--` so agent
passthrough args are left intact:

```bash
EDIT=0
ARGS=()
edit_stop=0
for a in "$@"; do
  if [ "$edit_stop" -eq 0 ] && [ "$a" = "--" ]; then edit_stop=1; fi
  if [ "$edit_stop" -eq 0 ] && [ "$a" = "--edit" ]; then EDIT=1; continue; fi
  ARGS+=("$a")
done
set -- "${ARGS[@]}"
```

This runs after `set -euo pipefail` / SCRIPT_DIR setup and before the existing
`while getopts ...` loop. The rest of getopts is unchanged.

Action block, inserted after the resolve+seed block and before the named-
container / `docker run` section:

```bash
if [ "$EDIT" -eq 1 ]; then
  ED="${VISUAL:-${EDITOR:-}}"
  [ -z "$ED" ] && { command -v nvim >/dev/null 2>&1 && ED=nvim || ED=vi; }
  exec $ED "$CONFIG_DIR"   # CONFIG_SRC in pi/goose/hermes
fi
```

`exec` replaces the shell with the editor; on editor exit the script ends.

## Interactions

- `--edit` takes precedence: `-n NAME` and any trailing agent args are ignored
  (no container is created). Documented, not an error.
- Works with `-H` (edits the live host config dir) and `-c CUSTOM_DIR`.
- Mutual-exclusion check for `-i`/`-H`/`-c` is unchanged and still applies.

## Files changed

Pattern is identical across all four scripts:

- `run-claude.sh`, `run-pi.sh`, `run-goose.sh`, `run-hermes.sh` — add the
  pre-getopts `--edit` scan + the action block; add a `--edit` line to each
  usage header (and bump the `sed -n '2,NNp'` help range).
- `README.md` — add a `--edit` row to the flag table and a one-line mention in
  the Run section.

## Verification

```bash
# Default isolated dir, fake editor confirms the right path is opened:
EDITOR='printf EDIT_OPENS:%s\n' ./run-pi.sh --edit -w /tmp/demo
# expect: EDIT_OPENS:<.../.docker-agent/demo/pi>  and no container launched

# -H targets host dir:
EDITOR='printf %s\n' ./run-claude.sh --edit -H        # -> ~/.claude

# Passthrough args after -- are not consumed by --edit:
#   ./run-pi.sh -- --edit            # --edit goes to pi, not the launcher

# Editor fallback when EDITOR/VISUAL unset: resolves nvim, else vi.
```
(Editor verification needs no Docker — the script `exec`s the editor before any
`docker run`.)
