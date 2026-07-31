# Wayland Browser View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace KasmVNC in `agentic-browser-base` with labwc (headless Wayland) + wayvnc + noVNC served by websockify, and move the browser view out of `run-hermes.sh` into a standalone `run-browser.sh`.

**Architecture:** The view container's PID1 is labwc itself. A thin `with-view` entrypoint exports the Wayland runtime environment and `exec labwc -C /etc/labwc`; labwc's native `autostart` then launches `wlr-randr`, `wayvnc`, and `websockify` — which runs *after* the compositor is up, eliminating the wait-for-socket polling that caused the earlier launch bugs. `wayvnc` binds container-localhost; only websockify's port is published, mapped to `127.0.0.1` on the host.

**Tech Stack:** Debian trixie main packages (`labwc 0.8.3`, `wayvnc 0.9.1`, `novnc 1.6.0`, `websockify 0.12.0`, `wlr-randr`, `wl-clipboard`); bash launchers; Docker.

**Spec:** `docs/superpowers/specs/2026-07-31-wayland-labwc-novnc-design.md`

**Branch:** `feat/wayland-view` (already checked out; spec commit `cb626ac` lives here).

**Note on "tests":** This is Dockerfile and launcher work — there is no unit test framework. Verification is `bash -n` plus **deterministic runtime checks against a real container**, matching the convention used in prior plans in this repo. Every task below states the exact command and the exact expected output.

## Global Constraints

- **Debian trixie main only.** No third-party apt repos, no GitHub release downloads, no compilation. Exact verified versions: `labwc 0.8.3-1`, `wayvnc 0.9.1-1`, `novnc 1:1.6.0-2`, `websockify 0.12.0+dfsg1-4+b1`.
- **No TLS, no auth.** `wayvnc` binds `127.0.0.1` inside the container; the host publish is `-p 127.0.0.1:PORT:8444`. Never bind or publish to `0.0.0.0` on the host.
- **PID1 is labwc.** The entrypoint ends in `exec labwc`. No supervisor, no `sleep infinity`.
- **Native Wayland, no Xwayland.** No X server packages. `MOZ_ENABLE_WAYLAND=1`.
- **`COPY browser/*` stays last** in `Dockerfile.browser`, after the `camoufox fetch` layer, so editing a script does not invalidate the ~700MB download.
- **labwc config lives in `/etc/labwc`,** never `$HOME/.config/labwc` — `$HOME` is `/home/dev`, whose subdirectories are runtime bind-mounts.
- **Fixed `XDG_RUNTIME_DIR=/tmp/xdg`,** not `/run/user/$(id -u)`. The UID differs between the rootful `dev` path and the rootless `--user 0:0` path, and a fixed path can live in image `ENV` so `docker exec` inherits it.
- Keep the GTK/NSS/ALSA/font packages. Firefox needs them on Wayland too; only X *server* packages go.

---

## File Structure

- `Dockerfile.browser` — browser layer. Package block (lines 29-58) and `ENV DISPLAY=:1` (line 100) change. Everything else — camoufox venv, `dev` user creation, `camoufox fetch`, COPY-last ordering — stays.
- `browser/with-view` — **new.** Entrypoint: export Wayland env, create runtime dir, `exec labwc`. Replaces `browser/with-vnc` (deleted).
- `browser/labwc-autostart` — **new.** Installed to `/etc/labwc/autostart`. Launches the three services.
- `browser/labwc-rc.xml` — **new.** Installed to `/etc/labwc/rc.xml`. Minimal compositor config.
- `browser/camoufox-open` — modify. Comments and the printed line reference `DISPLAY`/KasmVNC; both become Wayland.
- `run-browser.sh` — **new.** Standalone launcher for the view container.
- `run-hermes.sh` — modify. Delete the `-b` machinery: usage lines 20-25 and 34-35, `BROWSER`/`VNC_PORT` vars (54-55), the `_b_seen` parse logic (99-119), and the entire browser block (197-236).
- `Dockerfile.hermes` — modify. `ENTRYPOINT` (line 57) and the header comment (13-16).
- `README.md` — modify. Sections at lines 6, 82-106, 142, 162, 252-260.
- `build.sh` — modify. Comment-only, lines 9 and 111-113.

