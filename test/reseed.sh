#!/usr/bin/env bash
# Checks run-claude.sh --reseed: the bundled settings replace the old ones,
# plugins the defaults drop are pinned off, claude.json keeps login/project state
# but takes the default keys, and credentials/memory are untouched. Sandboxed
# HOME; the engine is stubbed so no container starts.
#
#   ./test/reseed.sh
set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/docker-agent-reseed.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck(){ if [[ "$3" == *"$2"* ]]; then echo "    PASS  $1"; pass=$((pass+1))
      else echo "    FAIL  $1"; echo "          want ~ $2"; echo "          got    $3"; fail=$((fail+1)); fi; }

mkdir -p "$T/home" "$T/stub"
printf '#!/usr/bin/env bash\ncase "$1" in info) echo "rootless: false" ;; esac\n' > "$T/stub/docker"
chmod +x "$T/stub/docker"
run(){ env HOME="$T/home" PATH="$T/stub:$PATH" ENGINE=docker bash "$REPO/run-claude.sh" "$@" 2>&1; }

P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q; git -C "$P" commit -q --allow-empty -m init
ID=$(git -C "$P" rev-list --max-parents=0 HEAD | tail -1); ID=${ID:0:12}
C="$T/home/.docker-agent/proj-$ID/claude"

# An existing store with stale settings, a plugin the defaults no longer enable,
# an old MCP server, and state that must survive.
mkdir -p "$C/plugins" "$C/projects/-work/memory"
echo '{"model":"sonnet","enabledPlugins":{"context-mode@context-mode":true}}' > "$C/settings.json"
echo '{"plugins":{"context-mode@context-mode":[]}}' > "$C/plugins/installed_plugins.json"
echo '{"oauthAccount":{"a":1},"projects":{"/work":{}},"mcpServers":{"semble":{}}}' > "$C.json"
echo secret > "$C/.credentials.json"
echo note > "$C/projects/-work/memory/m.md"

echo "== --reseed =="
out=$(run --reseed -w "$P"); rc=$?
ck "exits 0" "0" "$rc"
ck "reports" "reseeded $C" "$out"
ck "settings match defaults" "True" "$(python3 -c 'import json, sys
s = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
s["enabledPlugins"] = {k: v for k, v in s["enabledPlugins"].items() if k in d["enabledPlugins"]}
print(s == d)' "$C/settings.json" "$REPO/claude-default-config/claude/settings.json")"
ck "dropped plugin pinned off" "False" "$(python3 -c 'import json, sys
print(json.load(open(sys.argv[1]))["enabledPlugins"]["context-mode@context-mode"])' "$C/settings.json")"
ck "bundled flag copied" "yes" "$([ -e "$C/.i-have-adhd-always" ] && echo yes)"
ck "claude.json keeps state, takes defaults" "True True True" "$(python3 -c 'import json, sys
j = json.load(open(sys.argv[1])); d = json.load(open(sys.argv[2]))
print("oauthAccount" in j, "projects" in j, all(j[k] == v for k, v in d.items()))' "$C.json" "$REPO/claude-default-config/claude.json")"
ck "credentials untouched" "secret" "$(cat "$C/.credentials.json")"
ck "memory untouched" "note" "$(cat "$C/projects/-work/memory/m.md")"
ck "old settings backed up" "sonnet" "$(cat "$C/settings.json.bak")"
ck "old claude.json backed up" "semble" "$(cat "$C/claude.json.bak")"

echo "== refusals =="
out=$(run --reseed -H -w "$P"); rc=$?
ck "-H exits 2" "2" "$rc"
ck "-H reason" "not valid with -H" "$out"
out=$(run --reseed --edit -w "$P"); rc=$?
ck "--edit combo exits 2" "2" "$rc"

echo
echo "passed $pass, failed $fail"
exit $((fail>0))
