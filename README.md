# Docker-Agent

Docker images for agentic development:

1. **`agentic-dev-base`** — a language/tooling base image (Rust, Node.js, Bun, Python3, plus the common Unix toolkit).
2. **`agentic-claude`** — base + the Claude Code CLI as entrypoint.
3. **`agentic-pi`** — base + the [Pi coding agent](https://pi.dev) as entrypoint.
4. **`agentic-goose`** — base + the [goose](https://github.com/aaif-goose/goose) agent as entrypoint.
5. **`agentic-hermes`** — base + the [Hermes agent](https://github.com/NousResearch/hermes-agent) as entrypoint.

Each agent image runs against a bind-mounted codebase and a bind-mounted config
dir, as a non-root `dev` user whose UID/GID match the host owner of mounted files.

## Contents

### `agentic-dev-base` (Debian 13 "trixie" slim)

| Tool | Version (at build time) |
|------|-------------------------|
| Rust | latest stable + `clippy`, `rustfmt`, `rust-analyzer` |
| Node.js | 22.x LTS (NodeSource) |
| Bun | latest |
| Python | 3.13 (distro) |
| uv | latest (from `ghcr.io/astral-sh/uv`) |
| Tooling | `git`, `ripgrep`, `fd`, `jq`, `fzf`, `bat`, `neovim`, `curl`, `wget`, `unzip`, build-essential |

Image size: ~1.7 GB. Caches, docs, and man pages are stripped to keep it lean.

### `agentic-claude`

Adds, on top of the base:

- `@anthropic-ai/claude-code` — the CLI (entrypoint).
- `ccstatusline` — referenced by the host `settings.json` status line.
- `rtk` — the token-compressing proxy invoked by the host `PreToolUse(Bash)` hook (`rtk hook claude`). Built from source, pinned via the `RTK_TAG` build arg.

### `agentic-pi`

Adds `@earendil-works/pi-coding-agent` (binary `pi`) on top of the base.

### `agentic-goose`

Adds the `goose` CLI on top of the base. Built with `GOOSE_DISABLE_KEYRING=1`
so it uses file-based secrets (`~/.config/goose/secrets.yaml`) instead of a
system keyring, which doesn't exist in a container.

### `agentic-hermes`

Adds the [Hermes agent](https://github.com/NousResearch/hermes-agent) (binary
`hermes`) on top of the base. Hermes is a Python app, so it's installed into an
isolated venv at `/opt/hermes` (Python 3.11 via `uv`, with the `.[all]` extra
and `ffmpeg`) and the launcher is symlinked onto the global `PATH`. The venv is
kept out of `~/.hermes` because that dir is the runtime-mounted config. Pin the
clone with the `HERMES_REF` build arg (default `main`).

## Build

```bash
# 1. Base image
docker build -t agentic-dev-base:latest .

# 2. Agent images (UID/GID match your host user)
docker build -f Dockerfile.claude \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t agentic-claude:latest .
docker build -f Dockerfile.pi \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t agentic-pi:latest .
docker build -f Dockerfile.goose \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t agentic-goose:latest .
docker build -f Dockerfile.hermes \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t agentic-hermes:latest .
```

Build args:

- `UID` / `GID` — owner of mounted files (default `1000`), all agent images.
- `RTK_TAG` — rtk release tag to compile (default `v0.42.0`), `Dockerfile.claude` only.
- `HERMES_REF` — git ref of hermes-agent to clone (default `main`), `Dockerfile.hermes` only.

## Install (optional)

To run the helper scripts from any directory, symlink them onto your `PATH`:

```bash
./install.sh        # symlinks into ~/.local/bin (override with BIN=...)
```

This creates:

| Command | Script |
|---------|--------|
| `agent-claude` | `run-claude.sh` |
| `agent-pi` | `run-pi.sh` |
| `agent-goose` | `run-goose.sh` |
| `agent-hermes` | `run-hermes.sh` |

Then, from anywhere:

```bash
cd ~/code/myproj && agent-claude
```

The commands are **symlinks**, so editing a `run-*.sh` in the repo updates the
installed command immediately; moving or deleting the repo breaks the links.
`./install.sh` only puts the scripts on `PATH` — the images must already be
built (see **Build**). Remove the links with `./uninstall.sh`.

If `~/.local/bin` isn't on your `PATH`, `install.sh` prints how to add it
(`fish_add_path ~/.local/bin` for fish).

## Run

One helper script per agent — same flags, different defaults. Run them in place
with `./run-<agent>.sh`, or as `agent-<agent>` after `./install.sh`:

| Script | Agent | Default config mount |
|--------|-------|----------------------|
| `./run-claude.sh` | Claude Code | `~/.claude` (+ `~/.claude.json`) |
| `./run-pi.sh` | Pi | `~/.pi` |
| `./run-goose.sh` | goose | `~/.config/goose` |
| `./run-hermes.sh` | Hermes | `~/.hermes` |

```bash
./run-claude.sh [-c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [-- <agent args>]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-c CONFIG_DIR` | Agent config dir mounted into the container | agent's default above |
| `-w WORK_DIR` | Codebase mounted to `/work` | current directory |
| `-n NAME` | Reuse a persistent named container instead of a throwaway one | — |
| `-- …` | Everything after `--` is passed to the agent | — |

`run-pi.sh`, `run-goose.sh`, and `run-hermes.sh` take the same flags.
`run-goose.sh` with no extra args starts an interactive `goose session`;
`run-hermes.sh` with no args starts the interactive Hermes CLI.

Examples:

```bash
./run-claude.sh                                   # host config + current dir
./run-claude.sh -w ~/code/myproj                  # a different repo
./run-claude.sh -c ~/.claude-sandbox -w /tmp/x    # throwaway config + repo
./run-claude.sh -n myproj                         # create/reuse "myproj"
./run-claude.sh -- --version                      # pass args through to claude
```

### Named (persistent) containers

By default each run uses a throwaway container (`--rm`, gone on exit). With
`-n NAME` the container persists and is reused:

- **First call** with a name creates an idle container (it runs `sleep
  infinity` in the background) with the mounts from `-c`/`-w`, then execs
  `claude` into it.
- **Later calls** with the same name re-enter that same container — no second
  container is created.
- Because mounts are fixed when the container is created, `-c`/`-w` only take
  effect on the first call. Remove it with `docker rm -f NAME` to recreate with
  new mounts.

### What gets mounted

| Host | Container | Notes |
|------|-----------|-------|
| `CONFIG_DIR` (`~/.claude`) | `/home/dev/.claude` | plugins, skills, hooks, history, **credentials** |
| `<CONFIG_DIR>.json` (`~/.claude.json`) | `/home/dev/.claude.json` | project/trust state, MCP servers, enabled plugins |
| `WORK_DIR` (`$PWD`) | `/work` | your codebase, read-write |

The trust/config JSON convention is `<config-dir>.json` — so `~/.claude` pairs
with `~/.claude.json`, and `~/.claude-sandbox` pairs with `~/.claude-sandbox.json`
(auto-created on first run). A custom config dir is created if it doesn't exist.

## Plugins

The Claude image bakes in **no** plugins. They load at runtime from the mounted
config dir, so the container sees exactly the plugins your host has enabled.
Currently enabled (in `~/.claude/settings.json`):

- **superpowers** — skills + SessionStart hook.
- **caveman** — output-compression mode hooks.
- **context-mode** — MCP server + tool-routing hooks.
- **rust-analyzer-lsp** — drives the `rust-analyzer` binary baked into the base.

Hooks that call host binaries are satisfied in the image: `rtk` (Bash hook),
`ccstatusline` (status line), `rust-analyzer` (LSP), plus Node for the
context-mode hooks/MCP server.

## Notes & caveats

- **Credentials exposure.** Mounting `~/.claude` shares your live Claude
  credentials (`~/.claude/.credentials.json`) with the container. Any code the
  agent runs inside can read them. Use a separate config dir (`-c`) or an API
  key if you want isolation.
- **Trust prompt.** The repo mounts at `/work`, which differs from its host
  path. Claude trusts directories by absolute path, so the first run shows a
  trust prompt. Accept once — it persists into the mounted config JSON.
- **Config is shared, not copied.** Edits Claude makes (history, sessions,
  trust) write back to the host config dir.
