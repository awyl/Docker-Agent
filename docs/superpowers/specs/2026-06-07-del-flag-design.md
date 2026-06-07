# `--del` flag: remove an agent's isolated config

**Date:** 2026-06-07
**Status:** Approved, ready for implementation plan

## Problem

Each runner keeps a per-project, per-agent isolated config under
`~/.docker-agent/<proj>/<agent>` (e.g. `~/.docker-agent/Docker-Agent/claude`). These
accumulate and there is no built-in way to remove one — users must `rm -rf` by hand
and figure out the path. A `--del` flag should delete the current agent's entry for a
work dir, with a typed confirmation to prevent accidents.

## Goal

Add a `--del` one-shot flag to all four runners (`run-claude/goose/hermes/pi.sh`) that
deletes this agent's isolated config dir for the resolved work dir, after the user
confirms by typing the project name.

## Decisions

- **Agent-only scope.** Removes `~/.docker-agent/<proj>/<agent>` (plus claude's sibling
  `<agent>.json`). Other agents' configs for the same project survive. If the parent
  `<proj>/` becomes empty, prune it.
- **Confirm by project basename.** The user types `basename "$WORK_DIR"` (e.g.
  `Docker-Agent`). Distinctive per project; mismatch aborts with no deletion.
- **Isolated config only.** `--del` is valid only for the isolated config (default or
  `-i`). With `-H` (host `~/.claude`) or `-c` (custom dir) it refuses — it must never
  delete real host configs or arbitrary paths.
- **One-shot, like `--edit`.** Parsed before getopts, runs after resolution, exits
  before any container launch. Mutually exclusive with `--edit` (and claude's
  `--mem-from`/`--mem-to`).
- **Never touches `~/.docker-agent/gitconfig`** — the shared git-identity file lives at
  the top level, not under any `<proj>/`, so the agent-scoped delete and the
  empty-parent prune cannot reach it.

## Design

### Flag plumbing (each runner)

- Add `DEL=0` with the other flag defaults.
- In the existing long-flag extraction loop (the one handling `--edit`), add a
  `--del) DEL=1; continue ;;` case.
- Mutual-exclusion guard (extend the existing one near the `--edit`/mem handling):
  error if more than one of `--del` / `--edit` (/ claude's `--mem-from` / `--mem-to`)
  is set.

### Deletion block

Inserted **after** `WORK_DIR` and `ISOLATE` are resolved but **before** the
`if [ "$ISOLATE" -eq 1 ]` seeding/`mkdir` block, so it never recreates or seeds the dir
it is about to delete. `<agent>` is the literal agent name in each file.

```sh
# --del: remove this agent's isolated config for the work dir, then exit. Only
# touches the isolated ~/.docker-agent path — never -H host config or -c custom.
if [ "$DEL" -eq 1 ]; then
  if [ "$ISOLATE" -ne 1 ]; then
    echo "run-<agent>.sh: --del only removes the isolated config; not valid with -H or -c" >&2
    exit 2
  fi
  PROJ="$(basename "$WORK_DIR")"
  DEL_DIR="$HOME/.docker-agent/$PROJ/<agent>"
  if [ ! -e "$DEL_DIR" ]; then
    echo "--del: nothing to delete at $DEL_DIR"; exit 0
  fi
  printf 'About to delete %s\nType the project name (%s) to confirm: ' "$DEL_DIR" "$PROJ"
  read -r _ans
  [ "$_ans" = "$PROJ" ] || { echo "aborted"; exit 1; }
  rm -rf "$DEL_DIR"
  [ -e "$DEL_DIR.json" ] && rm -f "$DEL_DIR.json"        # claude's sibling .json (no-op for others)
  rmdir "$HOME/.docker-agent/$PROJ" 2>/dev/null || true  # prune parent if now empty
  echo "deleted $DEL_DIR"
  exit 0
fi
```

Notes:
- The `$DEL_DIR.json` line is uniform across runners; only claude has such a sibling,
  so it is a harmless no-op elsewhere.
- `rmdir` (not `rm -rf`) on the parent: removes it only when empty, so sibling agents'
  configs are never collaterally deleted.

### Behavior

| Case | Result |
|------|--------|
| default / `-i`, target exists, name matches | dir (+ claude `.json`) deleted, empty parent pruned, exit 0 |
| name typed does not match project | "aborted", nothing deleted, exit 1 |
| `-H` or `-c` | refuse, exit 2 |
| target does not exist | "nothing to delete", exit 0 |
| `--del` combined with `--edit`/`--mem-*` | error, exit 2 |

### Docs

- Add a `--del` line to each runner's usage header comment (printed by `-h`).
- Add `--del` to the README flags/options listing.

## Out of scope

- Whole-project deletion (all agents at once).
- Deleting `-c` custom or `-H` host configs.
- Removing built Docker images or named containers.
- A non-interactive `--yes`/force variant.

## Verification

- `--del` on a project with an existing isolated config, typing the correct project
  name → dir gone; typing a wrong name → dir intact.
- `--del -H` and `--del -c /tmp/x` → refused (exit 2), nothing deleted.
- `--del` when no config exists → "nothing to delete", exit 0.
- Deleting the only agent under a project prunes the empty `<proj>/`; a sibling agent's
  config under the same project is left intact and the parent is not pruned.
- `~/.docker-agent/gitconfig` still present after any `--del`.
- All four runners pass `bash -n`.
