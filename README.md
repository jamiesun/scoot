# Scoot

English | [中文](docs/README.zh.md)

<p align="center">
  <img src="docs/assets/scoot-infographic.png" alt="Scoot - local-first AI agent daemon and CLI in pure Zig" width="100%">
</p>

Scoot is a local-first AI agent CLI and daemon written in pure Zig. It talks to
an OpenAI-compatible model backend, asks the model for structured ReACT steps,
runs local tools through policy gates, and stores sessions plus audit events on
your machine.

Use it when you want a small terminal agent that can inspect a project, edit
files, run bounded commands, use local skills, or execute scheduled read-only
jobs without pulling in a large app stack.

## Why Scoot

| Need | Scoot's answer |
| --- | --- |
| Run an agent from a terminal | One self-contained binary with one-shot and REPL modes. |
| Keep state local | Config, sessions, skills, logs, and daemon state live under `~/.scoot` by default. |
| Use existing model infrastructure | Any OpenAI-compatible `chat/completions` backend works, local or hosted. |
| Avoid accidental damage | Tool calls pass through `guarded`, `readonly`, or `unrestricted` policy modes. |
| Audit what happened | Every agent step and tool decision is persisted as local JSONL state. |
| Extend behavior | Local skills are discovered from directories and read progressively when needed. |

## Why Zig

Single-binary distribution is not unique to Zig; Go and Rust can do that too.
Scoot uses Zig because its advantages line up with the way this agent is meant
to be deployed:

1. **Tiny standalone footprint.** Scoot is intended to run as a small local
   utility, sidecar, or embedded agent on machines where installing a language
   runtime, package tree, or service stack is unnecessary friction.
2. **Controlled memory for constrained devices.** Zig keeps allocation visible
   in the code, which fits a long-running daemon that may live on low-memory
   Linux boxes, edge devices, NAS hosts, or other resource-limited systems.
3. **Cross-platform migration with low dependency drag.** Zig's
   cross-compilation and libc handling make it easier to move the same agent
   across Linux/macOS targets and CPU architectures while keeping the external
   dependency surface small.

## Design Philosophy

Scoot is intentionally conservative. It optimizes for safety, auditability,
local-first operation, small deployment surface, and long-running stability
before feature breadth.

Some apparent limitations are deliberate choices:

- no GUI, because the interface should stay scriptable and inspectable;
- no provider-specific protocol sprawl, because the model boundary is
  OpenAI-compatible;
- no pretending `guarded` is a sandbox, because unattended work should use
  `readonly` and OS isolation;
- no native plugin runtime, because skills should extend behavior without
  expanding the trusted binary surface;
- foreground daemon mode, because supervisors such as `systemd` should own
  backgrounding, restart, logs, and shutdown.

The iron law is simple: validate model output, gate every effect through policy,
timeout external work, keep secrets out of text artifacts, and keep state local.
See [Design Philosophy](book/en/src/design-philosophy.md) for the full goals,
non-goals, and hard boundaries.

## Current Status

The core runtime is usable today:

- `scoot -e` for one-shot tasks and `scoot` / `scoot repl` for interactive use.
- Built-in tools for shell, file read/write/edit, regex search, globbing, file
  outlines, HTTP, skills, transcript recall, and bounded parallel read calls.
- Policy modes: `guarded` by default, `readonly` for fail-closed runs, and
  `unrestricted` when you deliberately accept full local access.
- TOML-first configuration with JSON fallback and secret loading from an
  environment variable, file, or command.
- Scheduled jobs and foreground daemon mode, with unattended `guarded` jobs
  coerced to effective `readonly`.
- Local session and audit logs in JSONL.

## Quick Start

### 1. Install Or Build

Install the latest release for your host:

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | sh
```

Or install to a user-writable directory:

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_DIR="$HOME/.local/bin" sh
```

The installer detects your OS/CPU, downloads the matching latest release asset
and `.sha256` file, verifies the archive, and installs `scoot`.

For resource-constrained hosts, install the explicit small build:

```sh
curl -fsSL https://raw.githubusercontent.com/jamiesun/scoot/main/install.sh | env SCOOT_INSTALL_FLAVOR=small sh
```

The default release keeps Zig runtime safety checks. The small release minimizes
binary size and disables those checks, so use it when footprint matters more
than fail-fast diagnostics.

To build from source instead, use **Zig 0.16.0 or newer**:

