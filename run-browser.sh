#!/usr/bin/env bash
# Boot a browser-view container: headless labwc + wayvnc + noVNC, with Camoufox
# available inside. Watch it at http://localhost:PORT/vnc.html and drive it by
# exec'ing an agent into the same container.
#
# Usage:
#   run-browser.sh [-i | -H | -c CONFIG_DIR] [-n NAME] [-p PORT] [-w WORK_DIR]
#                  [-g GEOMETRY] [-I IMAGE]
#
#   (default)     Mount the same isolated per-project Hermes config run-hermes.sh
#                 uses (~/.docker-agent/<repo-name>-<root12>/hermes), so an agent
#                 exec'd into this container shares its login and plugin state.
#                 The work dir must be a git repo with at least one commit.
#   -i            Force the isolated config (this is the default; explicit form).
#   -H            Use the host config dir (~/.hermes) directly.
#   -c CONFIG_DIR Use a custom config dir. -i, -H and -c are mutually exclusive.
#   -n NAME       container name (default: hermes-view)
#   -p PORT       host port, published to 127.0.0.1 only (default: 8444)
#   -w WORK_DIR   codebase dir mounted at /work (default: current dir)
#   -g GEOMETRY   view size (default: 1280x800)
#   -I IMAGE      image to boot (default: agentic-hermes:latest)
#
# The config dir is mounted at /home/dev/.hermes and XDG data/config are pointed
# under it, matching run-hermes.sh. With a non-Hermes -I image, use -c (or expect
# an unused mount). The host sccache and cargo caches and your global git identity
# come along too, on the same terms as run-hermes.sh.
#
# To edit or delete the config this mounts, use run-hermes.sh --edit / --del: it
# resolves the same store, and there is one copy of that logic rather than two.
#
# There is no TLS and no password: the view is bound to 127.0.0.1 on the host
# and is not reachable from the LAN. Tunnel over SSH or Tailscale to view it
# remotely.
#
# Stop with the command printed on startup (docker rm -f NAME, or
# container delete --force NAME under Apple container).
set -euo pipefail

# Resolve this script's own dir (following symlinks) so we can find the shared
# library next to it.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [ "${SOURCE#/}" = "$SOURCE" ] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
# Shared store resolver: repo identity for the isolated config dir.
. "$SCRIPT_DIR/lib/store.sh"
. "$SCRIPT_DIR/lib/engine.sh"

ORIG_ARGS=("$@")
NAME="hermes-view"
PORT="${VIEW_PORT:-8444}"
WORK_DIR="$PWD"
GEOMETRY="${VIEW_GEOMETRY:-1280x800}"
IMAGE="${IMAGE:-agentic-hermes:latest}"
CONFIG_SRC="$HOME/.hermes"
CONFIG_DST="/home/dev/.hermes"
# Keep plugin state out of the container's ephemeral ~/.local/share and ~/.config
# by redirecting XDG under the mounted config dir. Same as run-hermes.sh.
XDG_DATA_DST="$CONFIG_DST/share"
XDG_CONFIG_DST="$CONFIG_DST/config"
ISOLATE=0
HOST=0
CONFIG_EXPLICIT=0

# Persistent sccache compile cache, shared with the host. Pin to the host default
# (~/.cache/sccache) unless SCCACHE_DIR is already exported. Created before the
# mount so Docker doesn't materialize a root-owned dir.
SCCACHE_CACHE="${SCCACHE_DIR:-$HOME/.cache/sccache}"
mkdir -p "$SCCACHE_CACHE"

# Cargo registry + git caches, shared with the host so agents inside the container
# can read crate source code (registry/src, git checkouts). Pin to the host default
# (~/.cargo) unless CARGO_HOME is exported. Created before the mount so Docker
# doesn't materialize root-owned dirs.
CARGO_HOST="${CARGO_HOME:-$HOME/.cargo}"
mkdir -p "$CARGO_HOST/git" "$CARGO_HOST/registry"

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

while getopts "c:iHn:p:w:g:I:h" opt; do
  case "$opt" in
    c) CONFIG_SRC="$OPTARG"; CONFIG_EXPLICIT=1 ;;
    i) ISOLATE=1 ;;
    H) HOST=1 ;;
    n) NAME="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    g) GEOMETRY="$OPTARG" ;;
    I) IMAGE="$OPTARG" ;;
    h) sed -n '2,/Stop with/p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

