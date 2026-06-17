# Scoot

<p align="center">
  <img src="assets/scoot-infographic.png" alt="Scoot — local-first AI agent daemon and CLI in pure Zig, showing the ReACT loop, built-in tools, and execution policies" width="100%">
</p>

Scoot is a lightweight, local-first AI agent **daemon and CLI** written in pure
Zig. It drives an OpenAI-compatible model backend through a defensive
**ReACT loop**, validates every structured step the model produces, runs local
tools behind **execution-policy gates**, and records each step as auditable
local state.

It is built for plain-text environments — servers, containers, CI runners,
embedded Linux — where you want an automatable agent that is small, predictable,
and fully inspectable, with **no GUI, no cloud sync, and no plaintext secrets**.

## How It Works

Every turn runs the same defensive loop:

1. **Ask** the model for exactly one structured step (`thought` + `action` + `action_input`).
2. **Validate** the step against a strict JSON schema (never execute free-form text).
3. **Gate** the action through the active execution policy (`guarded` / `readonly` / `unrestricted`).
4. **Run** the selected built-in tool inside a sandbox with a hard timeout.
5. **Audit** the action and write it to the session transcript and audit log.
6. **Observe** — feed the tool's output back to the model as the next observation.

The loop repeats until the model emits a `final` answer or hits `max_turns`.

## Core Capabilities

- **Two entry points** — one-shot `scoot -e "<goal>"` and an interactive REPL.
- **Ten built-in actions** — `bash`, `file_read`, `file_write`, `file_edit`,
  `grep`, `glob`, `http_request`, `skill`, `parallel`, and `final`. The
  structured tools work without external commands, so they behave identically on
  stripped-down systems. See [Built-in Tools](tools.md).
- **Three execution policies** — `guarded` (interactive tripwire), `readonly`
  (fail-closed), and `unrestricted` (audited but unlimited), plus opt-in
  hardening for write-confinement and SSRF. See [Execution Policy & Security](policy.md).
- **Local skills** with progressive disclosure — task-specific instruction packs
  discovered from the project and user directories, read through a native,
  read-only `skill` action. See [Skills](skills.md).
- **Scheduling & daemon mode** — unattended jobs that always run with
  fail-closed `readonly` safety unless you opt into more. See [Scheduling & Daemon](scheduling.md).
- **Auditable state** — sessions and audit events persisted as append-only
  JSONL. See [Sessions & Audit](sessions.md).
- **Flexible config & secrets** — TOML first, JSON fallback, secrets loaded from
  an env var, a `0600` token file, or a credential command — never inline. See
  [Configuration](configuration.md).

## Quick Start

```sh
# 1. Build (Zig 0.16+).
zig build
zig build test

# 2. Point Scoot at a backend (defaults to a local Ollama-compatible endpoint).
export OPENAI_API_KEY="sk-..."          # only if your backend needs a key

# 3. Inspect the resolved runtime and health.
./zig-out/bin/scoot config
./zig-out/bin/scoot doctor

# 4. Run a one-shot goal, or start the REPL.
./zig-out/bin/scoot -e "count the Zig source files in this repository"
./zig-out/bin/scoot            # interactive REPL; /exit to leave
```

New to Scoot? Read [Installation](installation.md) → [Configuration](configuration.md)
→ [CLI Reference](cli.md). Want to understand what the agent can *do*? See
[Built-in Tools](tools.md) and [Execution Policy & Security](policy.md).

## Runtime Directory

Scoot keeps everything under `~/.scoot` by default. Override it with the
`--scoot-home` flag or the `SCOOT_HOME` environment variable (the flag wins).

```text
~/.scoot/
  config.toml      # configuration (config.json is the fallback)
  token            # optional 0600 API token file
  skills/          # user-level skills
  logs/            # audit / run logs (audit.jsonl)
  state/           # sessions, daemon lifecycle, scheduler state
```

Start from [`config.example.toml`](https://github.com/jamiesun/scoot/blob/main/config.example.toml) — copy it to
`~/.scoot/config.toml` and edit.

## Design Principles

Scoot is intentionally conservative. These are non-negotiable boundaries, not
preferences:

- local-first runtime state, one small binary, no GUI;
- OpenAI-compatible backends only — no provider-specific protocol sprawl;
- no plaintext secrets in committed config, logs, or audit output;
- no execution of unvalidated model output;
- skills add instructions and data, never a privileged execution path.

See the [Roadmap](roadmap.md) and [Agent Guide](agent.md) for the full set of
rules that govern how Scoot evolves.
