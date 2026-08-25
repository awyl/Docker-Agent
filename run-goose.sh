#!/usr/bin/env bash
# Run the goose agent in a container.
#
# Usage:
#   run-goose.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit] [-- <goose args>]
#
#   (default)       Isolated per-project, per-agent config in
#                   ~/.docker-agent/<repo-name>-<root12>/goose, keyed to the repo's
#                   root commit so renaming or moving the checkout still finds it.
#                   The work dir must be a git repo with at least one commit. Fresh config;
#                   config.yaml is seeded from the host.
#   -i              Force the isolated config (this is the default; explicit form).
#   -H              Use the host config dir (~/.config/goose) directly.
#   -c CONFIG_DIR   Use a custom config dir.
#                   -i, -H and -c are mutually exclusive.
#   --edit          Open the resolved config dir in $VISUAL/$EDITOR/nvim/vi and exit (no container).
#   --del [STORE]   Delete this agent's isolated config, then exit. Asks you to
#                   type the name back to confirm. Only valid for the isolated
#                   config (not -H/-c). With no STORE the work dir's repo names
#                   the store; pass a STORE directory name (see the list printed
#                   on a miss) to delete one whose checkout is already gone.
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `goose`.
#   With no goose args, an interactive `goose session` is started.
#
# Examples:
#   run-goose.sh                       # isolated config -> goose session (default)
#   run-goose.sh -H                    # host ~/.config/goose config
#   run-goose.sh -n myproj             # create/reuse "myproj"
#   run-goose.sh -- --version          # pass args to goose
#   run-goose.sh -- configure          # run goose configure
#
# Build once (on macOS, `container build` in place of `docker build`):
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.goose \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-goose:latest .
set -euo pipefail

# Resolve this script's own dir (following symlinks, since install.sh symlinks
# it onto PATH) so we can find the shared library next to it.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Shared store resolver: repo identity, legacy migration, --del by name.
. "$SCRIPT_DIR/lib/store.sh"
. "$SCRIPT_DIR/lib/engine.sh"

IMAGE="${IMAGE:-agentic-goose:latest}"
AGENT_CMD="goose"
CONFIG_SRC="$HOME/.config/goose"
CONFIG_DST="/home/dev/.config/goose"
WORK_DIR="$PWD"
NAME=""
ISOLATE=0
HOST=0
CONFIG_EXPLICIT=0

# Persistent sccache compile cache, shared with the host. Pin to the host default
# (~/.cache/sccache) unless SCCACHE_DIR is already exported. Created before the
# mount so Docker doesn't materialize a root-owned dir.
SCCACHE_CACHE="${SCCACHE_DIR:-$HOME/.cache/sccache}"
mkdir -p "$SCCACHE_CACHE"

# Cargo registry + git caches, shared with the host so agents inside the container
# can read crate source code (registry/src, git checkouts). Pin to the host default
# (~/.cargo) unless CARGO_HOME is exported. Created before the mount so Docker
# doesn't materialize root-owned dirs.
CARGO_HOST="${CARGO_HOME:-$HOME/.cargo}"
mkdir -p "$CARGO_HOST/git" "$CARGO_HOST/registry"

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

engine_select run-goose.sh || exit 1
engine_user_flag
engine_run_opts

# Extract the long flags --edit/--del before getopts (which only handles short opts).
# Stop at `--` so agent passthrough args keep their own --edit, if any.
EDIT=0
DEL=0
DEL_NAME=""
_args=(); _stop=0; _want_name=0
for _a in "$@"; do
  [ "$_stop" -eq 0 ] && [ "$_a" = "--" ] && _stop=1
  # `--del [STORE]`: a bare word right after --del names the store directly.
  if [ "$_want_name" -eq 1 ]; then
    _want_name=0
    case "$_a" in -*) ;; *) DEL_NAME="$_a"; continue ;; esac
  fi
  if [ "$_stop" -eq 0 ] && [ "$_a" = "--edit" ]; then EDIT=1; continue; fi
  if [ "$_stop" -eq 0 ] && [ "$_a" = "--del" ]; then DEL=1; _want_name=1; continue; fi
  _args+=("$_a")
done
set -- ${_args[@]+"${_args[@]}"}

if [ $((DEL + EDIT)) -gt 1 ]; then
  echo "run-goose.sh: choose only one of --del, --edit" >&2
  exit 2
fi