Task order front-loads the one real risk: Task 1 proves Camoufox runs on native Wayland before any launcher is touched.

---

### Task 1: Swap the browser layer to Wayland packages, and prove Camoufox runs on it

This task carries the project's only unverified assumption. If Camoufox will not run on native Wayland, we find out here, before anything else is built on top.

**Files:**
- Modify: `Dockerfile.browser:29-58` (package block), `Dockerfile.browser:96-100` (trailing ENV)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: image `agentic-browser-base:latest` containing `labwc`, `wayvnc`, `websockify`, `wlr-randr`, `wl-clipboard`, `/usr/share/novnc/vnc.html`, and env `WAYLAND_DISPLAY=wayland-0`, `XDG_RUNTIME_DIR=/tmp/xdg`, `MOZ_ENABLE_WAYLAND=1`. No `DISPLAY`, no `kasmvncserver`.

- [ ] **Step 1: Replace the package block**

Replace `Dockerfile.browser` lines 29-58 (the `RUN` that installs KasmVNC and the X stack, including the `TARGETARCH` case statement) with:

```dockerfile
# --- Wayland view stack + Firefox/Camoufox runtime libs, one layer ---
# Everything here is Debian trixie main: no third-party repo, no compilation.
#   labwc      wlroots compositor, runs headless (WLR_BACKENDS=headless)
#   wayvnc     RFB server that attaches to labwc via wlr-screencopy
#   novnc      browser client, served as static files from /usr/share/novnc
#   websockify serves those files and proxies WebSocket -> wayvnc's TCP port
# t64 suffixes (libasound2t64, libgtk-3-0t64) are the Debian trixie time64 names.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        labwc wayvnc novnc websockify wlr-randr wl-clipboard \
        dbus \
        libgl1-mesa-dri \
        libgtk-3-0t64 libx11-xcb1 libasound2t64 libdbus-glib-1-2 \
        libgdk-pixbuf-2.0-0 libpangocairo-1.0-0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libxkbcommon0 libatk1.0-0t64 libatk-bridge2.0-0t64 \
        libcups2t64 libnss3 libxss1 \
        fonts-liberation fonts-noto-core; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc/* /usr/share/man/* /tmp/*; \
    command -v labwc; command -v wayvnc; command -v websockify; \
    test -f /usr/share/novnc/vnc.html
```

Also delete the now-unused `ARG KASMVNC_VERSION=1.3.4` and `ARG TARGETARCH` lines (they sit just above, around lines 22-27), and delete the `RUN usermod -aG ssl-cert dev` line and its two-line comment (around lines 92-94).

The X client libraries stay: GTK links them regardless of session type. Only the X *server* packages (`xauth`, `x11-xserver-utils`, `xfonts-base`, `openbox`, `ssl-cert`) are gone.

- [ ] **Step 2: Replace the trailing ENV**

Replace the `ENV DISPLAY=:1` line and its comment near the end of `Dockerfile.browser` with:

```dockerfile
# Every shell — including `docker exec`, which does not inherit the entrypoint's
# environment — needs to find the compositor. XDG_RUNTIME_DIR is a fixed path
# rather than /run/user/$(id -u) because the UID differs between the rootful
# `dev` path and the rootless `--user 0:0` path, and only a fixed value can live
# in image ENV. MOZ_ENABLE_WAYLAND makes Camoufox a native Wayland client.
ENV WAYLAND_DISPLAY=wayland-0 \
    XDG_RUNTIME_DIR=/tmp/xdg \
    MOZ_ENABLE_WAYLAND=1
```

- [ ] **Step 3: Build the layer**

