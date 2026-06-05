#!/usr/bin/env bash
# Run the Hermes agent in a container.
#
# Usage:
#   run-hermes.sh [-c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <hermes args>]
#
#   -c CONFIG_DIR   Hermes config dir to mount     (default: ~/.hermes)
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `hermes`.
#   With no hermes args, the interactive CLI starts.
#
# Examples:
#   run-hermes.sh                      # throwaway, host config, current dir
#   run-hermes.sh -w ~/code/myproj     # different repo
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