while getopts "c:iHw:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    H) HOST=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,38p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Isolated config is the default; -H (host) and -c (custom) opt out of it.
if [ $((ISOLATE + HOST + CONFIG_EXPLICIT)) -gt 1 ]; then
  echo "run-goose.sh: choose only one of -i, -H, -c" >&2
  exit 2
fi
if [ "$HOST" -eq 0 ] && [ "$CONFIG_EXPLICIT" -eq 0 ]; then
  ISOLATE=1
fi

# Resolve the work dir up front; -i derives the config dir name from it.
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# --del: remove this agent's isolated config for the work dir, then exit. Only
# touches the isolated ~/.docker-agent path — never -H host config or -c custom.
if [ "$DEL" -eq 1 ]; then
  if [ "$ISOLATE" -ne 1 ]; then
    echo "run-goose.sh: --del only removes the isolated config; not valid with -H or -c" >&2
    exit 2
  fi
  if [ -n "$DEL_NAME" ]; then
    # Named form: needs no repo, for a checkout that is already gone.
    STORE="$(store_by_name "$DEL_NAME" run-goose.sh)" || exit 1
    PROJ="$DEL_NAME"
  else
    _id="$(store_repo_id "$WORK_DIR" run-goose.sh)" || exit 1
    PROJ="$(store_label "$WORK_DIR")"
    STORE="$(store_dir_for "$_id" "$PROJ")"
  fi
  DEL_DIR="$STORE/goose"
  if [ ! -e "$DEL_DIR" ]; then
    echo "--del: nothing to delete at $DEL_DIR"; exit 0
  fi
  printf 'About to delete %s\nType the project name (%s) to confirm: ' "$DEL_DIR" "$PROJ"
  read -r _ans
  [ "$_ans" = "$PROJ" ] || { echo "aborted"; exit 1; }
  rm -rf "$DEL_DIR"
  [ -e "$DEL_DIR.json" ] && rm -f "$DEL_DIR.json"        # sibling .json (no-op for goose)
  store_prune "$STORE"                                   # prune parent if now empty
  echo "deleted $DEL_DIR"
  exit 0
fi

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent, keyed to the repo's root commit rather than the
  # folder name: ~/.docker-agent/<repo-name>-<root12>/goose
  _id="$(store_repo_id "$WORK_DIR" run-goose.sh)" || exit 1
  CONFIG_SRC="$(store_dir_for "$_id" "$(store_label "$WORK_DIR")")/goose"
  # Seed config so the fresh isolated config keeps the host provider/model.
  if [ ! -e "$CONFIG_SRC/config.yaml" ] && [ -e "$HOME/.config/goose/config.yaml" ]; then
    mkdir -p "$CONFIG_SRC"
    cp "$HOME/.config/goose/config.yaml" "$CONFIG_SRC/config.yaml"
  fi
fi

mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# --edit: open the resolved (now-seeded) host config dir in an editor, then exit.
if [ "$EDIT" -eq 1 ]; then
  ED="${VISUAL:-${EDITOR:-}}"
  [ -z "$ED" ] && { command -v nvim >/dev/null 2>&1 && ED=nvim || ED=vi; }
  exec $ED "$CONFIG_SRC"
fi

# No args -> start an interactive session (goose's bare command only prints help).
if [ "$#" -eq 0 ]; then
  set -- session
fi

# --- Named container: a persistent sandbox we exec the agent into ---
if [ -n "$NAME" ]; then
  if ctr_exists "$NAME"; then
    ctr_running "$NAME" || "$ENGINE" start "$NAME" >/dev/null
  else
    "$ENGINE" run -d --name "$NAME" $USER_FLAG \
      ${ENGINE_RUN_OPTS[@]+"${ENGINE_RUN_OPTS[@]}"} \
      -v "$CONFIG_SRC":"$CONFIG_DST" \
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      -v "$CARGO_HOST/git":/home/dev/.cargo/git \
      -v "$CARGO_HOST/registry":/home/dev/.cargo/registry \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec "$ENGINE" exec -it $USER_FLAG -w /work "$NAME" "$AGENT_CMD" "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
exec "$ENGINE" run --rm -it $USER_FLAG \
  ${ENGINE_RUN_OPTS[@]+"${ENGINE_RUN_OPTS[@]}"} \
  -v "$CONFIG_SRC":"$CONFIG_DST" \
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  -v "$CARGO_HOST/git":/home/dev/.cargo/git \
  -v "$CARGO_HOST/registry":/home/dev/.cargo/registry \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
  "$IMAGE" "$@"
