#!/usr/bin/env bash
# Run Claude Code in a container.
#
# Usage:
#   run-claude.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit]
#                 [--mem-from | --mem-to] [-- <claude args>]
#
#   (default)       Isolated per-project, per-agent config in
#                   ~/.docker-agent/<work-dir-name>/claude. Fresh config;
#                   .credentials.json is seeded from ~/.claude so Claude stays
#                   logged in.
#   -i              Force the isolated config (this is the default; explicit form).
#   -H              Use the host config dir (~/.claude) directly.
#   -c CONFIG_DIR   Use a custom config dir.
#                   -i, -H and -c are mutually exclusive.
#   --edit          Open the resolved config dir in $VISUAL/$EDITOR/nvim/vi and exit (no container).
#   --mem-from      Copy the work-dir memory FROM host into the config dir, then exit.
#   --mem-to        Copy the work-dir memory TO host from the config dir, then exit.
#                   --mem-from and --mem-to are mutually exclusive. Memory dir only;
#                   point-in-time copy (last writer wins). Honour -i/-H/-c and -w.
#   -w WORK_DIR     Codebase dir to mount as /work (default: current dir)
#   -n NAME         Reuse a persistent named container. First call creates it;
#                   later calls with the same NAME re-enter the same container
#                   instead of making a new one. Without -n the container is
#                   throwaway (removed on exit).
#   anything after the options is passed through to `claude`.
#
# Examples:
#   run-claude.sh                                  # isolated config for cwd (default)
#   run-claude.sh -H                               # host ~/.claude config
#   run-claude.sh -w ~/code/myproj                 # isolated config, different repo
#   run-claude.sh -c ~/.claude-sandbox -w /tmp/x   # custom config + repo
#   run-claude.sh -n myproj                        # create/reuse "myproj"
#   run-claude.sh --mem-from                       # seed container memory from host
#   run-claude.sh --mem-to                         # save container memory back to host
#   run-claude.sh -- --version                     # pass args to claude
#
# Build once:
#   docker build -t agentic-dev-base:latest .
#   docker build -f Dockerfile.claude \
#     --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
#     -t agentic-claude:latest .
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

IMAGE="${IMAGE:-agentic-claude:latest}"
CONFIG_DIR="$HOME/.claude"
WORK_DIR="$PWD"
NAME=""
ISOLATE=0
HOST=0
CONFIG_EXPLICIT=0
MEM_FROM=0
MEM_TO=0

# Persistent sccache compile cache, shared with the host. Pin to the host default
# (~/.cache/sccache) unless SCCACHE_DIR is already exported. Created before the
# mount so Docker doesn't materialize a root-owned dir.
SCCACHE_CACHE="${SCCACHE_DIR:-$HOME/.cache/sccache}"
mkdir -p "$SCCACHE_CACHE"

# Seed the host's global git identity as the container's GLOBAL config, so a repo's
# own user.name/email (in the mounted /work/.git/config) takes precedence and the
# host identity is only the fallback. Regenerated each launch; skipped entirely if
# the host has no global identity (container then behaves as today).
GIT_ID_FILE="$HOME/.docker-agent/gitconfig"
_gn="$(git config --global user.name  2>/dev/null || true)"
_ge="$(git config --global user.email 2>/dev/null || true)"
GIT_ENV=()
if [ -n "$_gn" ] || [ -n "$_ge" ]; then
  mkdir -p "$(dirname "$GIT_ID_FILE")"
  { echo "[user]"
    [ -n "$_gn" ] && printf '\tname = %s\n'  "$_gn"
    [ -n "$_ge" ] && printf '\temail = %s\n' "$_ge"
  } > "$GIT_ID_FILE"
  GIT_ENV=(-v "$GIT_ID_FILE":/home/dev/.gitconfig:ro -e GIT_CONFIG_GLOBAL=/home/dev/.gitconfig)
fi

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

# Extract long flags (--edit, --mem-from, --mem-to) before getopts (which only
# handles short opts). Stop at `--` so agent passthrough args keep their own, if any.
EDIT=0
_args=(); _stop=0
for _a in "$@"; do
  [ "$_stop" -eq 0 ] && [ "$_a" = "--" ] && _stop=1
  if [ "$_stop" -eq 0 ]; then
    case "$_a" in
      --edit)     EDIT=1; continue ;;
      --mem-from) MEM_FROM=1; continue ;;
      --mem-to)   MEM_TO=1; continue ;;
    esac
  fi
  _args+=("$_a")
done
set -- "${_args[@]}"

if [ $((MEM_FROM + MEM_TO)) -gt 1 ]; then
  echo "run-claude.sh: choose only one of --mem-from, --mem-to" >&2
  exit 2
fi

