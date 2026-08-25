#!/usr/bin/env bash
# Tests for the engine shim in lib/engine.sh: every runner has to build the same
# command shape for docker and for Apple `container`, and must not regress the
# docker path while gaining the container one.
#
# Both engines are stubbed by a script on PATH that echoes its argv, so nothing
# is ever built or run. HOME is sandboxed to a temp dir.
#
#   ./test/engine.sh
set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/docker-agent-engine.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck(){ if [[ "$3" == *"$2"* ]]; then echo "    PASS  $1"; pass=$((pass+1))
      else echo "    FAIL  $1"; echo "          want ~ $2"; echo "          got    $3"; fail=$((fail+1)); fi; }
nk(){ if [[ "$3" != *"$2"* ]]; then echo "    PASS  $1"; pass=$((pass+1))
      else echo "    FAIL  $1"; echo "          must NOT contain $2"; echo "          got    $3"; fail=$((fail+1)); fi; }

mkdir -p "$T/home" "$T/stub"
for e in docker container; do
  cat > "$T/stub/$e" <<EOF
#!/usr/bin/env bash
echo "CALL: $e \$*" >&2
case "\$1" in list|ps) exit 0 ;; info) echo "rootless: false" ;; esac
EOF
  chmod +x "$T/stub/$e"
done
# run-browser.sh polls the view with curl; stub it so the happy path completes.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/curl"; chmod +x "$T/stub/curl"

P="$T/proj"; mkdir -p "$P"; git -C "$P" init -q; git -C "$P" commit -q --allow-empty -m "init proj"
run(){ local eng="$1" prog="$2"; shift 2
       env HOME="$T/home" PATH="$T/stub:$PATH" ENGINE="$eng" bash "$REPO/$prog" "$@" 2>&1; }

for prog in run-pi.sh run-claude.sh run-goose.sh run-hermes.sh; do
  echo "== $prog =="
  out=$(run container "$prog" -w "$P")
  ck "container: run --rm -it" "container run --rm -it" "$out"
  ck "container: runs as root" "--user 0:0"             "$out"
  ck "container: --init"       "--init"                 "$out"
  ck "container: VM sizing"    "-c 4 -m 8g"             "$out"

  out=$(run docker "$prog" -w "$P")
  ck "docker: run --rm -it"    "docker run --rm -it"    "$out"
  nk "docker: no root flag"    "--user 0:0"             "$out"
  nk "docker: no --init"       "--init"                 "$out"
  nk "docker: no VM sizing"    "-c 4 -m 8g"             "$out"

  out=$(run container "$prog" -w "$P" -n box)
  ck "container: name probe"   "container list -a -q"   "$out"
  ck "container: creates"      "container run -d --name box" "$out"
  ck "container: execs in"     "container exec -it"     "$out"

  out=$(run docker "$prog" -w "$P" -n box)
  ck "docker: name probe"      "docker ps -aq -f name=^box$" "$out"
  ck "docker: creates"         "docker run -d --name box"    "$out"
  ck "docker: execs in"        "docker exec -it"             "$out"
done

echo "== run-browser.sh =="
out=$(run container run-browser.sh -w "$P" -n view)
ck "container: creates view"  "container run -d --name view" "$out"
ck "container: publishes"     "-p 127.0.0.1:8444:8444"       "$out"
ck "container: stop wording"  "container delete --force"     "$out"
nk "container: no docker rm"  "docker rm -f"                 "$out"
out=$(run docker run-browser.sh -w "$P" -n view2)
ck "docker: creates view"     "docker run -d --name view2"   "$out"
ck "docker: stop wording"     "docker rm -f"                 "$out"

echo "== build.sh =="
out=$(env PATH="$T/stub:$PATH" ENGINE=container bash "$REPO/build.sh" pi 2>&1)
ck "container: builds base"   "container build -t agentic-dev-base:latest" "$out"
ck "container: builds agent"  "container build --no-cache -f Dockerfile.pi" "$out"
out=$(env PATH="$T/stub:$PATH" ENGINE=docker bash "$REPO/build.sh" pi 2>&1)
ck "docker: builds base"      "docker build -t agentic-dev-base:latest"    "$out"

echo; echo "passed $pass, failed $fail"; exit $((fail>0))
