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

# Sanity: fail the build if any tool is missing.
RUN set -eux; \
    rustc --version; cargo --version; clippy-driver --version; rust-analyzer --version; \
    node --version; npm --version; bun --version; \
    python3 --version; uv --version; \
    git --version; rg --version; fd --version; jq --version; nvim --version | head -1

WORKDIR /work
CMD ["bash"]
