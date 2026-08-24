#!/usr/bin/env bash
# Tests for the store resolver in lib/store.sh, driven through run-pi.sh.
#
# Every case runs against a sandboxed HOME in a temp dir, so it never touches
# your real ~/.docker-agent. No container is ever started: `--edit` with
# VISUAL=echo makes the runner print the store path it resolved and exit.
#
#   ./test/store.sh
set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/docker-agent-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck() { # ck <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1"; echo "        want ~ $2"; echo "        got    $3"; fail=$((fail+1)); fi
}
mkrepo() { mkdir -p "$1"; git -C "$1" init -q
           git -C "$1" commit -q --allow-empty -m "init $(basename "$1")"; }
run() { env HOME="$T/home" VISUAL=echo bash "$REPO/run-pi.sh" "$@" 2>&1; }

mkdir -p "$T/home"

echo "1. fresh repo creates <label>-<id> store"
mkrepo "$T/mathhead"
ID=$(git -C "$T/mathhead" rev-list --max-parents=0 HEAD | tail -1); ID=${ID:0:12}
ck "store name" "/.docker-agent/mathhead-$ID/pi" "$(run --edit -w "$T/mathhead")"

echo "2. rename the folder -> same store, stale label"
mv "$T/mathhead" "$T/math-solver"
out=$(run --edit -w "$T/math-solver")
ck "after rename" "/.docker-agent/mathhead-$ID/pi" "$out"
ck "notes the rename" "created for 'mathhead', now 'math-solver'" "$out"
ck "notes only once" "NO" "$(r2=$(run --edit -w "$T/math-solver"); [[ "$r2" == *"created for"* ]] && echo YES || echo NO)"

echo "3. move to another parent -> same store"
mkdir -p "$T/deep"; mv "$T/math-solver" "$T/deep/renamed-again"
ck "after move" "/.docker-agent/mathhead-$ID/pi" "$(run --edit -w "$T/deep/renamed-again")"

echo "4. subdirectory of the repo -> repo's store, repo's label"
mkdir -p "$T/deep/renamed-again/src"
ck "from subdir" "/.docker-agent/mathhead-$ID/pi" "$(run --edit -w "$T/deep/renamed-again/src")"

echo "5. legacy folder-name store is adopted once"
mkrepo "$T/legacyproj"
LID=$(git -C "$T/legacyproj" rev-list --max-parents=0 HEAD | tail -1); LID=${LID:0:12}
mkdir -p "$T/home/.docker-agent/legacyproj/pi"; echo marker > "$T/home/.docker-agent/legacyproj/pi/KEEP"
ck "adopted path" "/.docker-agent/legacyproj-$LID/pi" "$(run --edit -w "$T/legacyproj")"
ck "contents kept" "marker" "$(cat "$T/home/.docker-agent/legacyproj-$LID/pi/KEEP" 2>&1)"
ck "old dir gone" "NO" "$([ -e "$T/home/.docker-agent/legacyproj" ] && echo YES || echo NO)"

echo "6. non-git dir fails with instructions"
mkdir -p "$T/plain"
out=$(run --edit -w "$T/plain"); rc=$?
ck "exit 1" "1" "$rc"
ck "reason" "is not a git repository" "$out"
ck "instruction" "init && git -C" "$out"

echo "7. repo with no commits fails with its own instruction"
mkdir -p "$T/empty"; git -C "$T/empty" init -q
out=$(run --edit -w "$T/empty"); rc=$?
ck "exit 1" "1" "$rc"
ck "reason" "has no commits yet" "$out"
ck "instruction" "commit --allow-empty" "$out"

echo "8. --del STORE works with the repo deleted"
rm -rf "$T/legacyproj"
out=$(printf 'legacyproj-%s\n' "$LID" | run --del "legacyproj-$LID" -w "$T/deep/renamed-again"); rc=$?
ck "exit 0" "0" "$rc"
ck "deleted" "deleted" "$out"
ck "gone from disk" "NO" "$([ -e "$T/home/.docker-agent/legacyproj-$LID" ] && echo YES || echo NO)"

echo "9. --del with a bogus name lists the known stores"
out=$(run --del nosuchstore -w "$T/deep/renamed-again"); rc=$?
ck "exit 1" "1" "$rc"
ck "names it" "no store named 'nosuchstore'" "$out"
ck "lists stores" "mathhead-$ID" "$out"

# Identical author, message, tree and timestamp produce byte-identical commit
# objects, so two unrelated repos can share a root commit -- easy to hit with a
# scripted `git commit --allow-empty`. The store is shared; the point is that
# the runner says so instead of silently merging two projects' config.
echo "10. two repos sharing a root commit are surfaced, not silently merged"
export GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00"
mkdir -p "$T/twinA" "$T/twinB"
for d in "$T/twinA" "$T/twinB"; do git -C "$d" init -q; git -C "$d" commit -q --allow-empty -m same; done
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
TA=$(git -C "$T/twinA" rev-list --max-parents=0 HEAD|tail -1)
TB=$(git -C "$T/twinB" rev-list --max-parents=0 HEAD|tail -1)
ck "roots really collide" "$TA" "$TB"
run --edit -w "$T/twinA" >/dev/null
out=$(run --edit -w "$T/twinB")
ck "second repo warned" "created for 'twinA', now 'twinB'" "$out"

echo
echo "passed $pass, failed $fail"
exit $((fail > 0))
