#!/usr/bin/env bash
# Run the Hermes agent in a container.
#
# Usage:
#   run-hermes.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit] [-- <hermes args>]
#
#   (default)       Isolated per-project, per-agent config in
#                   ~/.docker-agent/<work-dir-name>/hermes. Fresh config; log in
#                   inside it on first run.
#   -i              Force the isolated config (this is the default; explicit form).
#   -H              Use the host config dir (~/.hermes) directly.
#   -c CONFIG_DIR   Use a custom config dir.
#                   -i, -H and -c are mutually exclusive.
#   --edit          Open the resolved config dir in $VISUAL/$EDITOR/nvim/vi and exit (no container).
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `hermes`.
#   With no hermes args, the interactive CLI starts.
#
# Examples:
#   run-hermes.sh                      # isolated config for current dir (default)
#   run-hermes.sh -H                   # host ~/.hermes config
#   run-hermes.sh -w ~/code/myproj     # isolated config, different repo
#   run-hermes.sh -n myproj            # create/reuse "myproj"
#   run-hermes.sh -- setup             # run the setup wizard
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.hermes \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-hermes:latest .
set -euo pipefail

IMAGE="${IMAGE:-agentic-hermes:latest}"
AGENT_CMD="hermes"
CONFIG_SRC="$HOME/.hermes"
CONFIG_DST="/home/dev/.hermes"
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

# Rootless Docker maps the host user to container root, so bind-mounted files
# appear owned by uid 0 and the non-root `dev` user cannot write them. Run as
# root in that case (root -> host user, owns the mounts). Rootful Docker keeps
# the UID-matched `dev` user. Override with USER_FLAG=... if needed.
if [ -z "${USER_FLAG+x}" ]; then
  if docker info 2>/dev/null | grep -q 'rootless: true'; then
    USER_FLAG="--user 0:0"
  else
    USER_FLAG=""
  fi
fi

# Extract the long flag --edit before getopts (which only handles short opts).
# Stop at `--` so agent passthrough args keep their own --edit, if any.
EDIT=0
_args=(); _stop=0
for _a in "$@"; do
  [ "$_stop" -eq 0 ] && [ "$_a" = "--" ] && _stop=1
  if [ "$_stop" -eq 0 ] && [ "$_a" = "--edit" ]; then EDIT=1; continue; fi
  _args+=("$_a")
done
set -- "${_args[@]}"

while getopts "c:iHw:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    H) HOST=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,25p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Isolated config is the default; -H (host) and -c (custom) opt out of it.
if [ $((ISOLATE + HOST + CONFIG_EXPLICIT)) -gt 1 ]; then
  echo "run-hermes.sh: choose only one of -i, -H, -c" >&2
  exit 2
fi
if [ "$HOST" -eq 0 ] && [ "$CONFIG_EXPLICIT" -eq 0 ]; then
  ISOLATE=1
fi

# Resolve the work dir up front; -i derives the config dir name from it.
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent: ~/.docker-agent/<work-dir-name>/hermes
  CONFIG_SRC="$HOME/.docker-agent/$(basename "$WORK_DIR")/hermes"
fi

mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# --edit: open the resolved host config dir in an editor, then exit (no container).
if [ "$EDIT" -eq 1 ]; then
  ED="${VISUAL:-${EDITOR:-}}"
  [ -z "$ED" ] && { command -v nvim >/dev/null 2>&1 && ED=nvim || ED=vi; }
  exec $ED "$CONFIG_SRC"
fi

# --- Named container: a persistent sandbox we exec the agent into ---
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    docker run -d --name "$NAME" $USER_FLAG \
      -v "$CONFIG_SRC":"$CONFIG_DST" \
      -v "$WORK_DIR":/work \
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it $USER_FLAG -w /work "$NAME" "$AGENT_CMD" "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
exec docker run --rm -it $USER_FLAG \
  -v "$CONFIG_SRC":"$CONFIG_DST" \
  -v "$WORK_DIR":/work \
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
  "$IMAGE" "$@"
