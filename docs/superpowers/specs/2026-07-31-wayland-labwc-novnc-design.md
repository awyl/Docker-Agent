# Wayland browser view: labwc + wayvnc + noVNC

**Date:** 2026-07-31
**Status:** Approved, ready for implementation plan

## Problem

`agentic-browser-base` currently gets its remote view from **KasmVNC**, chosen for
adaptive WebP encoding. In practice the encoding advantage is not perceptible for
watching a browser, and the stack carries real complexity:

- No Debian-trixie build exists, so the image pulls a **kali-rolling `.deb`** from a
  GitHub release — a third-party, out-of-distro supply chain.
- HTTPS forces the snakeoil private key, which forces `usermod -aG ssl-cert dev`.
- `kasmvncpasswd` imposes a 6-character minimum, so `run-hermes.sh` generates and
  prints a password.
- The `-geometry` CLI flag is ignored by the `vncserver` wrapper, so resolution has to
  be written into `~/.vnc/kasmvnc.yaml`.
- Starting `Xvnc` grabs the controlling TTY, which produced two launch bugs
  (commits 273d93e, cfd378e) and left a `</dev/tty` reconnect in `with-vnc`.

## Goal

Replace KasmVNC with **labwc (headless Wayland) + wayvnc (RFB) + noVNC (served by
websockify)**, all from Debian trixie main, and decouple the browser view from
`run-hermes.sh` into its own `run-browser.sh`.

The driver is a **simpler stack**, not better fidelity. Plain RFB is weaker than
KasmVNC's adaptive WebP; this is accepted deliberately.

## Verified facts

Confirmed by container experiment on `debian:trixie-slim` before writing this spec:

- All packages are in **trixie main** — `labwc 0.8.3-1`, `wayvnc 0.9.1-1`,
  `novnc 1:1.6.0-2`, `websockify 0.12.0+dfsg1-4+b1`, `wlr-randr`, `wl-clipboard`.
  No third-party repo, no compilation.
- `labwc` starts headless with `WLR_BACKENDS=headless`, `WLR_LIBINPUT_NO_DEVICES=1`,
  `WLR_RENDERER=pixman` and creates `wayland-0`.
- The output is named **`HEADLESS-1`** and is visible to `wlr-randr`, so geometry is
  set with `--custom-mode` — no config-file quirk.
- `wayvnc 127.0.0.1 5900` attaches to that compositor and listens.
- Debian's `novnc` ships **`/usr/share/novnc/vnc.html`** but **no `novnc_proxy`
  binary**, so websockify serves the web root directly.

## Decisions

- **Approach B — labwc `autostart` drives the stack.** The entrypoint sets environment
  and `exec labwc`; labwc's native `autostart` launches `wlr-randr`, `wayvnc`, and
  `websockify`. autostart runs after the compositor is up, which removes the
  wait-for-socket polling that caused the earlier launch bugs. Container PID1 is labwc,
  so the compositor's death is the container's death.
- **Native Wayland, no Xwayland.** Camoufox runs with `MOZ_ENABLE_WAYLAND=1`. No X
  server or X client packages in the image. This is the one unverified assumption; see
  Risks.
- **Localhost only, no TLS, no auth.** `wayvnc` binds container-localhost; only
  websockify's port is published, and `run-browser.sh` maps it to `127.0.0.1` on the
  host. Nothing is reachable from the LAN. Remote viewing goes over SSH or Tailscale.
  This deletes the snakeoil cert, the `ssl-cert` group, and all password handling.
- **`-b` and the detached-boot machinery leave `run-hermes.sh` entirely.** The browser
  view becomes `run-browser.sh`. `run-hermes.sh` returns to its pre-browser shape.
- **`run-browser.sh` boots `agentic-hermes`, not `agentic-browser-base`,** with
  `--entrypoint with-view`. The agent binary must be present in the container the user
  execs into. The image is overridable by flag.
- **`XDG_RUNTIME_DIR` is a fixed `/tmp/xdg`,** not `/run/user/$(id -u)`. The UID differs
  between the rootful image-`USER dev` path and the rootless `--user 0:0` path; a fixed
  path can live in image `ENV` and therefore be inherited by `docker exec`, which does
  not inherit the entrypoint's environment. `with-view` creates it `0700`.

## Architecture

Image tree is unchanged in shape: `agentic-dev-base` → `agentic-browser-base` →
`agentic-hermes`. Only the browser layer's contents change.

```
host browser
  → 127.0.0.1:PORT (published)
  → websockify        serves /usr/share/novnc, proxies WebSocket → TCP
  → 127.0.0.1:5900    wayvnc
  → wlr-screencopy    labwc (PID1)
  ← virtual-pointer / virtual-keyboard   (input, reversed)

camoufox-open URL
  → Playwright 1.55 → Firefox (MOZ_ENABLE_WAYLAND=1) → wayland-0 → labwc
```

