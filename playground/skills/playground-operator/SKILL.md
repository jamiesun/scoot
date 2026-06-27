---
name: playground-operator
description: Operate the Scoot playground test environment, run read-only project inspections, and exercise built-in tools while keeping all output inside playground/.
---

# Playground Operator

Use this skill when the user asks to test or exercise Scoot inside the
repository-local `playground/` environment.

Rules:

- Treat `playground/` as the runtime home for tests (`SCOOT_HOME=playground`).
- Prefer read-only inspection unless the user explicitly asks to change files.
- Keep generated artifacts under `playground/runs`, `playground/reports`,
  `playground/logs`, or `playground/state`. Never write outside `playground/`
  unless the task explicitly says so.
- Do not write credentials into config files, reports, session JSONL, or audit
  logs. Secrets live only in `playground/.env`, which is gitignored.
- When checking the repository shape, use `glob`, `grep`, `outline`, or safe
  read-only shell commands; prefer `parallel` for several independent reads.
- To run the local Wasm tool, use the native `wasm_tool` action with package
  `playground/tools/wasm/byte-stats`; do not shell out to run Wasm.
- To call the local MCP server, use `mcp_call` with server `playground-echo`
  and tool `echo`; do not use `bash` or `http_request` for it.
- For policy dry-runs, prefer `playground/scripts/policy-dry-runs.sh` instead of
  embedding dangerous command strings in a shell action.
- Do not broad-grep `playground/logs/audit.jsonl`; audit observations can carry
  large source files and will bloat context. Use `state-brief.sh` instead.

Expected runtime paths:

- Default config (committed): `playground/config.default.toml`
- Active config (generated, gitignored): `playground/config.toml`
- Secrets / backend overrides (gitignored): `playground/.env`
- Skills: `playground/skills`
- Wasm tools: `playground/tools/wasm/<name>`
- Audit log: `playground/logs/audit.jsonl`
- Sessions: `playground/state/sessions`
- Run transcripts: `playground/runs`
- Reports: `playground/reports`

Compact helpers:

- `playground/scripts/check-backend.sh`: verify the configured backend.
- `playground/scripts/build-wasm-tools.sh`: build and validate Wasm packages.
- `playground/scripts/policy-dry-runs.sh`: fixed policy dry-runs.
- `playground/scripts/state-brief.sh`: concise storage paths and event counts.

For a final answer, report: whether the backend was reachable, which tools were
used, whether any policy denial occurred, where session and audit data were
written, and one concrete improvement for the next run.
