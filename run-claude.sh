#!/usr/bin/env bash
# Run Claude Code in a container.
#
# Usage:
#   run-claude.sh [-c CONFIG_DIR | -i] [-w WORK_DIR] [-n NAME] [-- <claude args>]
#
#   -c CONFIG_DIR   Claude config dir to mount   (default: ~/.claude)
#   -i              Isolated per-project, per-agent config in
#                   ~/.docker-agent/<work-dir-name>/claude. Fresh config;
#                   .credentials.json is seeded from ~/.claude so Claude stays
#                   logged in. Mutually exclusive with -c.
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container. First call creates it;
#                   later calls with the same NAME re-enter the same container
#                   instead of making a new one. Without -n the container is
#                   throwaway (removed on exit).
#   anything after the options is passed through to `claude`.
#
# Examples:
#   run-claude.sh                                  # throwaway, host config, cwd
#   run-claude.sh -i                               # isolated config for cwd
#   run-claude.sh -w ~/code/myproj                 # different repo
#   run-claude.sh -c ~/.claude-sandbox -w /tmp/x   # throwaway config + repo
#   run-claude.sh -n myproj                        # create/reuse "myproj"
#   run-claude.sh -- --version                     # pass args to claude
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.claude \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-claude:latest .
set -euo pipefail

IMAGE="${IMAGE:-agentic-claude:latest}"
CONFIG_DIR="$HOME/.claude"
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
    c) CONFIG_DIR="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,24p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$ISOLATE" -eq 1 ] && [ "$CONFIG_EXPLICIT" -eq 1 ]; then
  echo "run-claude.sh: -c and -i are mutually exclusive" >&2
  exit 2
fi

# Resolve the work dir up front; -i derives the config dir name from it.
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent: ~/.docker-agent/<work-dir-name>/claude
  CONFIG_DIR="$HOME/.docker-agent/$(basename "$WORK_DIR")/claude"
  # Seed credentials so the fresh isolated config is already logged in.
  if [ ! -e "$CONFIG_DIR/.credentials.json" ] && [ -e "$HOME/.claude/.credentials.json" ]; then
    mkdir -p "$CONFIG_DIR"
    cp "$HOME/.claude/.credentials.json" "$CONFIG_DIR/.credentials.json"
  fi
fi

mkdir -p "$CONFIG_DIR"; CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"
# Claude keeps a sibling ~/.claude.json file alongside the config dir.
CONFIG_JSON="${CONFIG_DIR}.json"; touch "$CONFIG_JSON"

# --- Named container: a persistent sandbox we exec claude into ---
# The container itself idles (sleep infinity); each invocation runs claude via
# `docker exec`, so the container survives claude exiting. Mounts are fixed when
# the container is first created -> -c/-i/-w only matter on that first call.
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    # Exists already: just make sure it is running, then re-enter it.
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    # First time: create the idle container with the resolved mounts.
    docker run -d --name "$NAME" $USER_FLAG \
      -v "$CONFIG_DIR":/home/dev/.claude \
      -v "$CONFIG_JSON":/home/dev/.claude.json \
      -v "$WORK_DIR":/work \
      -w /work \
      --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it $USER_FLAG -w /work "$NAME" claude "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
exec docker run --rm -it $USER_FLAG \
  -v "$CONFIG_DIR":/home/dev/.claude \
  -v "$CONFIG_JSON":/home/dev/.claude.json \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
