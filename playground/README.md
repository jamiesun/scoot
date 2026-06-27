# Scoot Playground

A complete, committed, repeatable environment for evaluating Scoot end-to-end
without touching `~/.scoot`. Unlike a personal scratch directory, this folder is
tracked in git: the config defaults, skills, Wasm tool, tasks, and scripts are
shared, while all runtime state and secrets stay local and ignored.

Chinese: see [README.zh.md](README.zh.md).

## What is committed vs ignored

Committed (the test environment):

- `config.default.toml` — default runtime config, no secrets.
- `skills/` — playground-only skills (`playground-operator`, `playground-evaluator`).
- `tools/wasm/byte-stats/` — a compute-only Wasm tool package (source + manifest/policy/schema).
- `tasks/` — prompts driving repeatable tests.
- `scripts/` — helpers, evaluation, and cleanup.
- `.env.example` — template for local secrets/overrides.

Ignored (see `.gitignore`):

- `.env` — your API key and personal backend overrides.
- `config.toml` — generated at run time from `config.default.toml` + `.env`.
- `runs/`, `logs/`, `state/`, `reports/`, `tmp/` — all runtime data.
- `tools/wasm/*/component.wasm` — built Wasm artifacts (reproducible from source).

## Setup

```sh
# 1. Build scoot (and the wasm host) from the repo root.
zig build
zig build -Dwasm-host=true   # provides scoot-wasm for the wasm_tool action

# 2. Create your local env file and fill in the API key.
cp playground/.env.example playground/.env
$EDITOR playground/.env
```

`SCOOT_PLAYGROUND_API_KEY` is required. Optionally set
`SCOOT_PLAYGROUND_BASE_URL` and `SCOOT_PLAYGROUND_MODEL` to point at your own
OpenAI-compatible endpoint; otherwise the committed default (local Ollama) is
used. The scripts source `.env` and regenerate `config.toml` automatically.

## Common commands

All scripts run with `SCOOT_HOME=playground` and the repo's `zig-out/bin/scoot`.

```sh
playground/scripts/check-backend.sh           # verify the backend answers
playground/scripts/build-wasm-tools.sh        # build + validate the Wasm tool
playground/scripts/policy-dry-runs.sh readonly# fixed policy dry-runs
playground/scripts/run-task.sh playground/tasks/smoke.txt
playground/scripts/run-mcp-server.sh          # foreground local MCP echo server
playground/scripts/recall-smoke.sh            # best-effort recall probe (verifies a real recall action when dispatched)
playground/scripts/state-brief.sh             # compact state + audit counts
playground/scripts/evaluate.sh                # full evaluation -> reports/*.md
playground/scripts/clean.sh                   # wipe runtime state, keep .env
```

## Full evaluation

`evaluate.sh` is the one-shot suite. It:

1. prints resolved config and discovered skills,
2. builds and validates the `byte-stats` Wasm package,
3. checks backend reachability,
4. runs fixed policy dry-runs,
5. runs every task prompt (skill use, write tools, `wasm_tool`, `http_request`,
   `parallel`, policy, audit),
6. exercises `mcp_call` against a self-managed local MCP server,
7. runs a best-effort `recall` probe (verifies a real recall action when the
   model dispatches one; non-fatal),
8. summarizes audit/session state,
9. writes a timestamped report to `playground/reports/<stamp>-evaluation.md`.

The `playground-evaluator` skill wraps this flow so an agent run can drive the
evaluation, summarize the report, and reset state on request.

## Reset for a fresh run

```sh
playground/scripts/clean.sh
```

Removes `runs/`, `logs/`, `state/`, `reports/`, `tmp/`, the generated
`config.toml`, and built `component.wasm` files. It keeps `.env` and every
committed asset, so you can re-run from a clean slate immediately.

## Coverage map

| Surface | How it is tested |
| --- | --- |
| Skills (progressive disclosure) | `playground-operator` / `playground-evaluator` via the `skill` action |
| Built-in read tools | `tasks/smoke.txt`, `tasks/policy_guard.txt` (grep/glob/outline/file_read) |
| Built-in write tools | `tasks/file_write.txt` (`file_write` + `file_read`), `tasks/file_edit.txt` (`file_edit`) under `guarded` |
| Execution policy | `policy-dry-runs.sh`, `tasks/policy_guard.txt` |
| `http_request` | `tasks/http_request.txt` (allowed external GET under `guarded`; loopback deny via `policy-dry-runs.sh`) |
| `recall` | `tasks/recall.txt`, best-effort probe via `recall-smoke.sh` (verifies a real recall action when dispatched) |
| `parallel` | `tasks/parallel.txt` (bounded read-only fan-out: `file_read` + `grep`) |
| `wasm_tool` | `tasks/wasm_tool.txt` against `tools/wasm/byte-stats` |
| `mcp_call` | `tasks/mcp_echo.txt` against `playground-echo` server |
| Audit / sessions | `state-brief.sh`, `tasks/state_audit.txt` |
| Schedule | `[[schedule.jobs]]` in `config.default.toml` (disabled by default) |
