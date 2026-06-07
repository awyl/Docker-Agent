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
| `rtk` | token-compressing proxy (prebuilt release binary, pinned via `RTK_TAG`) — shared by every agent |
| `sccache` | Rust compiler cache (via `cargo binstall`, pinned via `SCCACHE_VERSION`); wired as `RUSTC_WRAPPER`, cache shared across agents |

Image size: ~1.7 GB. Caches, docs, and man pages are stripped to keep it lean.

**Rust compiler cache (sccache).** The base image bundles
[sccache](https://github.com/mozilla/sccache) and sets `RUSTC_WRAPPER=sccache`, so
every cargo build in any agent container is cached. The cache persists on the host
at `~/.cache/sccache` (override with `SCCACHE_DIR`) and is bind-mounted into each
container, so it is shared across all agents and with host builds. Check hit rates
inside a container with `sccache --show-stats`.

### `agentic-claude`

Adds, on top of the base:

- `@anthropic-ai/claude-code` — the CLI (entrypoint).
- `ccstatusline` — referenced by the host `settings.json` status line.

`rtk` (the token-compressing proxy the host `PreToolUse(Bash)` hook calls via
`rtk hook claude`) lives in `agentic-dev-base`, so this and every other agent
image inherit it.

The repo ships a default Claude config in `claude-default-config/` (model,
security deny rules, statusline, the `rtk` Bash hook, plugin set + marketplaces).
`run-claude.sh` seeds it into any config dir that has no config yet — i.e. lacks
`settings.json` — covering `-i` isolated, the default, and custom `-c` dirs.
Existing config is never overwritten (it copies no-clobber, so a seeded
`.credentials.json` survives). Credentials, the context7 MCP server (API key),
and runtime state are intentionally excluded from the bundle.

### `agentic-pi`

Adds `@earendil-works/pi-coding-agent` (binary `pi`) on top of the base.

The repo ships a default Pi config in `pi-default-config/` (plugin list,
keybindings, caveman + magic-context settings, the `rtk` extension). `run-pi.sh`
seeds it into any config dir that has no config yet — i.e. lacks
`agent/settings.json` — covering `-i` isolated, the default `~/.pi`, and custom
`-c` dirs. Existing config is never overwritten (it copies no-clobber, so a
seeded `auth.json` survives). Auth, installed npm packages, cloned plugin git
repos, sessions, and runtime DBs are intentionally excluded from the bundle.

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
- `RTK_TAG` — rtk release tag to download as a prebuilt binary (default `v0.42.0`), base image.
- `SCCACHE_VERSION` — sccache version for `cargo binstall`, bare semver (default `0.8.2`), base image.
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

By default each script uses an **isolated** per-project config dir; the host
config dir below is used only with `-H`:

| Script | Agent | Host config dir (`-H`) |
|--------|-------|------------------------|
| `./run-claude.sh` | Claude Code | `~/.claude` (+ `~/.claude.json`) |
| `./run-pi.sh` | Pi | `~/.pi` |
| `./run-goose.sh` | goose | `~/.config/goose` |
| `./run-hermes.sh` | Hermes | `~/.hermes` |

```bash
./run-claude.sh [-i | -H | -c CONFIG_DIR] [-w WORK_DIR] [-n NAME] [--edit] \
                [--mem-from | --mem-to] [-- <agent args>]
```

| Flag | Meaning | Default |
|------|---------|---------|
| _(none)_ | Isolated per-project config in `~/.docker-agent/<work-dir-name>/<agent>`, seeded from the host so it stays logged in | **the default** |
| `-i` | Force the isolated config (explicit form of the default) | — |
| `-H` | Use the host config dir directly (the agent default in the table above) | — |
| `-c CONFIG_DIR` | Use a custom config dir | — |
| `--edit` | Open the resolved config dir in your editor (`$VISUAL`/`$EDITOR`/`nvim`/`vi`) and exit — no container | — |
| `--mem-from` | Copy the work-dir memory **from** host into the config dir, then exit — no container (Claude only) | — |
| `--mem-to` | Copy the work-dir memory **to** host from the config dir, then exit — no container (Claude only) | — |
| `-w WORK_DIR` | Codebase mounted to `/work` | current directory |
| `-n NAME` | Reuse a persistent named container instead of a throwaway one | — |
| `-- …` | Everything after `--` is passed to the agent | — |

`-i`, `-H` and `-c` are mutually exclusive. Each invocation defaults to an
isolated, per-project config dir; pass `-H` to use your live host config instead.

`--edit` resolves and seeds the config dir the script would mount (respecting
`-i`/`-H`/`-c`), opens it in your editor, and exits without launching a
container.

`--mem-from` / `--mem-to` (Claude only) copy the working dir's memory between the
host Claude config and the resolved config dir, then exit. Claude keys memory by
cwd, and the container's cwd is always `/work` (slug `-work`), so its memory lives
under `<config-dir>/projects/-work/memory` while the host's lives under
`~/.claude/projects/<host-slug>/memory`. `--mem-from` seeds the container from the
host; `--mem-to` writes the container's memory back. Memory dir only (no session
logs); point-in-time copy, last writer wins. The two are mutually exclusive and
respect `-i`/`-H`/`-c` and `-w`.