Because the agent's browser and the streamed compositor are the same `wayland-0`, the
view shows the exact browser the agent drives.

`browser/labwc-autostart`:

```sh
wlr-randr --output HEADLESS-1 --custom-mode "${VIEW_GEOMETRY:-1280x800}" &
wayvnc 127.0.0.1 5900 &
websockify --web=/usr/share/novnc 0.0.0.0:8444 127.0.0.1:5900 &
```

websockify binds `0.0.0.0` *inside* the container; host exposure is controlled solely
by the `-p 127.0.0.1:PORT:8444` mapping in `run-browser.sh`.

## Components

| File | Change |
|---|---|
| `Dockerfile.browser` | swap package block; `ENV WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/tmp/xdg MOZ_ENABLE_WAYLAND=1`; drop `ENV DISPLAY=:1` |
| `browser/with-view` | **new**, replaces `browser/with-vnc`; ends `exec labwc` |
| `browser/labwc-autostart` | **new**, static, launches the three services |
| `browser/labwc-rc.xml` | **new**, minimal labwc config (server-side decorations) |
| `run-browser.sh` | **new**; boots detached, waits for the port, prints view URL and the `docker exec` line |
| `run-hermes.sh` | revert to pre-browser shape |
| `Dockerfile.hermes` | `ENTRYPOINT ["hermes"]` |
| `build.sh` | unchanged — still builds the browser layer between base and agents |

`COPY browser/*` stays **last** in `Dockerfile.browser`, after the camoufox fetch, so
editing a script does not invalidate the ~700MB layer.

### Removed outright

`KASMVNC_VERSION` build arg and the kali-rolling `.deb`; `openbox`; the `ssl-cert`
package and `usermod -aG ssl-cert dev`; `xauth`, `x11-xserver-utils`, `xfonts-base`;
`kasmvnc.yaml` and `xstartup` generation; `START_VNC`; `VNC_PASSWORD` generation and
the 6-character rule; the `</dev/tty` reconnect and the `vncserver </dev/null`
workaround; `ENV DISPLAY=:1`; the `-b` pre-getopts parse loop, the `BROWSER` flag, the
ephemeral `hermes-view-$$` container, and the `EXIT`/`INT`/`TERM` trap in
`run-hermes.sh`.

### Deliberately kept

The GTK, NSS, ALSA, dbus, and font packages (`libgtk-3-0t64`, `libnss3`,
`fonts-liberation`, `fonts-noto-core`, …). Firefox needs these on Wayland too — only
the X *server* packages go.

## Interfaces

`run-browser.sh [-n NAME] [-p PORT] [-w WORK_DIR] [-g GEOMETRY] [-I IMAGE]`

- `-n NAME` container name, default `hermes-view`
- `-p PORT` host port, published to `127.0.0.1`, default `8444`
- `-w WORK_DIR` mounted at `/work`, same resolution rules as the other runners
- `-g GEOMETRY` `VIEW_GEOMETRY`, default `1280x800`
- `-I IMAGE` default `agentic-hermes:latest`

On success it prints the view URL
(`http://localhost:PORT/vnc.html?autoconnect=true&resize=remote`) and the exact
`docker exec -it NAME hermes` line to run.

## Error handling

No supervisor, by choice.

- **labwc dies** → PID1 exits → container exits. Correct: without a compositor nothing
  else is meaningful.
- **wayvnc or websockify dies** → container stays up with a dead view.
  `run-browser.sh` polls the published port after boot and reports failure plainly;
  all three services inherit PID1's stdio, so `docker logs NAME` has everything.
- **`wlr-randr` fails** → the default headless mode stands and the view still works at
  the wrong size. Non-fatal by design.

## Risks

**Camoufox on native Wayland is unverified.** Camoufox 0.4.11 is a Firefox 135 fork
driven by pinned Playwright 1.55; `MOZ_ENABLE_WAYLAND=1` has not been tested against
it. Implementation therefore verifies this **first**, before any `run-hermes.sh`
changes.

Contingency if it fails: add the `xwayland` package and drop `MOZ_ENABLE_WAYLAND`.
Camoufox then runs on Xwayland under labwc exactly as it runs on X today. One package,
no architectural change — the rest of the design is unaffected.

## Testing

Deterministic container checks:

- PID1 is `labwc`; `$XDG_RUNTIME_DIR/wayland-0` exists.
- `127.0.0.1:5900` is listening inside the container.
- `curl` on the published host port returns **200** for `vnc.html`.
- The published port is bound to `127.0.0.1` only, not `0.0.0.0`.

Camoufox check:

- `camoufox-open` maps a window on `wayland-0`, and a Playwright screenshot is
  non-blank and matches `VIEW_GEOMETRY`.

Regression:

- `run-hermes.sh` starts a plain agent with no browser environment present.
- `docker exec -it NAME hermes` attaches on a clean TTY and stays alive.

Launcher verification is `bash -n` plus runtime checks, matching the convention in
prior plans in this repo.
