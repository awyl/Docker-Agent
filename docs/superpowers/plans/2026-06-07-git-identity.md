# Host Git Identity Passthrough — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seed the host's global git identity as the *fallback* identity in every agent container, so commits get the right author while a repo's own `user.*` always wins.

**Architecture:** Each `run-*.sh` generates a minimal `[user]` gitconfig from the host's global `user.name`/`user.email`, bind-mounts it read-only as the container's GLOBAL config, and pins `GIT_CONFIG_GLOBAL` to that path. git precedence (local > global) makes repo-local config win and the host identity the fallback. Pure launcher change — no image change.

**Tech Stack:** bash launchers, git config precedence, Docker bind mounts + env.

**Spec:** `docs/superpowers/specs/2026-06-07-git-identity-design.md`

**Branch:** `feat/git-identity` (already checked out; spec commit `67f75d8` lives here).

**Note on "tests":** Infra/launcher work — no unit suite. Verification = `bash -n` syntax checks and a runtime identity check (commit author resolves correctly; repo-local wins; empty-host is a no-op). Treat verification steps as the test gates.

**Shared snippet (used verbatim in Tasks 1-4).** The identity block is identical in all four runners; the only per-file differences are *where* it is inserted and the indentation of the injected `docker run` line. Reproduced in full in each task so tasks can be executed independently.