while getopts "c:iHw:n:h" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    H) HOST=1 ;;
    w) WORK_DIR="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    h) sed -n '2,36p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Isolated config is the default; -H (host) and -c (custom) opt out of it.
if [ $((ISOLATE + HOST + CONFIG_EXPLICIT)) -gt 1 ]; then
  echo "run-claude.sh: choose only one of -i, -H, -c" >&2
  exit 2
fi
if [ "$HOST" -eq 0 ] && [ "$CONFIG_EXPLICIT" -eq 0 ]; then
  ISOLATE=1
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
# Claude keeps a sibling ~/.claude.json file alongside the config dir. It must
# exist as a file before the bind mount, or Docker creates a *directory* there.
# Claude parses it as JSON, so an empty file (plain `touch`) trips a startup
# "JSON Parse error: Unexpected EOF" — seed it with {} when missing or empty.
CONFIG_JSON="${CONFIG_DIR}.json"
# Claude stores login (oauthAccount/userID) and onboarding state in this sibling
# file, not in the config dir. A fresh isolated config with an empty {} here
# would re-prompt for login + theme on every new project, so seed just those
# keys from the host ~/.claude.json. No project history, MCP servers, or caches
# are carried over, keeping the per-project config isolated. Falls back to {} if
# the file already has content, isn't isolated, or python3/host config is absent
# (an empty file would trip "JSON Parse error: Unexpected EOF" on startup).
HOST_JSON="$HOME/.claude.json"
if [ ! -s "$CONFIG_JSON" ]; then
  if [ "$ISOLATE" -eq 1 ] && [ -s "$HOST_JSON" ] && command -v python3 >/dev/null 2>&1; then
    HOST_JSON="$HOST_JSON" CONFIG_JSON="$CONFIG_JSON" \
    SEED_KEYS="oauthAccount userID hasCompletedOnboarding lastOnboardingVersion firstStartTime" \
    python3 -c 'import json, os
src = json.load(open(os.environ["HOST_JSON"]))
keys = os.environ["SEED_KEYS"].split()
json.dump({k: src[k] for k in keys if k in src}, open(os.environ["CONFIG_JSON"], "w"))' \
      || printf '{}\n' > "$CONFIG_JSON"
  else
    printf '{}\n' > "$CONFIG_JSON"
  fi
fi

# Seed the bundled default config into a Claude config dir that has none yet
# (no settings.json). cp -rn never clobbers, so a seeded .credentials.json and
# any existing config survive. Applies to -i, default, and -c; -H's ~/.claude
# already has a settings.json so it's left untouched.
DEFAULT_CONFIG="$SCRIPT_DIR/claude-default-config"
if [ ! -e "$CONFIG_DIR/settings.json" ] && [ -d "$DEFAULT_CONFIG/claude" ]; then
  cp -rn "$DEFAULT_CONFIG/claude/." "$CONFIG_DIR/"
fi

# --edit: open the resolved (now-seeded) host config dir in an editor, then exit.
if [ "$EDIT" -eq 1 ]; then
  ED="${VISUAL:-${EDITOR:-}}"
  [ -z "$ED" ] && { command -v nvim >/dev/null 2>&1 && ED=nvim || ED=vi; }
  exec $ED "$CONFIG_DIR"
fi

# --mem-from / --mem-to: one-shot copy of the work-dir memory dir between the host
# Claude config and the resolved config dir, then exit (no container). Claude keys
# memory by cwd: the host slug is WORK_DIR with '/' and '.' collapsed to '-', and
# inside the container cwd is always /work -> slug '-work'. Memory dir only.
if [ "$MEM_FROM" -eq 1 ] || [ "$MEM_TO" -eq 1 ]; then
  HOST_SLUG="$(printf '%s' "$WORK_DIR" | sed 's/[/.]/-/g')"
  HOST_MEM="$HOME/.claude/projects/$HOST_SLUG/memory"
  CONF_MEM="$CONFIG_DIR/projects/-work/memory"
  if [ "$MEM_FROM" -eq 1 ]; then
    if [ -d "$HOST_MEM" ]; then
      mkdir -p "$CONF_MEM"
      cp -a "$HOST_MEM/." "$CONF_MEM/"
      echo "memory: copied host -> $CONF_MEM"
    else
      echo "memory: no host memory at $HOST_MEM (nothing to copy)"
    fi
  else
    if [ -d "$CONF_MEM" ]; then
      mkdir -p "$HOST_MEM"
      cp -a "$CONF_MEM/." "$HOST_MEM/"
      echo "memory: copied $CONF_MEM -> host ($HOST_MEM)"
    else
      echo "memory: no config memory at $CONF_MEM (nothing to copy)"
    fi
  fi
  exit 0
fi

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
      -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
      ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
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
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
  ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
  -w /work \
  "$IMAGE" "$@"
