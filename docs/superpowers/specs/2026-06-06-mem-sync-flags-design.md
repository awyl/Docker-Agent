# `--mem-from` / `--mem-to` flags for run-claude.sh — design

## Context

Moving Claude Code work into the container means the working dir's **memory**
(`~/.claude/projects/<slug>/memory/`) does not follow. The default isolated config
(`~/.docker-agent/<proj>/claude`) seeds credentials and login keys only — never
`projects/`, so memory is absent in the container, and anything written there does
not flow back to the host.

Two complications make hand-copying error-prone:
- The project slug is long and easy to mistype
  (`-home-awyl-codebase-awyl-Docker-Agent`).
- Claude keys memory by cwd. The container's cwd is always `/work`, so its slug is
  `-work` — different from the host slug. A naive copy lands under the wrong slug.

`--mem-from` / `--mem-to` close the gap: one-shot copies of the memory dir between
host and the resolved config dir, with the slug mapping handled by the script.
Claude only — `memory/` is a Claude concept; pi/goose/hermes have their own models.

## Behavior

`run-claude.sh [config flags] [-w WORK_DIR] (--mem-from | --mem-to)`

1. Parse flags as normal: the mem flags respect `-i` (default), `-H`, `-c`, `-w`,
   so they target exactly the config dir the script would otherwise mount.
2. Run the existing resolve + seed flow (so `CONFIG_DIR` is finalized), then copy
   and exit — no container, no agent.

Direction:
- `--mem-from` — copy host memory **into** the config dir (seed the container).
- `--mem-to`   — copy config-dir memory **to** host (save the container's work back).

Scope: memory dir only (no `.jsonl` session logs). Point-in-time copy via
`cp -a`; last writer wins. The two flags are mutually exclusive.

Resolved paths:
- Host:   `~/.claude/projects/<host-slug>/memory`, where `<host-slug>` is the
  absolute `WORK_DIR` with `/` and `.` collapsed to `-`.
- Config: `<CONFIG_DIR>/projects/-work/memory` (container cwd `/work` → slug `-work`).

Missing-source is a no-op with a message, not an error (e.g. `--mem-from` when the
host has no memory yet).

## Implementation

Long flags: `getopts` handles only short options, so extend the existing
pre-getopts scan (added for `--edit`) to also recognize `--mem-from`/`--mem-to`,
stopping at the first `--` so agent passthrough args are left intact:

```bash
case "$_a" in
  --edit)     EDIT=1; continue ;;
  --mem-from) MEM_FROM=1; continue ;;
  --mem-to)   MEM_TO=1; continue ;;
esac
```

Mutual-exclusion guard right after the scan:

```bash
if [ $((MEM_FROM + MEM_TO)) -gt 1 ]; then
  echo "run-claude.sh: choose only one of --mem-from, --mem-to" >&2
  exit 2
fi
```

Action block, inserted after the `--edit` block (so `CONFIG_DIR`/`WORK_DIR` are
already resolved + seeded) and before the named-container / `docker run` section:

```bash
if [ "$MEM_FROM" -eq 1 ] || [ "$MEM_TO" -eq 1 ]; then
  HOST_SLUG="$(printf '%s' "$WORK_DIR" | sed 's/[/.]/-/g')"
  HOST_MEM="$HOME/.claude/projects/$HOST_SLUG/memory"
  CONF_MEM="$CONFIG_DIR/projects/-work/memory"
  if [ "$MEM_FROM" -eq 1 ]; then
    if [ -d "$HOST_MEM" ]; then
      mkdir -p "$CONF_MEM"; cp -a "$HOST_MEM/." "$CONF_MEM/"
      echo "memory: copied host -> $CONF_MEM"
    else
      echo "memory: no host memory at $HOST_MEM (nothing to copy)"
    fi
  else
    if [ -d "$CONF_MEM" ]; then
      mkdir -p "$HOST_MEM"; cp -a "$CONF_MEM/." "$HOST_MEM/"
      echo "memory: copied $CONF_MEM -> host ($HOST_MEM)"
    else
      echo "memory: no config memory at $CONF_MEM (nothing to copy)"
    fi
  fi
  exit 0
fi
```

No `getopts` string change (long flags only); no change to the launch/`exec`
paths — both flags return before any container starts.

## Interactions

- The mem flags take precedence: `-n NAME` and trailing agent args are ignored
  (no container created). Documented, not an error.
- Work with `-H` (host config layout: `CONF_MEM` becomes
  `~/.claude/projects/-work/memory`) and `-c CUSTOM_DIR`.
- The `-i`/`-H`/`-c` mutual-exclusion check is unchanged and still applies.
- Because `CONFIG_DIR` is on host disk and bind-mounted, the copy is pure
  host-side `cp` — no `docker cp`, container need not be running.

## Files changed

- `run-claude.sh` only — pre-getopts scan additions + guard + action block; add
  `--mem-from`/`--mem-to` lines to the usage header (and bump the `sed -n '2,NNp'`
  help range). The other `run-*.sh` scripts are not changed (Claude-only).
- `README.md` — two flag-table rows, an explanation paragraph, and two examples.

## Verification

```bash
HOSTMEM=~/.claude/projects/-home-awyl-codebase-awyl-Docker-Agent/memory
CONFMEM=~/.docker-agent/Docker-Agent/claude/projects/-work/memory

# host -> config
mkdir -p "$HOSTMEM"; printf x > "$HOSTMEM/t.md"
./run-claude.sh --mem-from        # expect: copied host -> .../-work/memory; t.md present

# config -> host
printf y > "$CONFMEM/u.md"
./run-claude.sh --mem-to          # expect: copied ... -> host; u.md present in $HOSTMEM

# mutual exclusion
./run-claude.sh --mem-from --mem-to ; echo $?   # expect: error, exit 2
```
(No Docker needed — the flags `exit` before any `docker run`.)
