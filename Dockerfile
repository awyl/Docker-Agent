# syntax=docker/dockerfile:1
#
# Agentic dev base image.
# Languages: Rust (stable + clippy/rustfmt), Node.js LTS, Bun, Python3 + uv.
# Tooling: git, ripgrep, fd, jq, fzf, bat, curl/wget, unzip, neovim, build chain.
# Goal: everything current, disk footprint kept low (single layers, caches purged).

FROM debian:trixie-slim

LABEL org.opencontainers.image.title="agentic-dev-base" \
      org.opencontainers.image.description="Rust + Node + Bun + Python3 base for agentic workflows"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# Pull uv/uvx as static binaries from the official image (smaller than the installer).
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Rust lives in /usr/local so every user sees it.
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/bun/bin:$PATH \
    BUN_INSTALL=/usr/local/bun

# ---- system packages + Node.js + Bun + Rust, all in one layer ----
RUN set -eux; \
    apt-get update; \
    apt-get -y --no-install-recommends upgrade; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git openssh-client \
        build-essential pkg-config libssl-dev \
        python3 python3-venv python3-dev \
        ripgrep fd-find jq fzf bat unzip xz-utils \
        neovim less locales; \
    # bat/fd ship under d suffix on Debian; add the conventional names
    ln -sf /usr/bin/batcat /usr/local/bin/bat; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    \
    # --- Node.js LTS (22.x) via NodeSource ---
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    npm install -g npm@latest; \
    \
    # --- Bun (latest) ---
    curl -fsSL https://bun.sh/install | bash; \
    \
    # --- Rust (latest stable, minimal profile + clippy/rustfmt/rust-analyzer) ---
    # rust-analyzer is the LSP server the rust-analyzer-lsp plugin drives.
    curl -fsSL https://sh.rustup.rs | sh -s -- \
        -y --no-modify-path --profile minimal \
        --component clippy --component rustfmt --component rust-analyzer; \
    ln -sf "$(rustup which rust-analyzer)" /usr/local/bin/rust-analyzer; \
    # wasm browser/web target (wasm-bindgen, trunk, leptos/yew, ...).
    rustup target add wasm32-unknown-unknown; \
    chmod -R a+rwX "$CARGO_HOME" "$RUSTUP_HOME"; \
    \
    # ---- shrink: drop caches, docs, apt lists ----
    npm cache clean --force; \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/cache/apt/* \
        /root/.cache \
        /usr/local/cargo/registry/cache \
        /usr/local/cargo/registry/src \
        /usr/share/doc/* \
        /usr/share/man/* \
        /tmp/*

# rtk: token-compressing proxy the agent hooks call (e.g. `rtk hook claude`).
# Prebuilt release binary instead of `cargo install` from source — much faster
# build, and the x86_64 musl asset is statically linked so it runs regardless of
# the container's glibc. Pinned; override with --build-arg RTK_TAG=vX.Y.Z.
# TARGETARCH is set by buildx; falls back to amd64 under a plain `docker build`.
# sccache version for cargo-binstall. Bare semver (no leading "v"): binstall's
# version spec is `sccache@X.Y.Z`. Override with --build-arg SCCACHE_VERSION=X.Y.Z.
ARG SCCACHE_VERSION=0.8.2
ARG RTK_TAG=v0.42.0
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) rtk_triple=x86_64-unknown-linux-musl ;; \
        arm64) rtk_triple=aarch64-unknown-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
        "https://github.com/rtk-ai/rtk/releases/download/${RTK_TAG}/rtk-${rtk_triple}.tar.gz" \
        -o /tmp/rtk.tar.gz; \
    tar -xzf /tmp/rtk.tar.gz -C /tmp; \
    install -m 0755 "$(find /tmp -type f -name rtk | head -1)" /usr/local/bin/rtk; \
    rm -rf /tmp/*; \
    rtk --version

# sccache: compiler cache for Rust. Installed with cargo-binstall (prebuilt
# binary, no source compile). cargo-binstall itself comes from its official
# prebuilt installer script. Both land in $CARGO_HOME/bin (already on PATH).
RUN set -eux; \
    curl -fsSL --proto '=https' --tlsv1.2 \
        https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
        | bash; \
    cargo binstall --no-confirm "sccache@${SCCACHE_VERSION}"; \
    ln -sf "$CARGO_HOME/bin/sccache" /usr/local/bin/sccache; \
    sccache --version; \
    chmod -R a+rwX "$CARGO_HOME"; \
    rm -rf /root/.cache /tmp/*

# Route all cargo builds through sccache, and pin the cache dir so the runner
# bind-mount target is deterministic even under rootless Docker (container runs
# as root, HOME=/root, so the default ~/.cache/sccache would miss the mount).
ENV RUSTC_WRAPPER=sccache \
    SCCACHE_DIR=/home/dev/.cache/sccache

# Sanity: fail the build if any tool is missing.
RUN set -eux; \
    rustc --version; cargo --version; clippy-driver --version; rust-analyzer --version; sccache --version; \
    rustup target list --installed | grep -qx wasm32-unknown-unknown; \
    node --version; npm --version; bun --version; \
    python3 --version; uv --version; rtk --version; \
    git --version; rg --version; fd --version; jq --version; nvim --version | head -1

WORKDIR /work
CMD ["bash"]
