# Scoot

English | [中文](docs/README.zh.md)

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
./zig-out/bin/scoot skills pack docs/examples/skills/minimal minimal.scoot-skill.tar
./zig-out/bin/scoot schedule list
./zig-out/bin/scoot -e "count Zig source files in this repository"
./zig-out/bin/scoot --trace -e "count Zig source files in this repository"
```

`--trace` is for one-shot CLI debugging. It prints the ReACT execution trace to stderr while keeping the final answer on stdout.

`doctor` performs local health checks without printing secrets. `--scoot-home` overrides the runtime directory for isolated tests. `policy check` dry-runs a tool action against `guarded`, `readonly`, or `unrestricted` policy mode.

`skills check [dir]` validates local skill structure without executing skill scripts. A valid skill directory contains `SKILL.md` with YAML front matter including non-empty `name` and `description`; unsupported compatibility declarations fail clearly until Scoot defines those gates.

`skills pack <dir> [out.tar]` validates a skill and exports a tar package with a `.scoot-skill.json` review manifest. It includes regular non-hidden files, rejects unsupported file types such as symlinks, and does not execute scripts or grant policy bypasses.

A minimal template is available at [docs/examples/skills/minimal/SKILL.md](docs/examples/skills/minimal/SKILL.md).

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

- Chinese README: [docs/README.zh.md](docs/README.zh.md)
- English roadmap: [docs/ROADMAP.md](docs/ROADMAP.md)
- Chinese roadmap: [docs/ROADMAP.zh.md](docs/ROADMAP.zh.md)
- English agent guide: [AGENT.md](AGENT.md)
- Chinese agent guide: [docs/AGENT.zh.md](docs/AGENT.zh.md)
- mdBook source: [book/](book/)

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
