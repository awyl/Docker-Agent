# syntax=docker/dockerfile:1
#
# goose agent (Block / AAIF) runner, built on the agentic-dev-base.
# Build the base first:   docker build -t agentic-dev-base:latest .
#
# Codebase + goose config are bind-mounted at RUN time (not baked in):
#   - host repo            -> /work
#   - host ~/.config/goose -> /home/dev/.config/goose
#
# UID/GID are build args so files written into the mounted config/repo
# stay owned by your host user.

FROM agentic-dev-base:latest

ARG UID=1000
ARG GID=1000

# No system keyring (dbus/secret-service) in a container -> use file-based
# secrets (~/.config/goose/secrets.yaml) instead.
ENV GOOSE_DISABLE_KEYRING=1

# goose CLI. The release tarball is .tar.bz2, so bzip2 is needed to unpack it.
# Install under a temp HOME, then move the binaries onto the global PATH.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends bzip2; \
    rm -rf /var/lib/apt/lists/*; \
    export HOME=/tmp/gi; mkdir -p "$HOME"; \
    curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh \
        | CONFIGURE=false bash; \
    mv "$HOME"/.local/bin/goose* /usr/local/bin/; \
    rm -rf /tmp/gi /tmp/*; \
    goose --version

# Non-root user whose UID/GID match the host owner of the mounted files.
RUN set -eux; \
    groupadd -g "${GID}" dev 2>/dev/null || true; \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash dev

USER dev
ENV HOME=/home/dev
WORKDIR /work

# goose is the entrypoint; `docker run ... session` to start an interactive run.
ENTRYPOINT ["goose"]