```bash
docker build -t agentic-dev-base:latest .
docker build -f Dockerfile.browser \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  -t agentic-browser-base:latest .
```

Expected: build succeeds. The four `command -v` / `test -f` checks at the end of the package layer are the build-time gate — a missing package fails the build there.

- [ ] **Step 4: Verify the packages and env, and that KasmVNC is gone**

```bash
docker run --rm agentic-browser-base:latest bash -c \
  'command -v labwc wayvnc websockify wlr-randr; \
   test -f /usr/share/novnc/vnc.html && echo novnc-ok; \
   echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR MOZ_ENABLE_WAYLAND=$MOZ_ENABLE_WAYLAND DISPLAY=${DISPLAY:-unset}"; \
   command -v vncserver kasmvncpasswd Xvnc 2>/dev/null && echo "KASM STILL PRESENT" || echo kasm-gone'
```

Expected output ends with:
```
novnc-ok
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg MOZ_ENABLE_WAYLAND=1 DISPLAY=unset
kasm-gone
```

- [ ] **Step 5: THE GATE — prove Camoufox runs as a native Wayland client**

This is the risk the whole design hangs on. Run labwc by hand (the entrypoint does not exist yet) and drive Camoufox through Playwright:

```bash
docker run --rm agentic-browser-base:latest bash -c '
set -e
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
labwc >/tmp/labwc.log 2>&1 &
sleep 5
test -S $XDG_RUNTIME_DIR/wayland-0 && echo "compositor-up"
camoufox-py - <<PY
from camoufox.sync_api import Camoufox
with Camoufox(headless=False) as b:
    p = b.new_page()
    p.goto("about:blank")
    p.set_viewport_size({"width": 1280, "height": 800})
    p.screenshot(path="/tmp/shot.png")
    print("camoufox-drove-ok")
PY
python3 -c "
import struct
d=open(\"/tmp/shot.png\",\"rb\").read()
w,h=struct.unpack(\">II\", d[16:24])
print(f\"screenshot {w}x{h} bytes={len(d)}\")
"'
```

Expected output contains:
```
compositor-up
camoufox-drove-ok
screenshot 1280x800 bytes=<some number greater than 1000>
```

**If this fails**, apply the spec's documented contingency before continuing: add `xwayland` to the package list in Step 1, drop `MOZ_ENABLE_WAYLAND=1` from the `ENV` in Step 2, and re-run Steps 3-5. Camoufox then runs on Xwayland under labwc exactly as it runs on X today. Record which path was taken in the commit message — the rest of the plan is unaffected either way.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile.browser
git commit -m "feat(browser): swap KasmVNC for the Wayland view stack

labwc, wayvnc, novnc and websockify, all from Debian trixie main —
replacing the kali-rolling KasmVNC .deb, openbox, the X server packages
and the ssl-cert group hack.

Camoufox verified as a native Wayland client under headless labwc."
```

---

### Task 2: Entrypoint and labwc configuration

**Files:**
- Create: `browser/with-view`, `browser/labwc-autostart`, `browser/labwc-rc.xml`
- Delete: `browser/with-vnc`
- Modify: `Dockerfile.browser` (the trailing `COPY`/`chmod` pair)

**Interfaces:**
- Consumes: image env from Task 1 (`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `MOZ_ENABLE_WAYLAND`).
- Produces: executable `with-view` on `PATH`, which runs the compositor as PID1 and serves noVNC on container port `$VIEW_PORT` (default `8444`). Honours env `VIEW_GEOMETRY` (default `1280x800`) and `VIEW_PORT`. These two names are what `run-browser.sh` sets in Task 3.

- [ ] **Step 1: Write `browser/with-view`**

