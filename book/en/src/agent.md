# Agent Guide

The authoritative English agent guide lives at:

- [`AGENT.md`](../../../AGENT.md)

The Chinese agent guide lives at:

- [`docs/AGENT.zh.md`](../../../docs/AGENT.zh.md)

## Key Rules

- Read the roadmap before expanding capability.
- Keep code changes scoped.
- Run `zig build` and `zig build test` after Zig changes.
- Keep all project documentation bilingual.
- Do not execute unvalidated model output.
- Do not let skill *execution* bypass the tool sandbox (reading a skill's instructions is a native read-only capability and is intentionally not policy-gated).
- Do not write secrets into config, logs, or audit output.

