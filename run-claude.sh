#!/usr/bin/env bash
# Run Claude Code in a container.
#
# Usage:
#   run-claude.sh [-c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <claude args>]
#
#   -c CONFIG_DIR   Claude config dir to mount   (default: ~/.claude)
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container. First call creates it;
#                   later calls with the same NAME re-enter the same container
#                   instead of making a new one. Without -n the container is
#                   throwaway (removed on exit).
#   anything after the options is passed through to `claude`.
#
# Examples:
#   run-claude.sh                                  # throwaway, host config, cwd
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

while getopts "c:w:n:h" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,18p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# --- Named container: a persistent sandbox we exec claude into ---
# The container itself idles (sleep infinity); each invocation runs claude via
# `docker exec`, so the container survives claude exiting. Mounts are fixed when
# the container is first created -> -c/-w only matter on that first call.
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    # Exists already: just make sure it is running, then re-enter it.
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    # First time: resolve mounts and create the idle container.
    CONFIG_DIR="$(cd "$(dirname "$CONFIG_DIR")" 2>/dev/null && pwd)/$(basename "$CONFIG_DIR")" \
      || { mkdir -p "$CONFIG_DIR"; CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"; }
    mkdir -p "$CONFIG_DIR"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
    CONFIG_JSON="${CONFIG_DIR}.json"; touch "$CONFIG_JSON"
    docker run -d --name "$NAME" \
      -v "$CONFIG_DIR":/home/dev/.claude \
      -v "$CONFIG_JSON":/home/dev/.claude.json \
      -v "$WORK_DIR":/work \
      -w /work \
      --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it -w /work "$NAME" claude "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
CONFIG_DIR="$(cd "$(dirname "$CONFIG_DIR")" 2>/dev/null && pwd)/$(basename "$CONFIG_DIR")" \
  || { mkdir -p "$CONFIG_DIR"; CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"; }
mkdir -p "$CONFIG_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
CONFIG_JSON="${CONFIG_DIR}.json"; touch "$CONFIG_JSON"

exec docker run --rm -it \
  -v "$CONFIG_DIR":/home/dev/.claude \
  -v "$CONFIG_JSON":/home/dev/.claude.json \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