```bash
#!/usr/bin/env bash
# Container entrypoint for the browser view. Prepares the Wayland runtime
# environment, then execs labwc as PID1. labwc's autostart (/etc/labwc/autostart)
# brings up wlr-randr, wayvnc and websockify — it runs after the compositor is
# live, so nothing here has to poll for the wayland socket.
#
# Env knobs:
#   VIEW_GEOMETRY=1280x800   headless output size
#   VIEW_PORT=8444           container port websockify serves noVNC on
#
# No TLS and no password: wayvnc binds container-localhost and only websockify's
# port is exposed, which run-browser.sh publishes to 127.0.0.1 on the host.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# Headless wlroots backend with the software renderer: no GPU, no /dev/dri, no
# extra host privilege. WLR_LIBINPUT_NO_DEVICES stops wlroots demanding input
# devices that a container does not have.
export WLR_BACKENDS="${WLR_BACKENDS:-headless}"
export WLR_LIBINPUT_NO_DEVICES=1
export WLR_RENDERER="${WLR_RENDERER:-pixman}"

export VIEW_GEOMETRY="${VIEW_GEOMETRY:-1280x800}"
export VIEW_PORT="${VIEW_PORT:-8444}"

# -C /etc/labwc, never ~/.config/labwc: $HOME is /home/dev and its subdirectories
# are runtime bind-mounts.
exec labwc -C /etc/labwc
```

- [ ] **Step 2: Write `browser/labwc-autostart`**

```sh
#!/bin/sh
# Run by labwc once the compositor is up. Ordering is therefore guaranteed
# without any wait-for-socket polling — that polling is what produced the
# launch bugs in the KasmVNC era.
#
# Failure of wlr-randr is non-fatal: the default headless mode stands and the
# view still works, just at the wrong size.
wlr-randr --output HEADLESS-1 --custom-mode "${VIEW_GEOMETRY:-1280x800}" || true

# RFB server, container-localhost only. Never expose this port directly.
wayvnc 127.0.0.1 5900 &

# Serves the noVNC client and proxies its WebSocket to wayvnc. Binding 0.0.0.0
# is inside the container; host exposure is decided solely by the -p mapping.
websockify --web=/usr/share/novnc "0.0.0.0:${VIEW_PORT:-8444}" 127.0.0.1:5900 &
```

- [ ] **Step 3: Write `browser/labwc-rc.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!-- Minimal labwc config for the browser view. Server-side decorations so a
     browser window gets a titlebar that can be dragged and resized through the
     noVNC client; no keybindings, since this compositor exists to show one
     browser rather than to be used as a desktop. -->
<labwc_config>
  <core>
    <decoration>server</decoration>
    <gap>0</gap>
  </core>
  <theme>
    <titlebar>
      <layout>icon:iconify,max,close</layout>
      <showTitle>yes</showTitle>
    </titlebar>
  </theme>
  <windowRules>
    <windowRule identifier="*" serverDecoration="yes" />
  </windowRules>
</labwc_config>
```

- [ ] **Step 4: Update the COPY block in `Dockerfile.browser` and delete `with-vnc`**

Replace the trailing `COPY`/`chmod` pair with:

```dockerfile
# Helper scripts last, so tweaking them doesn't invalidate the ~700MB camoufox
# fetch layer above. with-view (entrypoint), camoufox-open (launcher),
# camoufox-py (venv python), plus the labwc config that autostart depends on.
COPY browser/with-view browser/camoufox-open browser/camoufox-py /usr/local/bin/
COPY browser/labwc-rc.xml /etc/labwc/rc.xml
COPY browser/labwc-autostart /etc/labwc/autostart
RUN chmod 0755 /usr/local/bin/with-view /usr/local/bin/camoufox-open \
      /usr/local/bin/camoufox-py /etc/labwc/autostart
```

Then:

```bash
git rm browser/with-vnc
chmod +x browser/with-view
```

- [ ] **Step 5: Syntax-check the scripts**

```bash
bash -n browser/with-view && sh -n browser/labwc-autostart && echo "syntax ok"
```

Expected: `syntax ok`