WORK_DIR="$(cd "$WORK_DIR" && pwd)"

# Isolated config is the default; -H (host) and -c (custom) opt out of it.
if [ $((ISOLATE + HOST + CONFIG_EXPLICIT)) -gt 1 ]; then
  echo "run-browser.sh: choose only one of -i, -H, -c" >&2
  exit 2
fi
if [ "$HOST" -eq 0 ] && [ "$CONFIG_EXPLICIT" -eq 0 ]; then
  ISOLATE=1
fi

if [ "$ISOLATE" -eq 1 ]; then
  # Same store run-hermes.sh resolves, so the view and the CLI share one config:
  # ~/.docker-agent/<repo-name>-<root12>/hermes, keyed to the repo's root commit.
  _id="$(store_repo_id "$WORK_DIR" run-browser.sh)" || exit 1
  CONFIG_SRC="$(store_dir_for "$_id" "$(store_label "$WORK_DIR")")/hermes"
fi

# Created before the mount so the engine doesn't materialize a root-owned dir.
mkdir -p "$CONFIG_SRC"; CONFIG_SRC="$(cd "$CONFIG_SRC" && pwd)"

# Same mount set run-hermes.sh gives the agent, so a shell exec'd into this
# container behaves identically to one started by run-hermes.sh.
MOUNTS=(
  -v "$CONFIG_SRC":"$CONFIG_DST"
  -v "$WORK_DIR":/work
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache
  -v "$CARGO_HOST/git":/home/dev/.cargo/git
  -v "$CARGO_HOST/registry":/home/dev/.cargo/registry
)

engine_select run-browser.sh || exit 1
engine_user_flag
engine_run_opts

if ctr_exists "$NAME"; then
  ctr_running "$NAME" || "$ENGINE" start "$NAME" >/dev/null
  # Mounts are fixed at creation, so a container made before the config mount
  # existed (or with a different -c) silently keeps its old one. Say so rather
  # than let an agent log in to a dir that goes away with the container.
  if ! "$ENGINE" exec "$NAME" \
      grep -q " $CONFIG_DST " /proc/self/mountinfo 2>/dev/null; then
    echo "run-browser.sh: '$NAME' already exists and has no $CONFIG_DST mount." >&2
    echo "  Config written inside it will not persist. Recreate it with:" >&2
    echo "    $(engine_rm) $NAME && $0${ORIG_ARGS[*]:+ ${ORIG_ARGS[*]}}" >&2
  fi
else
  # A failed `run` (missing image, no with-view in it) would otherwise abort
  # under `set -e` with only the runtime's own message.
  if ! "$ENGINE" run -d --name "$NAME" $USER_FLAG \
      ${ENGINE_RUN_OPTS[@]+"${ENGINE_RUN_OPTS[@]}"} \
      -e "VIEW_PORT=8444" -e "VIEW_GEOMETRY=$GEOMETRY" \
      -e "XDG_DATA_HOME=$XDG_DATA_DST" \
      -e "XDG_CONFIG_HOME=$XDG_CONFIG_DST" \
      -p "127.0.0.1:${PORT}:8444" \
      "${MOUNTS[@]}" ${GIT_ENV[@]+"${GIT_ENV[@]}"} \
      -w /work --entrypoint with-view \
      "$IMAGE" >/dev/null; then
    echo "run-browser.sh: could not start '$NAME' from image '$IMAGE'" >&2
    echo "  the image must provide the with-view entrypoint (build it with build.sh)" >&2
    exit 1
  fi
fi

# The three services are launched by labwc's autostart, so the port appears a
# moment after the container does. Poll rather than guess.
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/vnc.html" 2>/dev/null; then
    ok=1; break
  fi
  sleep 1
done

if [ "${ok:-0}" -ne 1 ]; then
  echo "run-browser.sh: view did not come up on 127.0.0.1:${PORT}" >&2
  echo "  check: $ENGINE logs $NAME" >&2
  exit 1
fi

cat <<EOF
Browser view up (container '$NAME', ${GEOMETRY}).
  Watch:  http://localhost:${PORT}/vnc.html?autoconnect=true&resize=remote
  Drive:  $ENGINE exec -it $USER_FLAG -w /work $NAME hermes
  Browse: $ENGINE exec -it $USER_FLAG $NAME camoufox-open https://example.com
  Stop:   $(engine_rm) $NAME
EOF
