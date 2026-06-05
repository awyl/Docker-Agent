#!/usr/bin/env bash
# Run the Hermes agent in a container.
#
# Usage:
#   run-hermes.sh [-c CONFIG_DIR | -i] [-w WORK_DIR] [-n NAME] [-- <hermes args>]
#
#   -c CONFIG_DIR   Hermes config dir to mount     (default: ~/.hermes)
#   -i              Isolated per-project, per-agent config in
#                   ~/.docker-agent/<work-dir-name>/hermes. Fresh config; log in
#                   inside it on first run. Mutually exclusive with -c.
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `hermes`.
#   With no hermes args, the interactive CLI starts.
#
# Examples:
#   run-hermes.sh                      # throwaway, host config, current dir
#   run-hermes.sh -i                   # isolated config for current dir
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
  echo "run-hermes.sh: -c and -i are mutually exclusive" >&2
  exit 2
fi

# Resolve the work dir up front; -i derives the config dir name from it.
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent: ~/.docker-agent/<work-dir-name>/hermes
  CONFIG_SRC="$HOME/.docker-agent/$(basename "$WORK_DIR")/hermes"
fi

mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# --- Named container: a persistent sandbox we exec the agent into ---
if [ -n "$NAME" ]; then
  if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
    docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
  else
    docker run -d --name "$NAME" $USER_FLAG \
      -v "$CONFIG_SRC":"$CONFIG_DST" \
      -v "$WORK_DIR":/work \
      -w /work --entrypoint sleep \
      "$IMAGE" infinity >/dev/null
  fi
  exec docker exec -it $USER_FLAG -w /work "$NAME" "$AGENT_CMD" "$@"
fi

# --- Unnamed: throwaway container, removed on exit ---
exec docker run --rm -it $USER_FLAG \
  -v "$CONFIG_SRC":"$CONFIG_DST" \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