- [ ] **Step 6: Rebuild and run the full stack check**

```bash
docker build -f Dockerfile.browser \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  -t agentic-browser-base:latest .

docker rm -f viewtest 2>/dev/null
docker run -d --name viewtest -p 127.0.0.1:8444:8444 \
  --entrypoint with-view agentic-browser-base:latest
sleep 8

echo "--- PID1 ---"
docker exec viewtest ps -p 1 -o comm=
echo "--- wayland socket ---"
docker exec viewtest test -S /tmp/xdg/wayland-0 && echo wayland-0-ok
echo "--- wayvnc listening ---"
docker exec viewtest sh -c '(ss -ltn 2>/dev/null || netstat -ltn) | grep -c "127.0.0.1:5900"'
echo "--- novnc served ---"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8444/vnc.html
echo "--- output geometry ---"
docker exec viewtest sh -c 'WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg wlr-randr' | grep -A1 HEADLESS-1 | head -2
```

Expected:
```
--- PID1 ---
labwc
--- wayland socket ---
wayland-0-ok
--- wayvnc listening ---
1
--- novnc served ---
200
--- output geometry ---
HEADLESS-1 "Headless output 1"
  Make: (null)
```

- [ ] **Step 7: Verify a custom geometry takes effect**

```bash
docker rm -f viewtest
docker run -d --name viewtest -p 127.0.0.1:8444:8444 \
  -e VIEW_GEOMETRY=1600x900 --entrypoint with-view agentic-browser-base:latest
sleep 8
docker exec viewtest sh -c 'WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg wlr-randr --json' | grep -i '"width"\|"height"' | head -4
docker rm -f viewtest
```

Expected: the current mode reports width `1600` and height `900`.

- [ ] **Step 8: Commit**

```bash
git add browser/with-view browser/labwc-autostart browser/labwc-rc.xml Dockerfile.browser
git commit -m "feat(browser): with-view entrypoint, labwc runs as PID1

labwc's own autostart launches wlr-randr, wayvnc and websockify once the
compositor is live, so no wait-for-socket polling is needed. Config lives
in /etc/labwc because \$HOME's subdirectories are runtime bind-mounts."
```

---

### Task 3: `run-browser.sh`

**Files:**
- Create: `run-browser.sh`

**Interfaces:**
- Consumes: `with-view` entrypoint and the `VIEW_GEOMETRY`/`VIEW_PORT` env contract from Task 2.
- Produces: the user-facing launcher. Boots `agentic-hermes:latest` (not the browser base — the agent binary must be present in the container you exec into) with `--entrypoint with-view`, publishes to `127.0.0.1` only, and prints both the view URL and the `docker exec` line.

- [ ] **Step 1: Write `run-browser.sh`**

```bash
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
# Stop with: docker rm -f NAME
set -euo pipefail

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

# Rootless Docker maps the host user to container root, so bind-mounted files
# appear owned by uid 0 and the non-root `dev` user cannot write them. Same
# rule the agent runners use.
if [ -z "${USER_FLAG+x}" ]; then
  if docker info 2>/dev/null | grep -q 'rootless: true'; then
    USER_FLAG="--user 0:0"
  else
    USER_FLAG=""
  fi
fi

if docker ps -aq -f "name=^${NAME}$" | grep -q .; then
  docker ps -q -f "name=^${NAME}$" | grep -q . || docker start "$NAME" >/dev/null
else
  docker run -d --name "$NAME" $USER_FLAG \
    -e "VIEW_PORT=8444" -e "VIEW_GEOMETRY=$GEOMETRY" \
    -p "127.0.0.1:${PORT}:8444" \
    -v "$WORK_DIR":/work \
    -w /work --entrypoint with-view \
    "$IMAGE" >/dev/null
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
  echo "  check: docker logs $NAME" >&2
  exit 1
fi

cat <<EOF
Browser view up (container '$NAME', ${GEOMETRY}).
  Watch:  http://localhost:${PORT}/vnc.html?autoconnect=true&resize=remote
  Drive:  docker exec -it $USER_FLAG -w /work $NAME hermes
  Browse: docker exec -it $USER_FLAG $NAME camoufox-open https://example.com
  Stop:   docker rm -f $NAME
EOF
```

