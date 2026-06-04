# Docker-Agent

Two Docker images for agentic development:

1. **`agentic-dev-base`** — a language/tooling base image (Rust, Node.js, Bun, Python3, plus the common Unix toolkit).
2. **`agentic-claude`** — the base image plus the Claude Code CLI as its entrypoint, designed to run against a bind-mounted codebase and a bind-mounted Claude config.

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

Runs as a non-root `dev` user whose UID/GID are set at build time to match the host owner of mounted files (no root-owned droppings).

## Build

```bash
# 1. Base image
docker build -t agentic-dev-base:latest .

# 2. Claude image (UID/GID match your host user)
docker build -f Dockerfile.claude \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  -t agentic-claude:latest .
```

Optional build args for `Dockerfile.claude`:

- `RTK_TAG` — rtk release tag to compile (default `v0.42.0`).
- `UID` / `GID` — owner of mounted files (default `1000`).

## Run

Use the helper script:

```bash
./run-claude.sh [-c CONFIG_DIR] [-w WORK_DIR] [-- <claude args>]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-c CONFIG_DIR` | Claude config dir mounted to `/home/dev/.claude` | `~/.claude` |
| `-w WORK_DIR` | Codebase mounted to `/work` | current directory |
| `-- …` | Everything after `--` is passed to `claude` | — |

Examples:

```bash
./run-claude.sh                                   # host config + current dir
./run-claude.sh -w ~/code/myproj                  # a different repo
./run-claude.sh -c ~/.claude-sandbox -w /tmp/x    # throwaway config + repo
./run-claude.sh -- --version                      # pass args through to claude
```

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
