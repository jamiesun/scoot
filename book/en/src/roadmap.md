# Roadmap

The authoritative English roadmap lives at:

- [`docs/ROADMAP.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.md)

The Chinese roadmap lives at:

- [`docs/ROADMAP.zh.md`](https://github.com/jamiesun/scoot/blob/main/docs/ROADMAP.zh.md)

## Short Version

Scoot should stay a small, auditable, local-first automation core:

- one lightweight binary,
- CLI and config file interaction,
- OpenAI-compatible backend only,
- local state and audit logs,
- defensive validation before execution,
- no GUI,
- no cloud sync,
- no secret leakage,
- no skill privilege bypass.

Near-term work should improve diagnostics, per-run summaries, directory permission hardening, log lifecycle, and eventually plan mode.