- [ ] **Step 2: Make it executable and syntax-check**

```bash
chmod +x run-browser.sh && bash -n run-browser.sh && echo "syntax ok"
```

Expected: `syntax ok`

- [ ] **Step 3: Verify it boots and reports correctly**

```bash
docker rm -f hermes-view 2>/dev/null
./run-browser.sh -g 1600x900
```

Expected: the four-line summary block, with `1600x900` in the header and a `http://localhost:8444/vnc.html?autoconnect=true&resize=remote` watch line.

- [ ] **Step 4: Verify the publish is localhost-only**

This is the security property the design rests on — check it explicitly rather than trusting the flag.

```bash
docker port hermes-view
```

Expected: `8444/tcp -> 127.0.0.1:8444` — and **not** `0.0.0.0:8444`.

- [ ] **Step 5: Verify the printed exec line actually works**

```bash
docker exec -w /work hermes-view sh -c 'echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; test -S "$XDG_RUNTIME_DIR/wayland-0" && echo exec-sees-compositor'
```

Expected:
```
WAYLAND_DISPLAY=wayland-0
exec-sees-compositor
```

This confirms the fixed `XDG_RUNTIME_DIR` decision: `docker exec` does not inherit the entrypoint's environment, so an exec'd agent finds the compositor only because the value is baked into image `ENV`.

- [ ] **Step 6: Verify the failure path reports rather than hangs**

```bash
docker rm -f hermes-view 2>/dev/null
./run-browser.sh -I debian:trixie-slim -n brokentest ; echo "exit=$?"
docker rm -f brokentest 2>/dev/null
```

Expected: after roughly 30 seconds, `run-browser.sh: view did not come up on 127.0.0.1:8444`, the `docker logs brokentest` hint, and `exit=1`.

- [ ] **Step 7: Clean up and commit**

```bash
docker rm -f hermes-view 2>/dev/null
git add run-browser.sh
git commit -m "feat: run-browser.sh, standalone browser view launcher

Boots the view container and prints the exec line to drive it. Publishes
to 127.0.0.1 only — no TLS and no password by design."
```

---

### Task 4: Revert `run-hermes.sh` and `Dockerfile.hermes`

**Files:**
- Modify: `run-hermes.sh` (usage 5, 20-25, 34-35; vars 54-55; parse loop 99-119; browser block 197-236)
- Modify: `Dockerfile.hermes:13-16` (header comment), `Dockerfile.hermes:57` (`ENTRYPOINT`)

**Interfaces:**
- Consumes: nothing from Tasks 1-3 — this task only removes.
- Produces: `run-hermes.sh` with no browser awareness, and `agentic-hermes` whose default entrypoint is bare `hermes`.

- [ ] **Step 1: Strip the usage block in `run-hermes.sh`**

On line 5, change the usage line to:

```
#   run-hermes.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit] [-- <hermes args>]
```

Delete lines 20-25 entirely (the `-b [PORT]` description). Delete lines 34-35 (the two `-b` examples). Add one line to the examples block in their place:

```
#   For the browser view, see run-browser.sh.
```

- [ ] **Step 2: Delete the browser variables**

Delete lines 54-55:

```bash
BROWSER=0
VNC_PORT="${VNC_PORT:-8444}"
```

- [ ] **Step 3: Simplify the pre-getopts parse loop**

Replace the comment and loop at lines 99-119 with:

