# Scoot

English | [中文](docs/README.zh.md)

<p align="center">
  <img src="docs/assets/scoot-infographic.png" alt="Scoot — local-first AI agent daemon and CLI in pure Zig, showing the ReACT loop (model, validate, policy, tools, audit), built-in tools, and guarded/readonly/unrestricted execution policies" width="100%">
</p>

Scoot is a lightweight AI agent daemon and CLI written in pure Zig. It runs in a plain text environment, talks to an OpenAI-compatible model backend, validates structured model steps, executes local tools through policy gates, and records every step as auditable local state.

The design is intentionally conservative:

- local-first runtime state,
- one small binary,
- no GUI,
- no provider-specific protocol sprawl,
- no plaintext secrets in committed config,
- no execution of unvalidated model output.

## Status

The core foundation is usable:

- one-shot `scoot -e` and interactive REPL run the ReACT loop,
- built-in tools cover shell, file operations, search/glob, and HTTP,
- execution policies support `guarded`, `readonly`, and `unrestricted`,
- skills are discovered locally with progressive disclosure,
- scheduled jobs run with effective `readonly` mode by default,
- sessions and audit events are persisted as JSONL,
- config supports TOML first, JSON fallback, and secret loading from env/file/command.

## Requirements

- Zig 0.16.0 or newer.

## Build And Run

```sh
zig build
zig build test
zig build run -- --version
```

Run the built binary:

```sh
./zig-out/bin/scoot --help
./zig-out/bin/scoot config
./zig-out/bin/scoot doctor
./zig-out/bin/scoot --scoot-home /tmp/scoot-test doctor
./zig-out/bin/scoot policy check bash "rm -rf /" --mode guarded
./zig-out/bin/scoot skills
./zig-out/bin/scoot skills check
./zig-out/bin/scoot skills check docs/examples/skills/minimal
./zig-out/bin/scoot skills check docs/examples/skills/metadata
./zig-out/bin/scoot skills pack docs/examples/skills/minimal minimal.scoot-skill.tar
./zig-out/bin/scoot wasm-tools check path/to/tool
./zig-out/bin/scoot schedule list
./zig-out/bin/scoot daemon status
./zig-out/bin/scoot daemon run --ticks 1
./zig-out/bin/scoot daemon stop
./zig-out/bin/scoot -e "count Zig source files in this repository"
./zig-out/bin/scoot --retries 4 -e "count Zig source files in this repository"
./zig-out/bin/scoot --trace -e "count Zig source files in this repository"
```

`--trace` is for debugging. In both `-e` one-shot and interactive REPL mode it prints the ReACT execution trace to stderr while keeping the final answer (or conversation) on stdout. The trace emits a live progress marker *before* each blocking step — `thinking:` before calling the model and `running: <tool>` before executing a tool — so you can see what the agent is doing while it waits instead of the trace appearing to freeze. `--retries` controls how many times `-e` retries temporary backend failures such as rate limits and 5xx responses.

`doctor` performs local health checks without printing secrets. `--scoot-home` overrides the runtime directory for isolated tests. `policy check` dry-runs a tool action against `guarded`, `readonly`, or `unrestricted` policy mode.

`skills check [dir]` validates local skill structure without executing skill scripts. A valid skill directory contains `SKILL.md` with YAML front matter including non-empty `name` and `description`; optional `capabilities`, `allowed_tools`, and `scope` metadata is validated for review. Unsupported compatibility declarations fail clearly until Scoot defines those gates.

`skills pack <dir> [out.tar]` validates a skill and exports a tar package with a `.scoot-skill.json` review manifest. It includes regular non-hidden files, rejects unsupported file types such as symlinks, and does not execute scripts or grant policy bypasses.

Templates are available at [docs/examples/skills/minimal/SKILL.md](docs/examples/skills/minimal/SKILL.md) and [docs/examples/skills/metadata/SKILL.md](docs/examples/skills/metadata/SKILL.md).

`wasm-tools check <dir>` validates a local Wasm tool package boundary: `manifest.toml`, `policy.toml`, referenced JSON schemas, and safe relative paths. It is static validation only and never loads or executes Wasm.

`daemon run` is the foreground long-running mode for scheduled jobs. It writes `state/daemon.json` and `state/daemon.pid`, handles SIGTERM/SIGINT, and preserves the scheduled-job safety rule that unattended `guarded` jobs run as effective `readonly`.

The agent can also use a bounded `parallel` action for 1-4 independent read-only tool calls. It preserves observation order, rejects shell/write/nested calls, and still routes every child call through the normal policy gate.

## Configuration

Use `--scoot-home` or `SCOOT_HOME` to choose a runtime directory. `--scoot-home` has priority over the environment variable. By default Scoot uses `~/.scoot`.

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

Start from [config.example.toml](config.example.toml).

## Documentation

The **User Guide** (bilingual mdBook under [`book/`](book/)) is the comprehensive,
task-oriented documentation. Source chapters:

- [Introduction](book/en/src/index.md)
- [Installation](book/en/src/installation.md) — build, install, backend setup.
- [Configuration](book/en/src/configuration.md) — every config key, with defaults.
- [CLI Reference](book/en/src/cli.md) — every command and flag.
- [Built-in Tools](book/en/src/tools.md) — the ten agent actions.
- [Execution Policy & Security](book/en/src/policy.md) — modes, hardening, threat model.
- [Skills](book/en/src/skills.md) — authoring and using skills.
- [Scheduling & Daemon](book/en/src/scheduling.md) — unattended jobs.
- [Sessions & Audit](book/en/src/sessions.md) — local state formats.
- [Wasm Tool Packages](book/en/src/wasm-tools.md) — package boundary.
- [Troubleshooting & FAQ](book/en/src/troubleshooting.md)

Chinese chapters live under [`book/zh/src/`](book/zh/src/).

Reference documents:

- Chinese README: [docs/README.zh.md](docs/README.zh.md)
- English roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · Chinese: [docs/ROADMAP.zh.md](docs/ROADMAP.zh.md)
- English agent guide: [AGENT.md](AGENT.md) · Chinese: [docs/AGENT.zh.md](docs/AGENT.zh.md)
- Daemon lifecycle: [docs/DAEMON.md](docs/DAEMON.md) · [docs/DAEMON.zh.md](docs/DAEMON.zh.md)
- Skills: [docs/SKILLS.md](docs/SKILLS.md) · [docs/SKILLS.zh.md](docs/SKILLS.zh.md)
- Wasm tool packages: [docs/WASM_TOOLS.md](docs/WASM_TOOLS.md) · [docs/WASM_TOOLS.zh.md](docs/WASM_TOOLS.zh.md)

Build the docs locally:

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
```

## Repository Layout

```text
src/                 Zig source
src/tools/           Built-in tools
docs/                Project documents and translated docs
book/en/             English mdBook site
book/zh/             Chinese mdBook site
.github/workflows/   CI, release, and documentation workflows
```

## Documentation Policy

Project documentation must stay bilingual. Root documentation is English by default. Chinese documents live under `docs/` with `.zh.md` suffixes. When changing English docs, update the Chinese counterpart in the same change.

## Release Artifacts

Tagged releases publish:

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

Each artifact includes a `.tar.gz` archive and a `.sha256` checksum.

## License

MIT. See [LICENSE](LICENSE).
