# `--mem-from` / `--mem-to` Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--mem-from` / `--mem-to` flags to `run-claude.sh` that copy the working dir's Claude memory dir between the host config and the resolved (container) config dir, then exit without launching a container. Claude only — `memory/` is a Claude concept; pi/goose/hermes are out of scope.

**Architecture:** Extend the existing pre-`getopts` long-flag scan (added for `--edit`) to also set `MEM_FROM`/`MEM_TO`, plus a mutual-exclusion guard. An action block, placed after the `--edit` block (so `CONFIG_DIR`/`WORK_DIR` are resolved+seeded) and before the container section, computes the host slug (`WORK_DIR` with `/`,`.`→`-`) and the container slug (`-work`, fixed cwd), then `cp -a`s the `memory/` subdir in the requested direction and `exit 0`s. Because the config dir is host-side and bind-mounted, this is plain `cp` — no `docker cp`.

**Tech Stack:** Bash (`getopts`, `sed`, `cp -a`). No test framework — verification is bash harness scripts using fake `HOME`/`WORK_DIR` dirs; no Docker needed (flags exit before any `docker run`).

---

## File structure

- `run-claude.sh` — pre-getopts scan additions + guard + action block; usage header + help `sed` range.
- `README.md` — flag-table rows, explanation paragraph, examples.
- `docs/superpowers/specs/2026-06-06-mem-sync-flags-design.md` — companion spec.

Placement rules:
- **Scan**: the existing `--edit` pre-getopts loop — convert the single `--edit` test to a `case` covering `--edit`/`--mem-from`/`--mem-to`. Add the guard right after `set -- "${_args[@]}"`.
- **Action block**: immediately after the `--edit` action block, before the `if [ -n "$NAME" ]` named-container section.

---

## Task 1: run-claude.sh

**Files:**
- Modify: `run-claude.sh` (usage header; pre-getopts scan + guard; action block)
- Test: `/tmp/test-mem-claude.sh` (throwaway harness)

- [ ] **Step 1: Write the failing test**

Create `/tmp/test-mem-claude.sh`:

```bash
#!/usr/bin/env bash
set -u
REPO="/home/awyl/codebase/awyl/Docker-Agent"
work="$(mktemp -d)/proj"; mkdir -p "$work"
fakehome="$(mktemp -d)"
slug="$(printf '%s' "$work" | sed 's/[/.]/-/g')"
hostmem="$fakehome/.claude/projects/$slug/memory"
confmem="$fakehome/.docker-agent/$(basename "$work")/claude/projects/-work/memory"

# --mem-from: host -> config
mkdir -p "$hostmem"; printf x > "$hostmem/t.md"
HOME="$fakehome" bash "$REPO/run-claude.sh" --mem-from -w "$work" >/dev/null 2>&1
[ -f "$confmem/t.md" ] && echo "FROM_PASS" || echo "FROM_FAIL"

# --mem-to: config -> host
printf y > "$confmem/u.md"
HOME="$fakehome" bash "$REPO/run-claude.sh" --mem-to -w "$work" >/dev/null 2>&1
[ -f "$hostmem/u.md" ] && echo "TO_PASS" || echo "TO_FAIL"

# mutual exclusion
HOME="$fakehome" bash "$REPO/run-claude.sh" --mem-from --mem-to -w "$work" >/dev/null 2>&1
[ "$?" -eq 2 ] && echo "EXCL_PASS" || echo "EXCL_FAIL"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/test-mem-claude.sh`
Expected: `FROM_FAIL` (getopts/scan does not know the flags yet).

- [ ] **Step 3: Add the usage header lines**

Change the Usage signature to include the flags (wrap to a second line), and after the `--edit` description line add:
```bash
#   --mem-from      Copy the work-dir memory FROM host into the config dir, then exit.
#   --mem-to        Copy the work-dir memory TO host from the config dir, then exit.
#                   --mem-from and --mem-to are mutually exclusive. Memory dir only;
#                   point-in-time copy (last writer wins). Honour -i/-H/-c and -w.
```
Add two examples to the header (`--mem-from` / `--mem-to`).

- [ ] **Step 4: Bump the help `sed` range**

The header grew by 7 lines: change `h) sed -n '2,29p' "$0"; exit 0 ;;` to `h) sed -n '2,36p' "$0"; exit 0 ;;`.

- [ ] **Step 5: Init flag vars**

Near `CONFIG_EXPLICIT=0`, add `MEM_FROM=0` and `MEM_TO=0`.

- [ ] **Step 6: Extend the pre-getopts scan + add the guard**

Replace the single `--edit` test in the existing scan loop with a `case`:
```bash
  if [ "$_stop" -eq 0 ]; then
    case "$_a" in
      --edit)     EDIT=1; continue ;;
      --mem-from) MEM_FROM=1; continue ;;
      --mem-to)   MEM_TO=1; continue ;;
    esac
  fi
```
After `set -- "${_args[@]}"`, add:
```bash
if [ $((MEM_FROM + MEM_TO)) -gt 1 ]; then
  echo "run-claude.sh: choose only one of --mem-from, --mem-to" >&2
  exit 2
fi
```

- [ ] **Step 7: Add the action block**

Immediately after the `--edit` action block (`if [ "$EDIT" -eq 1 ]; then ... fi`), insert:
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

- [ ] **Step 8: Run test to verify it passes**

Run: `bash /tmp/test-mem-claude.sh`
Expected: `FROM_PASS`, `TO_PASS`, `EXCL_PASS`.

- [ ] **Step 9: Syntax check**

Run: `bash -n run-claude.sh && echo OK`
Expected: `OK`

- [ ] **Step 10: Commit**

```bash
git add run-claude.sh
git commit -m "feat(run-claude): add --mem-from/--mem-to to sync work-dir memory"
```

---

## Task 2: README docs

**Files:**
- Modify: `README.md` (flag table; explanation; examples)

- [ ] **Step 1: Add two rows to the flag table** (after `--edit`):
```markdown
| `--mem-from` | Copy the work-dir memory **from** host into the config dir, then exit — no container (Claude only) | — |
| `--mem-to` | Copy the work-dir memory **to** host from the config dir, then exit — no container (Claude only) | — |
```

- [ ] **Step 2: Update the Run signature** to include `[--mem-from | --mem-to]`.

- [ ] **Step 3: Add an explanation paragraph** after the `--edit` note covering the slug mapping (container cwd `/work` → `-work` vs host slug), memory-dir-only / last-writer-wins, mutual exclusion, and `-i`/`-H`/`-c`/`-w` honouring. Note the other `run-*.sh` scripts do **not** take these flags.

- [ ] **Step 4: Add two examples** (`--mem-from`, `--mem-to`).

- [ ] **Step 5: Verify docs** — `grep -n -- '--mem-' README.md` shows signature, table rows, paragraph, examples.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/superpowers
git commit -m "docs: document --mem-from/--mem-to flags for run-claude.sh"
```

---

## Final verification (after all tasks)

- [ ] **Run the harness test:**

```bash
bash /tmp/test-mem-claude.sh
```
Expected: `FROM_PASS`, `TO_PASS`, `EXCL_PASS`.

- [ ] **Help text shows the flags and is not truncated:**

```bash
bash run-claude.sh -h | grep -- '--mem-' >/dev/null && echo OK || echo MISSING
```
Expected: `OK`

- [ ] **Normal launch is unchanged:** `run-claude.sh` with no mem flag still reaches the `docker run`/`exec` path (no early exit).
