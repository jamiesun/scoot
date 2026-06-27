# Roadmap

The authoritative English roadmap lives at:

- [`docs/ROADMAP.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.md)

The Chinese roadmap lives at:

- [`docs/ROADMAP.zh.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.zh.md)

## Short Version

Scoot should stay a small, auditable, local-first automation core:

- one lightweight binary,
- CLI, REPL, daemon, and local stdio `serve` interaction,
- OpenAI-compatible Responses API backend only,
- local state and audit logs,
- defensive validation before execution,
- no GUI or web UI,
- no cloud sync,
- no secret leakage,
- no skill privilege bypass,
- MCP/Wasm/other extension seams must remain configuration-gated, timeout-bound, and auditable,
- the public package root must stay a narrow stable embedding API.

Near-term work should focus on extension-boundary audits, actionable diagnostics, documentation alignment, runtime governance, and only then plan mode.
