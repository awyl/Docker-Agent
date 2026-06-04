#!/usr/bin/env bash
# Run Claude Code in a container.
#
# Usage:
#   run-claude.sh [-c CONFIG_DIR] [-w WORK_DIR] [-- <claude args>]
#
#   -c CONFIG_DIR   Claude config dir to mount   (default: ~/.claude)
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   anything after the options is passed through to `claude`.
#
# Examples:
#   run-claude.sh                                  # host config, current dir
#   run-claude.sh -w ~/code/myproj                 # different repo
#   run-claude.sh -c ~/.claude-sandbox -w /tmp/x   # throwaway config + repo
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

while getopts "c:w:h" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    h) sed -n '2,15p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Resolve to absolute paths; create config dir if missing so the mount works.
CONFIG_DIR="$(cd "$(dirname "$CONFIG_DIR")" 2>/dev/null && pwd)/$(basename "$CONFIG_DIR")" \
  || { mkdir -p "$CONFIG_DIR"; CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"; }
mkdir -p "$CONFIG_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# Project/trust state + mcpServers live next to the config dir as <dir>.json.
CONFIG_JSON="${CONFIG_DIR}.json"
touch "$CONFIG_JSON"

exec docker run --rm -it \
  -v "$CONFIG_DIR":/home/dev/.claude \
  -v "$CONFIG_JSON":/home/dev/.claude.json \
  -v "$WORK_DIR":/work \
  -w /work \
  "$IMAGE" "$@"