```bash
# Extract --edit/--del before getopts (which handles no long flags). Stop at `--`
# so agent passthrough args are left alone.
EDIT=0
DEL=0
_args=(); _stop=0
for _a in "$@"; do
  [ "$_stop" -eq 0 ] && [ "$_a" = "--" ] && _stop=1
  if [ "$_stop" -eq 0 ] && [ "$_a" = "--edit" ]; then EDIT=1; continue; fi
  if [ "$_stop" -eq 0 ] && [ "$_a" = "--del" ]; then DEL=1; continue; fi
  _args+=("$_a")
done
set -- "${_args[@]}"
```

The `_b_seen` variable and the bare-number consumption case disappear with it — that hack existed only because getopts cannot express an optional-argument flag.

- [ ] **Step 4: Delete the entire browser block**

Delete lines 197-236 — the `# --- Browser view (-b) ---` comment through the closing `fi` of that block, including the password generation, the ephemeral container naming, the detached `docker run`, the launch-line `echo`, and the `trap ... EXIT INT TERM`.

The file should now go straight from the `MOUNTS=(...)` array to `# --- Named container: ... ---`.

- [ ] **Step 5: Update `Dockerfile.hermes`**

Replace the header comment at lines 13-16 with:

```dockerfile
# Re-based on the browser layer (labwc + Camoufox) so the hermes agent can drive
# a stealth browser. UID/GID are consumed by that layer (which creates the `dev`
# user); declared here so build.sh can pass them without an "unused build arg"
# warning. For the watchable view, boot this image with run-browser.sh.
```

Replace lines 54-57 with:

```dockerfile
# Bare `hermes` starts the interactive CLI; extra args from `docker run` are
# appended. The browser view uses a different entrypoint (`with-view`), which
# run-browser.sh selects explicitly.
ENTRYPOINT ["hermes"]
```

- [ ] **Step 6: Syntax-check and confirm every trace is gone**

```bash
bash -n run-hermes.sh && echo "syntax ok"
grep -n "BROWSER\|VNC\|_b_seen\|with-vnc\|kasm" run-hermes.sh Dockerfile.hermes || echo "no browser traces"
```

Expected:
```
syntax ok
no browser traces
```

- [ ] **Step 7: Verify `-b` is now rejected and the normal path still works**

```bash
docker build -f Dockerfile.hermes \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  -t agentic-hermes:latest .

./run-hermes.sh -b 2>&1 | head -2; echo "exit=${PIPESTATUS[0]}"
./run-hermes.sh -h | head -5
docker run --rm --entrypoint sh agentic-hermes:latest -c \
  'command -v hermes && echo hermes-present'
```

Expected: `-b` produces a getopts `illegal option` error and a non-zero exit; `-h` prints usage with no `-b` line; the image reports `hermes-present`.

- [ ] **Step 8: Verify the view still works end to end after the entrypoint change**

`run-browser.sh` overrides the entrypoint, so Task 3 must still pass against the rebuilt image:

```bash
docker rm -f hermes-view 2>/dev/null
./run-browser.sh
docker exec -w /work hermes-view sh -c 'test -S "$XDG_RUNTIME_DIR/wayland-0" && echo still-ok'
docker rm -f hermes-view
```

Expected: the summary block, then `still-ok`.

- [ ] **Step 9: Commit**

```bash
git add run-hermes.sh Dockerfile.hermes
git commit -m "refactor: drop -b and the detached-boot machinery from run-hermes

The browser view now lives in run-browser.sh. This removes the optional-
argument getopts hack, the generated VNC password, the ephemeral
hermes-view-\$\$ container and its EXIT trap, and restores the plain
hermes entrypoint."
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` (lines 6, 82-106, 142, 162, 252-260), `build.sh` (lines 9, 111-113), `browser/camoufox-open` (header comment and the printed line)

**Interfaces:**
- Consumes: the finished behaviour of Tasks 1-4.
- Produces: docs that match the shipped code. No code behaviour changes here.

- [ ] **Step 1: Update `browser/camoufox-open`**

Replace the header comment with:

