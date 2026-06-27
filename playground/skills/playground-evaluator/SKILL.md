---
name: playground-evaluator
description: Run a full Scoot playground evaluation and produce a Markdown report, analyze playground audit/session state, and reset runtime data between runs while preserving .env.
---

# Playground Evaluator

Use this skill when the user asks to evaluate Scoot end-to-end in the
`playground/` environment, summarize a run, or reset the playground for a fresh
evaluation.

## Run a full evaluation

The single entry point is the evaluation script. It validates the build surface,
runs every task prompt, exercises the `wasm_tool` and `mcp_call` boundaries
(starting its own local MCP server), summarizes state, and writes a timestamped
Markdown report under `playground/reports/`:

- `playground/scripts/evaluate.sh`

Guidance:

- Run it with a single `bash` action and a generous timeout; it drives several
  agent sub-runs and may take minutes.
- The script prints the report path on the last line (`Report written: ...`).
- Read the generated report back (it is normal Markdown) to summarize results.
  Do not read `playground/logs/audit.jsonl` directly; it can contain large
  escaped observations that bloat context.

## Analyze state without bloating context

For lightweight analysis between or after runs:

- Prefer `playground/scripts/state-brief.sh` for audit event counts, session
  file counts, and recent transcript exit statuses.
- Count at least these audit kinds when present: `run`, `thought`, `tool_call`,
  `observation`, `final`, `policy_deny`, `system_error`.
- A run succeeded only if it reached a `final` event; do not infer success from
  the absence of errors.
- Look for repeated malformed actions, policy denials, or backend failures, and
  name the dominant failure mode if any.

## Reset between evaluations

To start clean while keeping secrets and committed assets:

- `playground/scripts/clean.sh`

It removes `runs/`, `logs/`, `state/`, `reports/`, `tmp/`, the generated
`config.toml`, and built `component.wasm` artifacts, then recreates empty data
directories. It never deletes `playground/.env` or any committed file.

## Report expectations

When asked to evaluate, produce a concise summary that states:

- whether the backend was reachable,
- the pass/fail status of the wasm_tool and mcp_call smokes,
- per-task exit statuses and the dominant failure mode (if any),
- where the full report, sessions, and audit data were written,
- the single smallest next adjustment to improve the environment.
