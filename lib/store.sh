# Shared helpers for locating a project's isolated config store.
#
# The store is keyed to the repository's ROOT COMMIT rather than the folder
# name, so renaming or moving a checkout still finds the same store:
#
#   ~/.docker-agent/<repo-name>-<root12>/<agent>
#
# The <repo-name> prefix is a human label fixed when the store is created.
# Lookup globs on the -<root12> suffix alone and never reads the prefix, so a
# stale label after a rename costs nothing.
#
# Sourced by every run-*.sh: the identity and migration rules have to agree
# across agents, or one project ends up with two stores.

DOCKER_AGENT_HOME="${DOCKER_AGENT_HOME:-$HOME/.docker-agent}"

# Print a work dir's repo identity (first 12 chars of the root commit).
# Returns 1 with an instruction on stderr if the dir cannot supply one.
#   $1 work dir   $2 calling script name (for the message)
store_repo_id() {
  local wd="$1" prog="$2" root
  if ! git -C "$wd" rev-parse --show-toplevel >/dev/null 2>&1; then
    cat >&2 <<MSG
$prog: $wd is not a git repository.

The isolated config store is keyed to the repository's root commit, so it keeps
working when you rename or move the checkout. Give the directory a repo:

    git -C "$wd" init && git -C "$wd" commit --allow-empty -m "init $(basename "$wd")"
MSG
    return 1
  fi
  root="$(git -C "$wd" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)"
  if [ -z "$root" ]; then
    cat >&2 <<MSG
$prog: $wd is a git repository but has no commits yet.

The isolated config store is keyed to the repository's root commit, which does
not exist until the first commit. Make one:

    git -C "$wd" commit --allow-empty -m "init $(basename "$wd")"
MSG
    return 1
  fi
  printf '%s\n' "${root:0:12}"
}

# Print the human label for a work dir's store: the basename of the REPO ROOT,
# not of the work dir. Running in a subdirectory shares the repo's one store,
# so the label should name the repo.
#   $1 work dir
store_label() {
  basename "$(git -C "$1" rev-parse --show-toplevel)"
}

# Print the store dir for an identity, adopting a store created under the old
# folder-name scheme the first time it is seen. Creates nothing otherwise.
#   $1 identity   $2 label
store_dir_for() {
  local id="$1" label="$2" d legacy
  local hits=()

  # Match on the identity suffix only, so the label is free to be stale. Glob
  # expansion is sorted, so a (never expected) tie resolves the same way twice.
  for d in "$DOCKER_AGENT_HOME"/*-"$id"; do
    [ -d "$d" ] && hits+=("$d")
  done
  if [ "${#hits[@]}" -gt 1 ]; then
    echo "warning: ${#hits[@]} stores match -$id; using ${hits[0]}" >&2
  fi
  if [ "${#hits[@]}" -ge 1 ]; then
    store_note_label "${hits[0]}" "$label"
    printf '%s\n' "${hits[0]}"
    return 0
  fi

  # One-time adoption of a pre-identity store named after the folder.
  legacy="$DOCKER_AGENT_HOME/$label"
  if [ -d "$legacy" ]; then
    mv "$legacy" "$DOCKER_AGENT_HOME/$label-$id"
  fi
  mkdir -p "$DOCKER_AGENT_HOME/$label-$id"
  printf '%s\n' "$label" > "$DOCKER_AGENT_HOME/$label-$id/.label"
  printf '%s\n' "$DOCKER_AGENT_HOME/$label-$id"
}

# Say something the first time a store is reached under a different label than
# the one it was created with. A rename is the benign cause and this confirms
# it; the other cause is two repos sharing a root commit, which is worth
# seeing rather than silently sharing one config.
store_note_label() {
  local dir="$1" label="$2" was=""
  [ -f "$dir/.label" ] && was="$(cat "$dir/.label")"
  if [ "$was" != "$label" ]; then
    [ -n "$was" ] && echo "note: reusing store $(basename "$dir") (created for '$was', now '$label')" >&2
    printf '%s\n' "$label" > "$dir/.label"
  fi
}

# List the store directory names, one per line, for error messages.
store_list() {
  local d found=0
  echo "Known stores in $DOCKER_AGENT_HOME:"
  for d in "$DOCKER_AGENT_HOME"/*/; do
    [ -d "$d" ] || continue
    echo "  $(basename "$d")"
    found=1
  done
  [ "$found" -eq 1 ] || echo "  (none)"
}

# Print a store dir looked up by its directory name, for `--del NAME` when the
# repository is gone. Returns 1 and lists the known stores if there is no match.
#   $1 store name   $2 calling script name
store_by_name() {
  local name="$1" prog="$2"
  if [ -d "$DOCKER_AGENT_HOME/$name" ]; then
    printf '%s\n' "$DOCKER_AGENT_HOME/$name"
    return 0
  fi
  echo "$prog: no store named '$name'" >&2
  store_list >&2
  return 1
}

# Remove a store directory once no agent config is left in it. The .label
# bookkeeping file does not count as content, so --del still prunes the parent.
store_prune() {
  local dir="$1" entry
  [ -d "$dir" ] || return 0
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ "$(basename "$entry")" = ".label" ] && continue
    return 0
  done
  rm -rf "$dir"
}