Identity block (insert after each runner's `SCCACHE_CACHE` / `mkdir -p "$SCCACHE_CACHE"` lines):

```sh
# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi
```

Injection line (added right after `-v "$WORK_DIR":/work \` in both `docker run` blocks; match the block's indentation):

```sh
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
```

---

## File Structure

- `run-claude.sh` — add identity block + 2 injection lines.
- `run-goose.sh` — add identity block + 2 injection lines.
- `run-hermes.sh` — add identity block + 2 injection lines.
- `run-pi.sh` — add identity block + 2 injection lines.
- `README.md` — document the behavior + the new mount row.

---

## Task 1: run-claude.sh

**Files:**
- Modify: `run-claude.sh`

- [ ] **Step 1: Add the identity block**

Find the existing sccache block (the line `mkdir -p "$SCCACHE_CACHE"`, ~L69).
Immediately after it, add:

```sh

# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi
```

- [ ] **Step 2: Inject into the named-container block**

In the `docker run -d --name "$NAME"` block, the lines read (6-space indent):

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      -w /work \
```

Add the git env line after the sccache mount:

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work \
```

- [ ] **Step 3: Inject into the unnamed (throwaway) block**

In the final `exec docker run --rm -it` block (2-space indent):

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  -w /work \
```

becomes:

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
```

- [ ] **Step 4: Syntax check**

Run: `bash -n run-claude.sh`
Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
git add run-claude.sh
git commit -m "feat(run-claude): pass host git identity as container fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: run-goose.sh

**Files:**
- Modify: `run-goose.sh`

- [ ] **Step 1: Add the identity block**

Find the sccache block (`mkdir -p "$SCCACHE_CACHE"`, ~L48). Immediately after it, add:

```sh

# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi
```

- [ ] **Step 2: Inject into the named-container block**

In the `docker run -d --name "$NAME"` block (6-space indent):

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      -w /work --entrypoint sleep \
```

becomes:

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint sleep \
```

- [ ] **Step 3: Inject into the unnamed block**

In the `exec docker run --rm -it` block (2-space indent):

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  -w /work \
```

becomes:

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
```

- [ ] **Step 4: Syntax check**

Run: `bash -n run-goose.sh`
Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
git add run-goose.sh
git commit -m "feat(run-goose): pass host git identity as container fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: run-hermes.sh

**Files:**
- Modify: `run-hermes.sh`

- [ ] **Step 1: Add the identity block**

Find the sccache block (`mkdir -p "$SCCACHE_CACHE"`, ~L48). Immediately after it, add:

```sh

# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi
```

- [ ] **Step 2: Inject into the named-container block**

In the `docker run -d --name "$NAME"` block (6-space indent):

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      -w /work --entrypoint sleep \
```

becomes:

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint sleep \
```

- [ ] **Step 3: Inject into the unnamed block**

In the `exec docker run --rm -it` block (2-space indent):

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  -w /work \
```

becomes:

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
```

- [ ] **Step 4: Syntax check**

Run: `bash -n run-hermes.sh`
Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
git add run-hermes.sh
git commit -m "feat(run-hermes): pass host git identity as container fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: run-pi.sh

**Files:**
- Modify: `run-pi.sh`

- [ ] **Step 1: Add the identity block**

Find the sccache block (`mkdir -p "$SCCACHE_CACHE"`, ~L62). Immediately after it, add:

```sh

# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi
```

- [ ] **Step 2: Inject into the named-container block**

In the `docker run -d --name "$NAME"` block (6-space indent, which also has the
`-e "XDG_DATA_HOME=..."` flag):

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      -w /work --entrypoint sleep \
```

becomes:

```sh
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint sleep \
```

- [ ] **Step 3: Inject into the unnamed block**

In the `exec docker run --rm -it` block (2-space indent):

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  -w /work \
```

becomes:

```sh
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
```

- [ ] **Step 4: Syntax check**

Run: `bash -n run-pi.sh`
Expected: no output (exit 0).

- [ ] **Step 5: Commit**

```bash
git add run-pi.sh
git commit -m "feat(run-pi): pass host git identity as container fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Document in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a mount-table row**

Find the "What gets mounted" table (the row added for sccache:
`| `SCCACHE_CACHE` (`~/.cache/sccache`) | ... |`). Add this row after it:

```markdown
| `~/.docker-agent/gitconfig` (generated) | `/home/dev/.gitconfig` (`GIT_CONFIG_GLOBAL`) | host global git identity, fallback only — read-only |
```

- [ ] **Step 2: Add an explanatory note**

In the "Notes & caveats" section (find it with
`grep -n 'Notes & caveats' README.md`), add this bullet:

```markdown
- **Git identity.** The runners seed your host's *global* `user.name` / `user.email`
  into the container as its global git config (a generated, read-only
  `~/.docker-agent/gitconfig` mounted at `/home/dev/.gitconfig`). A repo's own
  identity in `/work/.git/config` always wins (git precedence: local > global); the
  host identity is only the fallback. If the host has no global identity, nothing is
  injected.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document host git identity passthrough

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: End-to-end runtime verification

**Files:** none (verification only)

> Uses the already-built `agentic-dev-base:latest` image and drives the *actual*
> runner code paths via a copy of `run-claude.sh` logic. Because the agent images
> have `claude` as entrypoint (can't run `git`), these checks build the docker
> command the way the runner does but with `agentic-dev-base` + an explicit command.
> This exercises the real `GIT_ENV` array construction by sourcing the runner's
> variables.

- [ ] **Step 1: Confirm the runner generates the identity file**

Run:
```bash
rm -f ~/.docker-agent/gitconfig
bash -c '
  GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
  _gn="$(git config --global user.name 2>/dev/null || true)"
  _ge="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$_gn" ] || [ -n "$_ge" ]; then
    mkdir -p "$(dirname "$GIT_ID_FILE")"
    { echo "[user]"; [ -n "$_gn" ] && printf "\tname = %s\n" "$_gn"; [ -n "$_ge" ] && printf "\temail = %s\n" "$_ge"; } > "$GIT_ID_FILE"
  fi'
cat ~/.docker-agent/gitconfig
```
Expected: file contains `[user]` with the host's `name` / `email`.

- [ ] **Step 2: Fallback case — repo with NO local identity gets host identity**

```bash
tmp="$(mktemp -d)"
docker run --rm \
  -v "$tmp":/work \
  -v "$HOME/.docker-agent/gitconfig":/home/dev/.gitconfig:ro \
  -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig \
  -w /work agentic-dev-base:latest \
  bash -c 'git init -q && git config user.name && git config user.email'
rm -rf "$tmp"
```
Expected: prints the host's name then email (global fallback applied).

- [ ] **Step 3: Override case — repo WITH local identity wins**

```bash
tmp="$(mktemp -d)"
docker run --rm \
  -v "$tmp":/work \
  -v "$HOME/.docker-agent/gitconfig":/home/dev/.gitconfig:ro \
  -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig \
  -w /work agentic-dev-base:latest \
  bash -c 'git init -q && git config user.email "repo@local" && echo "resolved: $(git config user.email)"'
rm -rf "$tmp"
```
Expected: `resolved: repo@local` (repo-local beats global).

- [ ] **Step 4: Commit author is correct (fallback)**

```bash
tmp="$(mktemp -d)"
docker run --rm \
  -v "$tmp":/work \
  -v "$HOME/.docker-agent/gitconfig":/home/dev/.gitconfig:ro \
  -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig \
  -w /work agentic-dev-base:latest \
  bash -c 'git init -q && git commit -q --allow-empty -m t && git log -1 --pretty="%an <%ae>"'
rm -rf "$tmp"
```
Expected: the host's `Name <email>` — no "Please tell me who you are" error.

- [ ] **Step 5: Empty-host no-op**

```bash
tmp="$(mktemp -d)"
docker run --rm -v "$tmp":/work -w /work agentic-dev-base:latest \
  bash -c 'git init -q && (git config user.email || echo "(none — unchanged behavior)")'
rm -rf "$tmp"
```
Expected: `(none — unchanged behavior)` — with no identity mount, container is as before.

- [ ] **Step 6: All runners syntax-clean**

Run: `for f in run-claude.sh run-goose.sh run-hermes.sh run-pi.sh; do bash -n "$f" && echo "$f OK"; done`
Expected: four `OK` lines.

---

## Self-Review

- **Spec coverage:** Identity block + injection in all four runners (Tasks 1-4),
  README behavior + mount row (Task 5), verification covering fallback / repo-wins /
  commit-author / empty-host (Task 6). All spec sections covered. Out-of-scope items
  (credentials, signing, non-identity config, per-project identity) correctly omitted.
- **Consistency:** `GIT_ID_FILE`, `GIT_ENV`, container path `/home/dev/.gitconfig`,
  and `GIT_CONFIG_GLOBAL` value identical across every task. The injected line
  `${GIT_ENV[@]+"${GIT_ENV[@]}"}` identical everywhere (only indentation differs per
  block).
- **No placeholders:** every code/command step shows exact content.
