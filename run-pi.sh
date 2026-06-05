#!/usr/bin/env bash
# Run the Pi coding agent in a container.
#
# Usage:
#   run-pi.sh [-c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <pi args>]
#
#   -c CONFIG_DIR   Pi config dir to mount        (default: ~/.pi)
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `pi`.
#
# Examples:
#   run-pi.sh                          # throwaway, host config, current dir
#   run-pi.sh -w ~/code/myproj         # different repo
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
WORK_DIR="$PWD"
NAME=""

while getopts "c:w:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,15p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# --- Named container: a persistent sandbox we exec the agent into ---
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"
    WORK_DIR="$(cd "$WORK_DIR" && pwd)"
    docker run -d --name "$NAME" \
      -v "$CONFIG_SRC":"$CONFIG_DST" \
      -v "$WORK_DIR":/work \
      -w /work --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it -w /work "$NAME" "$AGENT_CMD" "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

exec docker run --rm -it \
  -v "$CONFIG_SRC":"$CONFIG_DST" \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
