#!/usr/bin/env bash
# Run the Pi coding agent in a container.
#
# Usage:
#   run-pi.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit] [-- <pi args>]
#
#   (default)       Isolated per-project, per-agent config in ~/.docker-agent/<work-dir-name>/pi.
#                   Fresh config (no host extensions); auth.json is seeded from
#                   ~/.pi so pi stays logged in, and the bundled default config
#                   (pi-default-config/) is seeded if the dir has none.
#   -i              Force the isolated config (this is the default; explicit form).
#   -H              Use the host config dir (~/.pi) directly.
#   -c CONFIG_DIR   Use a custom config dir.
#                   -i, -H and -c are mutually exclusive.
#   --edit          Open the resolved config dir in $VISUAL/$EDITOR/nvim/vi and exit (no container).
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container (see run-claude.sh).
#   anything after the options is passed through to `pi`.
#
# Examples:
#   run-pi.sh                          # isolated config for current dir (default)
#   run-pi.sh -H                       # host ~/.pi config
#   run-pi.sh -w ~/code/myproj         # isolated config for myproj
#   run-pi.sh -c ~/.pi-sandbox         # custom config dir
#   run-pi.sh -n myproj                # create/reuse "myproj"
#   run-pi.sh -- --version             # pass args to pi
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.pi \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-pi:latest .
set -euo pipefail

# Resolve this script's own dir (following symlinks, since install.sh symlinks
# it onto PATH) so we can find the bundled default config next to it.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

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
    h) sed -n '2,26p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Isolated config is the default; -H (host) and -c (custom) opt out of it.
if [ $((ISOLATE + HOST + CONFIG_EXPLICIT)) -gt 1 ]; then
  echo "run-pi.sh: choose only one of -i, -H, -c" >&2
  exit 2
fi
if [ "$HOST" -eq 0 ] && [ "$CONFIG_EXPLICIT" -eq 0 ]; then
  ISOLATE=1
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

# Seed the bundled default config into a config dir that has none yet
# (no agent/settings.json). cp -rn never clobbers, so an auth.json seeded
# above and any existing config survive. Applies to -i, default ~/.pi, and -c.
DEFAULT_CONFIG="$SCRIPT_DIR/pi-default-config"
if [ ! -e "$CONFIG_SRC/agent/settings.json" ] && [ -d "$DEFAULT_CONFIG/agent" ]; then
  mkdir -p "$CONFIG_SRC/agent"
  cp -rn "$DEFAULT_CONFIG/agent/." "$CONFIG_SRC/agent/"
fi

# --edit: open the resolved (now-seeded) host config dir in an editor, then exit.
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