```sh
zig build
zig build test
./zig-out/bin/scoot --version
```

For an optimized binary:

```sh
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSmall
```

### 2. Configure

Scoot uses `~/.scoot` by default. Start from the sample config:

```sh
mkdir -p ~/.scoot
cp config.example.toml ~/.scoot/config.toml
```

Edit `[backend]` for your OpenAI-compatible backend:

```toml
[backend]
base_url = "http://127.0.0.1:11434/v1"
model = "qwen2.5"
api_key_env = "OPENAI_API_KEY"
```

Keep tokens out of committed config. The simplest hosted-backend setup is:

```sh
export OPENAI_API_KEY="sk-..."
```

For local backends such as Ollama-compatible endpoints, you can leave the token
unset if the backend does not require one.

### 3. Verify

```sh
./zig-out/bin/scoot config
./zig-out/bin/scoot doctor
```

`config` shows the resolved runtime directory and backend with secrets redacted.
`doctor` checks local prerequisites, config loading, secret source, skills, and
audit paths without printing token values.

### 4. Run A Goal

```sh
./zig-out/bin/scoot -e "summarize this repository"
./zig-out/bin/scoot --trace -e "count Zig source files in this repository"
./zig-out/bin/scoot
```

`-e` prints only the final answer to stdout, which makes it useful in scripts.
`--trace` streams the ReACT progress to stderr with markers such as `thinking:`
and `running: <tool>`.

## Common Commands

| Command | What it does |
| --- | --- |
| `scoot` or `scoot repl` | Start the interactive REPL. |
| `scoot -e "<goal>"` | Run one goal and exit. |
| `scoot --trace -e "<goal>"` | Run one goal with execution trace on stderr. |
| `scoot config` | Show resolved config with secrets redacted. |
| `scoot doctor` | Run local health checks. |
| `scoot policy check <action> <input>` | Dry-run a tool action against a policy. |
| `scoot skills` | List discovered local skills. |
| `scoot skills check [dir]` | Validate a skill directory without executing scripts. |
| `scoot skills pack <dir> [out.tar]` | Export a reviewable skill package. |
| `scoot wasm-tools check <dir>` | Statically validate a Wasm tool package boundary. |
| `scoot schedule list` | Show configured scheduled jobs. |
| `scoot daemon run` | Run scheduled jobs in the foreground daemon loop. |

Examples:

```sh
./zig-out/bin/scoot policy check bash "rm -rf /" --mode guarded
./zig-out/bin/scoot skills check docs/examples/skills/minimal
./zig-out/bin/scoot skills pack docs/examples/skills/minimal minimal.scoot-skill.tar
./zig-out/bin/scoot wasm-tools check path/to/tool
./zig-out/bin/scoot daemon run --ticks 1
```

## Choose The Right Run Mode

Scoot has three common ways to run work. They are intentionally different:

| Mode | Goal source | Lifetime | Use when |
| --- | --- | --- | --- |
| `scoot -e "<goal>"` | The prompt on the command line. | Run now, print the final answer, exit. | A human or script wants one immediate task. |
| `scoot schedule run --ticks 1` | `[[schedule.jobs]]` in config. | Poll configured jobs once, run any that are due, exit. | An external scheduler such as cron or a systemd timer owns the timing. |
| `scoot daemon run` | `[[schedule.jobs]]` in config. | Poll forever by default (`--ticks N` makes it bounded). | Scoot owns the schedule loop and a supervisor only keeps the process alive. |

`daemon run` is not just `-e` with a different name. `-e` executes one explicit
prompt immediately. `daemon run` loads configured jobs, applies their
`every_sec`, `at_unix`, or `cron` triggers, writes daemon pid/state files, and
uses the unattended job safety rules. A supervisor such as `systemd` is useful
with `daemon run` because Scoot stays in the foreground and systemd owns
startup, restart, logs, environment, and shutdown.

## Configuration Model

Runtime files live under `~/.scoot` unless you override the directory with
`--scoot-home` or `SCOOT_HOME`. The CLI flag wins over the environment variable.

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

Configuration precedence:

```text
SCOOT_* environment overrides > config.toml > built-in defaults
```