`run-pi.sh`, `run-goose.sh`, and `run-hermes.sh` take the same flags (except the
Claude-only `--mem-from`/`--mem-to`).
`run-goose.sh` with no extra args starts an interactive `goose session`;
`run-hermes.sh` with no args starts the interactive Hermes CLI.

Examples:

```bash
./run-claude.sh                                   # isolated config + current dir (default)
./run-claude.sh -H                                # host ~/.claude config
./run-claude.sh -w ~/code/myproj                  # isolated config, a different repo
./run-claude.sh -c ~/.claude-sandbox -w /tmp/x    # custom config + repo
./run-claude.sh -n myproj                         # create/reuse "myproj"
./run-claude.sh --mem-from                        # seed container memory from host
./run-claude.sh --mem-to                          # save container memory back to host
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
| `SCCACHE_CACHE` (`~/.cache/sccache`) | `/home/dev/.cache/sccache` | shared Rust compiler cache, read-write |

The trust/config JSON convention is `<config-dir>.json` — so `~/.claude` pairs
with `~/.claude.json`, and `~/.claude-sandbox` pairs with `~/.claude-sandbox.json`
(auto-created on first run). A custom config dir is created if it doesn't exist.

## Plugins

The Claude image bakes in **no** plugins. They load at runtime from the mounted
config dir, so the container sees exactly the plugins your host has enabled. A
fresh isolated config is seeded from `claude-default-config/` (see above), which
enables (in `settings.json`):

- **superpowers** — skills + SessionStart hook.
- **caveman** — output-compression mode hooks.
- **context-mode** — MCP server + tool-routing hooks.
- **code-simplifier** — code cleanup skill.
- **rust-analyzer-lsp** — drives the `rust-analyzer` binary baked into the base.

`caveman` and `context-mode` come from GitHub marketplaces declared in the
seeded `settings.json`; the rest come from the built-in `claude-plugins-official`
marketplace. context-mode re-deploys its own SessionStart cache-heal hook on
first run, so the bundle omits it.

Hooks that call host binaries are satisfied in the image: `rtk` (Bash hook),
`ccstatusline` (status line), `rust-analyzer` (LSP), plus Node for the
context-mode hooks/MCP server.

## Notes & caveats

- **Credentials exposure.** The default isolated config is *seeded* with a copy
  of your host credentials (e.g. `~/.claude/.credentials.json`) so the agent
  stays logged in — that copy lives in `~/.docker-agent/<proj>/<agent>` and any
  code the agent runs can read it. `-H` exposes the live host credentials
  directly. Use an API key if you want no credential material in the container.
- **Trust prompt.** The repo mounts at `/work`, which differs from its host
  path. Claude trusts directories by absolute path, so the first run shows a
  trust prompt. Accept once — it persists into the mounted config JSON.
- **Default config is isolated, not shared.** By default each project gets its
  own config dir, so edits the agent makes (history, sessions, trust) stay
  per-project. Use `-H` to share — and write back to — your live host config.
