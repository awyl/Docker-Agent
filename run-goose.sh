#!/usr/bin/env bash
# Run the goose agent in a container.
#
# Usage:
#   run-goose.sh [-c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <goose args>]
#
#   -c CONFIG_DIR   goose config dir to mount      (default: ~/.config/goose)
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `goose`.
#   With no goose args, an interactive `goose session` is started.
#
# Examples:
#   run-goose.sh                       # throwaway -> goose session, current dir
#   run-goose.sh -n myproj             # create/reuse "myproj"
#   run-goose.sh -- --version          # pass args to goose
#   run-goose.sh -- configure          # run goose configure
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.goose \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-goose:latest .
set -euo pipefail

IMAGE="${IMAGE:-agentic-goose:latest}"
AGENT_CMD="goose"
CONFIG_SRC="$HOME/.config/goose"
CONFIG_DST="/home/dev/.config/goose"
WORK_DIR="$PWD"
NAME=""

while getopts "c:w:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,17p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# No args -> start an interactive session (goose's bare command only prints help).
if [ "$#" -eq 0 ]; then
  set -- session
fi

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
