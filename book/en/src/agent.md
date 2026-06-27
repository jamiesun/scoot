# Agent Guide

The authoritative English agent guide lives at:

- [`AGENT.md`](https://github.com/jamiesun/scoot/blob/main/AGENT.md)

The Chinese agent guide lives at:

- [`docs/AGENT.zh.md`](https://github.com/jamiesun/scoot/blob/main/docs/AGENT.zh.md)

## Key Rules

- Read the roadmap before expanding capability.
- Keep code changes scoped.
- Run `zig build` and `zig build test` after Zig changes.
- Keep all project documentation bilingual.
- Do not execute unvalidated model output.
- Do not let skill *execution* bypass the tool sandbox; reading skill instructions/resources is a native read-only capability and intentionally not policy-gated.
- Export internal subsystems from `src/internal.zig`; keep `src/root.zig` limited to the stable embedding API unless explicitly changing that API boundary.
- Do not write secrets into config, logs, or audit output.
