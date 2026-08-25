# Container engine selection, shared by every runner and by build.sh.
#
# Supports docker and Apple's `container` CLI (macOS, one lightweight VM per
# container). `container` is a near drop-in for the subcommands used here; the
# three places it differs are handled below, once, so the runners cannot drift
# apart on them.

# Choose the engine: $ENGINE when set, else docker if it is on PATH, else
# Apple `container`. Sets $ENGINE. Returns 1 if neither is installed.
#   $1 calling script name (for the message)
engine_select() {
  [ -n "${ENGINE:-}" ] && return 0
  if command -v docker >/dev/null 2>&1; then
    ENGINE=docker
  elif command -v container >/dev/null 2>&1; then
    ENGINE=container
  else
    echo "$1: no container engine found (need docker, or Apple 'container')" >&2
    return 1
  fi
}

# Decide whether the container runs as root. Rootless Docker maps the host user
# to container root, so bind-mounted files appear owned by uid 0 and the
# non-root `dev` user cannot write them. Apple `container` shares host dirs over
# virtiofs, which exposes every bind mount as root:root whatever the host owner,
# so it needs the same treatment. Rootful Docker keeps the UID-matched `dev`
# user. Sets $USER_FLAG; respects an existing USER_FLAG=... override.
engine_user_flag() {
  [ -n "${USER_FLAG+x}" ] && return 0
  if [ "$ENGINE" = "container" ]; then
    USER_FLAG="--user 0:0"
  elif docker info 2>/dev/null | grep -q 'rootless: true'; then
    USER_FLAG="--user 0:0"
  else
    USER_FLAG=""
  fi
  return 0
}

# Extra `run` options for the chosen engine. Each Apple container is its own VM:
# the stock cpu/memory allocation sits well below what a Rust build wants, and
# --init supplies the reaper and signal forwarder that the agent's children
# (LSPs, npm, plugins) otherwise go without. Sets $ENGINE_RUN_OPTS.
engine_run_opts() {
  ENGINE_RUN_OPTS=()
  if [ "$ENGINE" = "container" ]; then
    ENGINE_RUN_OPTS=(--init -c "${AGENT_CPUS:-4}" -m "${AGENT_MEMORY:-8g}")
  fi
  return 0
}

# Container lookups. `container list` has no --filter, so the name is matched
# against its id list instead (--name sets the container id, so they are equal).
ctr_exists() {
  if [ "$ENGINE" = "container" ]; then
    container list -a -q | grep -qx "$1"
  else
    docker ps -aq -f "name=^$1$" | grep -q .
  fi
}

ctr_running() {
  if [ "$ENGINE" = "container" ]; then
    container list -q | grep -qx "$1"
  else
    docker ps -q -f "name=^$1$" | grep -q .
  fi
}

# How the chosen engine removes a running container, for printed instructions.
# docker spells it `rm -f`; Apple `container` spells it `delete --force`.
engine_rm() {
  if [ "$ENGINE" = "container" ]; then
    echo "container delete --force"
  else
    echo "docker rm -f"
  fi
}
