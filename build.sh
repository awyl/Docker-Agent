#!/usr/bin/env bash
# Build the Docker images for the agent runners.
#
# Builds the shared base image first, then each agent image FROM it. UID/GID
# build-args match the invoking user so files written in the container are
# owned correctly on the host.
#
#   agentic-dev-base:latest   (Dockerfile)        <- shared base, built first
#   agentic-claude:latest     (Dockerfile.claude)
#   agentic-goose:latest      (Dockerfile.goose)
#   agentic-hermes:latest     (Dockerfile.hermes)
#   agentic-pi:latest         (Dockerfile.pi)
#
# Usage:
#   ./build.sh                 # build base + all agents (all cached)
#   ./build.sh claude pi       # cached base + force-rebuild named agent layers
#   ./build.sh --no-cache      # forward flags to docker build (e.g. --no-cache)
#   ./build.sh --base-only     # force-rebuild only the base image
#
# Naming specific agents force-rebuilds only those agent layers (--no-cache on
# the agent build); the shared base stays on cache. Passing your own docker
# flags disables this auto --no-cache.
#
# Env:
#   UID, GID      override the uid/gid baked in (default: current user)
#   HERMES_REF    git ref for the hermes build (default: main)
set -euo pipefail

# Resolve symlinks so the build context is the repo, not the install dir
# (this script is symlinked onto PATH as `agent-build`).
self="$0"
while [ -L "$self" ]; do
  link="$(readlink "$self")"
  case "$link" in
    /*) self="$link" ;;
    *)  self="$(dirname "$self")/$link" ;;
  esac
done
SRC="$(cd "$(dirname "$self")" && pwd)"
cd "$SRC"

UID_ARG="${UID:-$(id -u)}"
GID_ARG="${GID:-$(id -g)}"
HERMES_REF="${HERMES_REF:-main}"

# agent name -> dockerfile : image
agents=(
  "claude:Dockerfile.claude:agentic-claude:latest"
  "goose:Dockerfile.goose:agentic-goose:latest"
  "hermes:Dockerfile.hermes:agentic-hermes:latest"
  "pi:Dockerfile.pi:agentic-pi:latest"
)

base_only=0
docker_flags=()
selected=()

for arg in "$@"; do
  case "$arg" in
    --base-only) base_only=1 ;;
    -*)          docker_flags+=("$arg") ;;
    *)           selected+=("$arg") ;;
  esac
done

# No agent names given -> build them all (and let the base layer cache too).
# When specific agents are named, force-rebuild just those agent layers while
# leaving the shared base on cache.
explicit=1
if [ "${#selected[@]}" -eq 0 ]; then
  explicit=0
  for entry in "${agents[@]}"; do
    selected+=("${entry%%:*}")
  done
fi

# Per-agent flags: force a rebuild of the agent layer when a name was given
# explicitly, unless the caller already passed their own cache flags.
agent_flags=()
if [ "$explicit" -eq 1 ] && [ "${#docker_flags[@]}" -eq 0 ]; then
  agent_flags+=(--no-cache)
fi

# Validate requested agent names before building anything.
known() {
  for entry in "${agents[@]}"; do
    [ "${entry%%:*}" = "$1" ] && return 0
  done
  return 1
}
if [ "$base_only" -eq 0 ]; then
  for name in "${selected[@]}"; do
    if ! known "$name"; then
      echo "ERROR: unknown agent '$name' (known: claude goose hermes pi)" >&2
      exit 1
    fi
  done
fi

# Force a rebuild of just the base when --base-only is requested explicitly,
# unless the caller already passed their own cache flags.
base_flags=()
if [ "$base_only" -eq 1 ] && [ "${#docker_flags[@]}" -eq 0 ]; then
  base_flags+=(--no-cache)
fi

echo "==> Building agentic-dev-base:latest"
docker build "${docker_flags[@]}" "${base_flags[@]}" -t agentic-dev-base:latest .

if [ "$base_only" -eq 1 ]; then
  echo "==> Done (base only)."
  exit 0
fi

for name in "${selected[@]}"; do
  for entry in "${agents[@]}"; do
    [ "${entry%%:*}" = "$name" ] || continue
    rest="${entry#*:}"
    dockerfile="${rest%%:*}"
    image="${rest#*:}"

    extra=()
    [ "$name" = "hermes" ] && extra+=(--build-arg "HERMES_REF=$HERMES_REF")

    echo "==> Building $image  ($dockerfile)"
    docker build "${docker_flags[@]}" "${agent_flags[@]}" -f "$dockerfile" \
      --build-arg "UID=$UID_ARG" --build-arg "GID=$GID_ARG" \
      "${extra[@]}" \
      -t "$image" .
  done
done

echo "==> Done."
