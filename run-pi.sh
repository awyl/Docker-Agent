#!/usr/bin/env bash
# Run the Pi coding agent in a container.
#
# Usage:
#   run-pi.sh [-c CONFIG_DIR | -i] [-w WORK_DIR] [-n NAME] [-- <pi args>]
#
#   -c CONFIG_DIR   Pi config dir to mount        (default: ~/.pi)
#   -i              Isolated per-project, per-agent config in ~/.docker-agent/<work-dir-name>/pi.
#                   Fresh config (no host extensions); auth.json is seeded from
#                   ~/.pi so pi stays logged in. Mutually exclusive with -c.
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `pi`.
#
# Examples:
#   run-pi.sh                          # throwaway, host config, current dir
#   run-pi.sh -i                       # isolated config for current dir
#   run-pi.sh -i -w ~/code/myproj      # isolated config for myproj
#   run-pi.sh -w ~/code/myproj         # different repo, host config
#   run-pi.sh -n myproj                # create/reuse "myproj"
#   run-pi.sh -- --version             # pass args to pi
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.pi \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-pi:latest .
set -euo pipefail

IMAGE="${IMAGE:-agentic-pi:latest}"
AGENT_CMD="pi"
CONFIG_SRC="$HOME/.pi"
CONFIG_DST="/home/dev/.pi"
# Plugins that store state in $XDG_DATA_HOME (default ~/.local/share, ephemeral
# here) are redirected under the mounted config dir so they persist. Matches the
# ENV baked into the image; set explicitly so it holds even on an older image.
XDG_DATA_DST="$CONFIG_DST/share"
WORK_DIR="$PWD"
NAME=""
ISOLATE=0
CONFIG_EXPLICIT=0

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

while getopts "c:iw:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,21p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$ISOLATE" -eq 1 ] && [ "$CONFIG_EXPLICIT" -eq 1 ]; then
  echo "run-pi.sh: -c and -i are mutually exclusive" >&2
  exit 2
fi

# Resolve the work dir up front; -i derives the config dir name from it.
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent: ~/.docker-agent/<work-dir-name>/pi
  CONFIG_SRC="$HOME/.docker-agent/$(basename "$WORK_DIR")/pi"
  # Seed auth so the fresh isolated config is already logged in.
  if [ ! -e "$CONFIG_SRC/agent/auth.json" ] && [ -e "$HOME/.pi/agent/auth.json" ]; then
    mkdir -p "$CONFIG_SRC/agent"
    cp "$HOME/.pi/agent/auth.json" "$CONFIG_SRC/agent/auth.json"
  fi
fi

mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# --- Named container: a persistent sandbox we exec the agent into ---
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    docker run -d --name "$NAME" $USER_FLAG \
      -e "XDG_DATA_HOME=$XDG_DATA_DST" \
      -v "$CONFIG_SRC":"$CONFIG_DST" \
      -v "$WORK_DIR":/work \
      -w /work --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it $USER_FLAG -e "XDG_DATA_HOME=$XDG_DATA_DST" -w /work "$NAME" "$AGENT_CMD" "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
exec docker run --rm -it $USER_FLAG \
  -e "XDG_DATA_HOME=$XDG_DATA_DST" \
  -v "$CONFIG_SRC":"$CONFIG_DST" \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