```bash
#!/usr/bin/env bash
# Open a URL in Camoufox (visible, non-headless) on the container's Wayland
# compositor and hold it open so you can watch it through the noVNC view.
# Ctrl-C to quit.
#
#   camoufox-open [URL]
#
# Needs a live compositor: run inside a container booted by run-browser.sh.
# Defaults to a fingerprint test page so you can confirm stealth.
```

In the Python heredoc, change the printed line from `DISPLAY` to the Wayland display:

```python
    print(f"[camoufox-open] {url} open on WAYLAND_DISPLAY={os.environ.get('WAYLAND_DISPLAY')}. Ctrl-C to quit.")
```

- [ ] **Step 2: Update `build.sh` comments**

Line 9 becomes:

```
#   agentic-browser-base:latest (Dockerfile.browser) <- base + labwc/wayvnc/noVNC + Camoufox
```

Lines 111-113 become:

```bash
# Shared browser layer (Wayland view + Camoufox) that hermes is re-based on. Built
echo "==> Building agentic-browser-base:latest  (Dockerfile.browser)"
```

No build logic changes — `build.sh` already builds the layer in the right order.

- [ ] **Step 3: Rewrite the README browser sections**

Line 6 (the intro list): replace the KasmVNC link and description with
`[labwc](https://labwc.github.io/) + [wayvnc](https://github.com/any1/wayvnc) + [noVNC](https://novnc.com/) (web remote view)`.

Replace the section heading at line 82 with `### agentic-browser-base (base + Wayland view + Camoufox)` and rewrite lines 86-106 to describe: headless labwc as PID1, wayvnc on container-localhost, websockify serving `/usr/share/novnc`, everything from trixie main, and **no TLS or password because the view is published to `127.0.0.1` only**. Delete the clipboard/HTTPS/Chromium-viewer paragraph — with no TLS there is no secure-context requirement, and clipboard now rides `wl-clipboard` through wayvnc.

Line 142 comment becomes `# 1b. Browser layer (Wayland view + Camoufox); hermes is built FROM this`.

Line 162: delete the `KASMVNC_VERSION` build-arg row; there is no version arg any more.

Replace the `**Browser view (run-hermes.sh -b [PORT])**` paragraph at lines 252-260 with a `run-browser.sh` section documenting the five flags (`-n -p -w -g -I`), the `http://localhost:PORT/vnc.html` URL, the `docker exec -it NAME hermes` follow-up, and the localhost-only security note with the SSH/Tailscale advice for remote viewing.

- [ ] **Step 4: Verify the docs match reality**

```bash
grep -rn "kasm\|Kasm\|KASMVNC\|START_VNC\|VNC_PASSWORD\|with-vnc\|openbox" \
  README.md build.sh browser/ Dockerfile.browser Dockerfile.hermes run-hermes.sh run-browser.sh \
  || echo "no stale references"
grep -n "run-browser.sh" README.md | head -3
```

Expected: `no stale references`, followed by at least one README hit for `run-browser.sh`.

- [ ] **Step 5: Commit**

```bash
git add README.md build.sh browser/camoufox-open
git commit -m "docs: describe the Wayland view and run-browser.sh"
```

---

## Final verification

Run once after all five tasks, from a clean state:

```bash
./build.sh
docker rm -f hermes-view 2>/dev/null
./run-browser.sh -g 1440x900
docker port hermes-view                     # expect 127.0.0.1:8444, never 0.0.0.0
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8444/vnc.html            # expect 200
docker exec hermes-view ps -p 1 -o comm=    # expect labwc
docker exec -d hermes-view camoufox-open https://example.com
sleep 15
docker exec hermes-view sh -c 'pgrep -c -f camoufox'   # expect at least 1
docker rm -f hermes-view
./run-hermes.sh -- --help                   # expect hermes help, no browser env
```

Then open `http://localhost:8444/vnc.html?autoconnect=true&resize=remote` and confirm the Camoufox window is visible and clickable — the one check that cannot be automated.
