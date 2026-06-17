# Scoot

<p align="center">
  <img src="assets/scoot-infographic.png" alt="Scoot — local-first AI agent daemon and CLI in pure Zig, showing the ReACT loop, built-in tools, and execution policies" width="100%">
</p>

Scoot is a lightweight AI agent daemon and CLI written in Zig. It runs local or remote OpenAI-compatible model backends through a defensive ReACT loop:

1. ask the model for one structured step,
2. validate the step,
3. pass it through execution policy,
4. run the selected tool,
5. write audit/session data,
6. feed the observation back to the model.

## Core Capabilities

- CLI and REPL execution.
- Built-in tools for shell, files, search/glob, and HTTP.
- Execution policies: `guarded`, `readonly`, `unrestricted`.
- Local skills with progressive disclosure.
- Scheduled jobs with unattended `readonly` safety.
- JSONL sessions and audit logs.
- TOML/JSON config and secret loading from env, token file, or credential command.

## Quick Start

```sh
zig build
zig build test
./zig-out/bin/scoot config
./zig-out/bin/scoot -e "count Zig files in this repository"
```

## Runtime Directory

Scoot uses `~/.scoot` by default. Set `SCOOT_HOME` to isolate test environments.

```text
~/.scoot/
  config.toml
  token
  skills/
  logs/
  state/
```

Start from `config.example.toml`.

