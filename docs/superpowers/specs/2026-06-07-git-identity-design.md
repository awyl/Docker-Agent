# Pass host git identity into agent containers

**Date:** 2026-06-07
**Status:** Approved, ready for implementation plan

## Problem

Agent containers lose the host's git identity. Commits made inside a container
either fail with the "Please tell me who you are" prompt or land with an empty/wrong
author. The repo's own identity (in `<repo>/.git/config`) already rides along via the
`/work` bind mount, so it works — but the host's **global** `user.name` / `user.email`
(the fallback for repos that don't set their own) is missing.

## Goal

Make the host's global git identity the **fallback** identity inside every agent
container, while a repo's own identity always wins.

## Decisions

- **Global-precedence seed, not command-level env.** git config precedence is
  `local > global > system`. We want repo-local (`/work/.git/config`) to win, so the
  host identity must be seeded at **global** scope. `GIT_CONFIG_*` env is command-level
  (highest precedence) — it would override repo-local, so it is **not** used.
- **Generated minimal global config file, bind-mounted.** Global precedence requires a
  config *file*; there is no env that injects key/values at global scope. The runner
  generates a tiny gitconfig holding only `[user] name/email` and mounts it as the
  container's global config.
- **`GIT_CONFIG_GLOBAL` pins the path** so it works under rootless Docker too (where the
  container runs as root, `HOME=/root`, not `/home/dev`).
- **Identity only.** Host `credential.helper`, gpg program paths, and other host-specific
  keys are deliberately excluded — they would break or leak in the container.
- **Signing is out of scope.** The host does not force commit signing
  (no `user.signingkey` / `commit.gpgsign`), so no signing config is passed.
- **Runner-only change.** No Dockerfile/image change (git is already in the base; the
  feature is pure launcher wiring).
- **All four runners** (`run-claude/goose/hermes/pi.sh`).

## Design

### Identity resolution + file generation (each runner)

Add near the existing `SCCACHE_CACHE` block:

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

- Only keys the host actually has are written (handles name-only or email-only hosts).
- Read-only mount: the container cannot clobber the host file.
- `GIT_ID_FILE` is a single shared host file (`~/.docker-agent/gitconfig`) — host
  identity is the same regardless of project/agent.

### Injection into the launch blocks

Inject the array into **both** `docker run` blocks of each runner — the named-create
(`docker run -d ... --entrypoint sleep`) and the unnamed throwaway (`docker run --rm`):

```sh
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
```

- The `${GIT_ENV[@]+"${GIT_ENV[@]}"}` form expands to nothing when the array is empty,
  avoiding a `set -u` error and avoiding a bogus empty argument to `docker`.
- **Not** added to the `docker exec` line: env and mounts set at `docker run` creation
  are part of the container config, and `docker exec` inherits them. For named
  containers the identity is therefore fixed at creation time (same model as the
  existing mounts).

### Resulting behavior

| Situation | Identity used in container |
|-----------|----------------------------|
| Repo under `/work` sets its own `user.*` | Repo's identity (local > global) |
| Repo sets none | Host global identity (the seeded file) |
| Host has no global identity | Nothing injected; unchanged from today |
| Host has only name **or** only email | That one key seeded; the other unset |

Precedence is real git precedence, so it holds for any repo or sub-repo under `/work`
dynamically — no launch-time repo detection that could go stale.

## Out of scope

- Credential helpers / auth (pushing from inside the container).
- Commit signing (gpg/ssh).
- Any non-identity git config (aliases, includes, etc.).
- Per-project or per-agent distinct identities.

## Verification

- Host has global identity, repo under `/work` has **no** local identity:
  in-container `git config user.name` / `user.email` return the host values; a test
  commit records the host author.
- Repo under `/work` **has** a local identity: in-container `git config user.email`
  returns the repo value (host does not override it).
- Named container: create it, then a second `docker exec` invocation still sees the
  identity (env/mount inherited).
- Host with no global identity: runner injects nothing; container starts and behaves
  as before (no errors).
- All four runners pass `bash -n`.
