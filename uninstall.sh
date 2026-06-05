#!/usr/bin/env bash
# Remove the agent runner symlinks created by install.sh.
#
# Only removes a link if it points back into this repo, so it never deletes
# an unrelated command of the same name.
#
# Usage:
#   ./uninstall.sh
#   BIN=~/bin ./uninstall.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HOME/.local/bin}"

cmds=(agent-claude agent-pi agent-goose)

for cmd in "${cmds[@]}"; do
  link="$BIN/$cmd"
  [ -L "$link" ] || continue
  target="$(readlink "$link")"
  case "$target" in
    "$SRC/"*) rm -f "$link"; echo "Removed $link" ;;
    *) echo "Skipped $link (points to $target, not this repo)" ;;
  esac
done
