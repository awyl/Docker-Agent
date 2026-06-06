#!/usr/bin/env bash
# Run the goose agent in a container.
#
# Usage:
#   run-goose.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <goose args>]
#
#   (default)       Isolated per-project, per-agent config in
#                   ~/.docker-agent/<work-dir-name>/goose. Fresh config;
#                   config.yaml is seeded from the host.
#   -i              Force the isolated config (this is the default; explicit form).
#   -H              Use the host config dir (~/.config/goose) directly.
#   -c CONFIG_DIR   Use a custom config dir.
#                   -i, -H and -c are mutually exclusive.
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
ISOLATE=0
HOST=0
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

while getopts "c:iHw:n:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    H) HOST=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,24p' "$0"; exit 0 ;;
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

if [ "$ISOLATE" -eq 1 ]; then
  # Per-project AND per-agent: ~/.docker-agent/<work-dir-name>/goose
  CONFIG_SRC="$HOME/.docker-agent/$(basename "$WORK_DIR")/goose"
  # Seed config so the fresh isolated config keeps the host provider/model.
  if [ ! -e "$CONFIG_SRC/config.yaml" ] && [ -e "$HOME/.config/goose/config.yaml" ]; then
    mkdir -p "$CONFIG_SRC"
    cp "$HOME/.config/goose/config.yaml" "$CONFIG_SRC/config.yaml"
  fi
fi

mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# No args -> start an interactive session (goose's bare command only prints help).
if [ "$#" -eq 0 ]; then
  set -- session
fi

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
