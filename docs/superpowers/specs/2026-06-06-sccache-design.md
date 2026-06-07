# sccache in the base image + shared compile cache

**Date:** 2026-06-06
**Status:** Approved, ready for implementation plan

## Problem

The base image (`Dockerfile`) ships Rust but no compiler cache. Every container
build recompiles dependencies from scratch, and nothing is shared between runs or
with the host. Add [sccache](https://github.com/mozilla/sccache) so cargo builds
hit a persistent, host-shared cache.

## Decisions

- **Install via `cargo binstall`** (prebuilt binary, no source compile).
- **All four runners** (`run-claude/goose/hermes/pi.sh`) mount the cache. sccache
  lives in the shared base image, so every agent benefits.
- **Global wrapper, incremental left ON.** `RUSTC_WRAPPER=sccache` makes every
  cargo build use sccache automatically. `CARGO_INCREMENTAL` is **not** changed —
  local incremental crates will skip sccache (incremental compilation wins there),
  but dependency builds (non-incremental) still cache. Accepted tradeoff.
- **Pinned** via `ARG`, matching the rtk convention.

## Design

### 1. Base image — `Dockerfile`

**New build arg** (place near `ARG RTK_TAG`):

```dockerfile
# sccache version for cargo-binstall. Bare semver (no leading "v"): binstall's
# version spec is `sccache@X.Y.Z`. Override with --build-arg SCCACHE_VERSION=X.Y.Z.
ARG SCCACHE_VERSION=0.8.2
```

**New RUN layer** (after the rtk install layer, before the sanity-check RUN):

```dockerfile
# sccache: compiler cache for Rust. Installed with cargo-binstall (prebuilt
# binary, no source compile). cargo-binstall itself comes from its official
# prebuilt installer script. Both land in $CARGO_HOME/bin (already on PATH).
RUN set -eux; \
    curl -fsSL --proto '=https' --tlsv1.2 \
        https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
        | bash; \
    cargo binstall --no-confirm "sccache@${SCCACHE_VERSION}"; \
    sccache --version; \
    chmod -R a+rwX "$CARGO_HOME"; \
    rm -rf /root/.cache /tmp/*
```

**New ENV** (place with the other Rust ENV near the top, or right after the
sccache layer — ENV applies image-wide at runtime regardless):

```dockerfile
# Route all cargo builds through sccache, and pin the cache dir so the runner
# bind-mount target is deterministic even under rootless Docker (container runs
# as root, HOME=/root, so the default ~/.cache/sccache would miss the mount).
ENV RUSTC_WRAPPER=sccache \
    SCCACHE_DIR=/home/dev/.cache/sccache
```

**Sanity-check RUN** — add `sccache --version` to the existing final check line
alongside `rustc --version; cargo --version; ...`.

> Note: `RUSTC_WRAPPER=sccache` is set image-wide. No cargo *build* runs in later
> Dockerfile steps (only `cargo --version` in the sanity check), so it has no
> build-time effect; it only matters at container runtime.

### 2. Runners — all four `run-*.sh`

Each runner has two launch blocks: a named (persistent) `docker run -d ...` and an
unnamed (throwaway) `docker run --rm ...` (claude/goose/hermes) or equivalent. The
cache mount goes in **both** blocks of **each** file.

**Host cache dir resolution** (add near the other top-of-file vars, e.g. by
`WORK_DIR=...`):

```sh
# Persistent sccache compile cache, shared with the host. Pin to the host default
# (~/.cache/sccache) unless SCCACHE_DIR is already exported. Create it before the
# mount so Docker doesn't materialize a root-owned dir.
SCCACHE_CACHE="${SCCACHE_DIR:-$HOME/.cache/sccache}"
mkdir -p "$SCCACHE_CACHE"
```

**Mount line** (add to every `docker run` block, next to `-v "$WORK_DIR":/work`):

```sh
  -v "$SCCACHE_CACHE":/home/dev/.cache/sccache \
```

The container always sees the cache at `/home/dev/.cache/sccache`, which matches
the image's `SCCACHE_DIR`, so it works under both rootful (`dev` user, HOME
`/home/dev`) and rootless (`root`, HOME `/root` — `SCCACHE_DIR` overrides the
default).

Per-file mount-block locations:
- `run-claude.sh` — named block (~L216) and unnamed block (~L228).
- `run-goose.sh` — named (~L121) and unnamed (~L131).
- `run-hermes.sh` — named (~L111) and unnamed (~L121).
- `run-pi.sh` — named (~L140) and unnamed (~L151), alongside the existing
  `-e XDG_DATA_HOME=...` / `-v` flags.

### 3. Docs — `README.md`

One short note: the base image bundles sccache as the Rust compiler cache, wired
via `RUSTC_WRAPPER`; the cache persists on the host at `~/.cache/sccache` and is
shared across all agents and with host builds.

## Out of scope

- Distributed/remote sccache backends (S3, Redis, memcached). Local disk only.
- Disabling incremental compilation (`CARGO_INCREMENTAL=0`) — explicitly left on.
- Caching for non-Rust toolchains (sccache can wrap C/C++; not configured here).

## Verification

- `docker build -t agentic-dev-base:latest .` succeeds; sanity RUN prints an
  sccache version.
- In a container: `echo $RUSTC_WRAPPER` → `sccache`; `sccache --version` works;
  `sccache --show-stats` runs.
- Build a small Rust project twice across two `run-*.sh` invocations; second build
  shows sccache cache hits and `~/.cache/sccache` on the host is populated.
- Each runner: confirm the mount appears in `docker inspect` (or that the host
  cache dir grows after a build).
