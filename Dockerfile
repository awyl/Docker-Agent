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
    LC_ALL=C.UTF-8

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

# Sanity: fail the build if any tool is missing.
RUN set -eux; \
    rustc --version; cargo --version; clippy-driver --version; rust-analyzer --version; \
    node --version; npm --version; bun --version; \
    python3 --version; uv --version; rtk --version; \
    git --version; rg --version; fd --version; jq --version; nvim --version | head -1

WORKDIR /work
CMD ["bash"]
