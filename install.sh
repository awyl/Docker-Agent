#!/usr/bin/env bash
# Install the agent runner scripts onto PATH as symlinks.
#
# Symlinks each run-*.sh into ~/.local/bin (override with BIN=...), so the
# commands work from any directory and stay in sync with the repo.
#
#   run-claude.sh -> agent-claude
#   run-pi.sh     -> agent-pi
#   run-goose.sh  -> agent-goose
#   run-hermes.sh -> agent-hermes
#
# Usage:
#   ./install.sh            # symlink into ~/.local/bin
#   BIN=~/bin ./install.sh  # symlink into a different dir
#
# Note: this does not build the Docker images. The commands only work once
# `agentic-*:latest` exists (see "Build" in README.md).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"

# run-script -> installed command name
links=(
  "run-claude.sh:agent-claude"
  "run-pi.sh:agent-pi"
  "run-goose.sh:agent-goose"
  "run-hermes.sh:agent-hermes"
)

installed=()
for entry in "${links[@]}"; do
  script="${entry%%:*}"
  cmd="${entry##*:}"
  chmod +x "$SRC/$script"
  ln -sfn "$SRC/$script" "$BIN/$cmd"
  installed+=("$cmd")
done

echo "Installed into $BIN:"
for cmd in "${installed[@]}"; do
  echo "  $cmd -> $(readlink "$BIN/$cmd")"
done

# Warn if BIN is not on PATH.
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    echo
    echo "WARNING: $BIN is not on your PATH. Add it:"
    echo "  fish:  fish_add_path $BIN"
    echo "  bash:  export PATH=\"$BIN:\$PATH\"   # add to ~/.bashrc"
    ;;
esac
