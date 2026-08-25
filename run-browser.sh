#!/usr/bin/env bash
# Boot a browser-view container: headless labwc + wayvnc + noVNC, with Camoufox
# available inside. Watch it at http://localhost:PORT/vnc.html and drive it by
# exec'ing an agent into the same container.
#
# Usage:
#   run-browser.sh [-n NAME] [-p PORT] [-w WORK_DIR] [-g GEOMETRY] [-I IMAGE]
#
#   -n NAME       container name (default: hermes-view)
#   -p PORT       host port, published to 127.0.0.1 only (default: 8444)
#   -w WORK_DIR   codebase dir mounted at /work (default: current dir)
#   -g GEOMETRY   view size (default: 1280x800)
#   -I IMAGE      image to boot (default: agentic-hermes:latest)
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
. "$SCRIPT_DIR/lib/engine.sh"

NAME="hermes-view"
PORT="${VIEW_PORT:-8444}"
WORK_DIR="$PWD"
GEOMETRY="${VIEW_GEOMETRY:-1280x800}"
IMAGE="${IMAGE:-agentic-hermes:latest}"

while getopts "n:p:w:g:I:h" opt; do
  case "$opt" in
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

engine_select run-browser.sh || exit 1
engine_user_flag
engine_run_opts

if ctr_exists "$NAME"; then
  ctr_running "$NAME" || "$ENGINE" start "$NAME" >/dev/null
else
  # A failed `run` (missing image, no with-view in it) would otherwise abort
  # under `set -e` with only the runtime's own message.
  if ! "$ENGINE" run -d --name "$NAME" $USER_FLAG \
      ${ENGINE_RUN_OPTS[@]+"${ENGINE_RUN_OPTS[@]}"} \
      -e "VIEW_PORT=8444" -e "VIEW_GEOMETRY=$GEOMETRY" \
      -p "127.0.0.1:${PORT}:8444" \
      -v "$WORK_DIR":/work \
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