Secrets are intentionally separate from `SCOOT_*` overrides. Scoot reads the
backend token from `backend.api_key_env` first, then `backend.api_key_file`,
then `backend.api_key_cmd`. See
[Configuration -> Environment Variable Overrides](book/en/src/configuration.md#environment-variable-overrides)
for the full table and CI examples.

## Safety Model

Scoot validates every model step before execution. Tool calls are then checked
against the active policy mode:

| Mode | Use when | Behavior |
| --- | --- | --- |
| `guarded` | Normal interactive work. | Allows ordinary work but blocks known catastrophic shell patterns. |
| `readonly` | Untrusted or unattended work. | Denies shell, writes, and network; allows confined local reads. |
| `unrestricted` | You fully trust the goal. | Allows all tool actions, still audited. |

`guarded` is the default convenience mode, not a security sandbox. Use
`readonly` for unattended jobs or goals you do not trust, and combine it with
OS-level isolation when you need strong containment.

## Built-in Capabilities

Scoot's model may only request structured actions. The built-in action set
currently covers:

- `bash` for bounded POSIX shell commands.
- `file_read`, `file_write`, and `file_edit` for file operations.
- `grep`, `glob`, and `outline` for project inspection.
- `http_request` for one bounded HTTP/HTTPS request.
- `skill` for reading trusted local skill instructions and resources.
- `recall` for retrieving exact earlier messages from the current session transcript.
- `parallel` for 1-4 independent read-only calls.
- `final` for returning the answer.

The structured file/search/HTTP tools do not require external shell commands,
which keeps Scoot useful on minimal or embedded systems.

## Documentation

The full user guide is the bilingual mdBook under [`book/`](book/):

- [Installation](book/en/src/installation.md) - build, install, backend setup.
- [Design Philosophy](book/en/src/design-philosophy.md) - goals, non-goals, and hard boundaries.
- [Configuration](book/en/src/configuration.md) - every config key and default.
- [CLI Reference](book/en/src/cli.md) - every command and flag.
- [Built-in Tools](book/en/src/tools.md) - all agent actions.
- [Execution Policy & Security](book/en/src/policy.md) - modes and threat model.
- [Skills](book/en/src/skills.md) - authoring and using skills.
- [Scheduling & Daemon](book/en/src/scheduling.md) - unattended jobs.
- [Sessions & Audit](book/en/src/sessions.md) - local state formats.
- [Wasm Tool Packages](book/en/src/wasm-tools.md) - package boundary.
- [Embedding API](book/en/src/embed-api.md) - stable Zig package surface.
- [Best Practice Cases](book/en/src/best-practices.md) - CI, operations, probes, and runbooks.
- [Troubleshooting & FAQ](book/en/src/troubleshooting.md)

Chinese chapters live under [`book/zh/src/`](book/zh/src/).

Reference documents:

- Chinese README: [docs/README.zh.md](docs/README.zh.md)
- Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) / [docs/ROADMAP.zh.md](docs/ROADMAP.zh.md)
- Agent guide: [AGENT.md](AGENT.md) / [docs/AGENT.zh.md](docs/AGENT.zh.md)
- Daemon lifecycle: [docs/DAEMON.md](docs/DAEMON.md) / [docs/DAEMON.zh.md](docs/DAEMON.zh.md)
- Skills: [docs/SKILLS.md](docs/SKILLS.md) / [docs/SKILLS.zh.md](docs/SKILLS.zh.md)
- Wasm tool packages: [docs/WASM_TOOLS.md](docs/WASM_TOOLS.md) / [docs/WASM_TOOLS.zh.md](docs/WASM_TOOLS.zh.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md) / [docs/CHANGELOG.zh.md](docs/CHANGELOG.zh.md)

Build the docs locally:

```sh
mdbook build book/en
mdbook build book/zh
mkdir -p site
cp book/site-index.html site/index.html
mkdir -p site/assets
cp docs/assets/scoot-logo.svg docs/assets/scoot-favicon.svg docs/assets/scoot-favicon.png site/assets/
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

## Release Artifacts

Tagged releases publish:

- `linux-amd64`
- `linux-arm64`
- `linux-armv7`
- `macos-amd64`
- `macos-arm64`

Each target also publishes a `-small` variant built with `ReleaseSmall`. Every
artifact includes a `.tar.gz` archive and a `.sha256` checksum. The release also
publishes `install.sh`, and each archive includes a copy of the same installer.

## Documentation Policy

Project documentation stays bilingual. Root documentation is English by
default. Chinese documents live under `docs/` with `.zh.md` suffixes. When
changing English docs, update the Chinese counterpart in the same change.

## License

MIT. See [LICENSE](LICENSE).
