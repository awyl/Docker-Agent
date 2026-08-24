#!/usr/bin/env bash
# Checks that all four runners resolve their store identically -- if they ever
# disagree, one project ends up with two stores. Sandboxed HOME in a temp dir;
# no container is started (`--edit` with VISUAL=echo prints the resolved path).
#
#   ./test/store-agents.sh
set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/docker-agent-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck(){ if [[ "$3" == *"$2"* ]]; then echo "    PASS  $1"; pass=$((pass+1))
      else echo "    FAIL  $1"; echo "          want ~ $2"; echo "          got    $3"; fail=$((fail+1)); fi; }

mkdir -p "$T/home"
for spec in "run-pi.sh:pi" "run-claude.sh:claude" "run-goose.sh:goose" "run-hermes.sh:hermes"; do
  prog="${spec%%:*}"; agent="${spec##*:}"
  echo "== $prog =="
  run(){ env HOME="$T/home" VISUAL=echo bash "$REPO/$prog" "$@" 2>&1; }

  P="$T/$agent-proj"; mkdir -p "$P"; git -C "$P" init -q
  git -C "$P" commit -q --allow-empty -m "init $agent-proj"
  ID=$(git -C "$P" rev-list --max-parents=0 HEAD|tail -1); ID=${ID:0:12}
  ck "creates <label>-<id>/$agent" ".docker-agent/$agent-proj-$ID/$agent" "$(run --edit -w "$P")"

  mv "$P" "$T/$agent-renamed"
  ck "survives rename"            ".docker-agent/$agent-proj-$ID/$agent" "$(run --edit -w "$T/$agent-renamed")"

  mkdir -p "$T/$agent-plain"
  out=$(run --edit -w "$T/$agent-plain"); rc=$?
  ck "non-git exits 1" "1" "$rc"
  ck "non-git reason"  "is not a git repository" "$out"

  mkdir -p "$T/$agent-empty"; git -C "$T/$agent-empty" init -q
  out=$(run --edit -w "$T/$agent-empty"); rc=$?
  ck "no-commit exits 1" "1" "$rc"
  ck "no-commit reason"  "has no commits yet" "$out"

  out=$(run --del nope -w "$T/$agent-renamed"); rc=$?
  ck "--del bogus exits 1" "1" "$rc"
  ck "--del bogus lists"   "$agent-proj-$ID" "$out"
done

echo
echo "passed $pass, failed $fail"
exit $((fail>0))
