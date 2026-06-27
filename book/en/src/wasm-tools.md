# Agent Compute Units (Wasm Tool Packages)

**Status: core static validation plus a standalone host.** The core `scoot`
binary still does **not** load or execute Wasm, but the optional
`scoot-wasm` binary can execute the current integer, floating-point, and WASI
host subset when built with `-Dwasm-host=true`. The full reference is
[`docs/WASM_TOOLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/WASM_TOOLS.md); this is the overview.

The goal is a small, local, **reviewable** boundary for third-party tools —
deliberately smaller than MCP or Wassette — so a package can be inspected and
its requested authority understood *before* any runtime is ever added.

## Positioning: An Agent Compute Unit, Not "Partial Wasm"

Scoot deliberately uses only a slice of Wasm, and does **not** chase full-spec
Wasm or the Component Model as a goal. That is a **choice, not a defect**. The
unit of extension here is an **Agent Compute Unit**: a sealed, pure
data-transform sandbox whose only channels are stdin (input), stdout/stderr
(output), argv (configuration), and the process exit code. It has no filesystem,
network, environment, clock, or randomness authority — any such import traps. Its
output is a pure function of `(stdin, argv)`; if a unit needs a timestamp, seed,
or nonce, the host passes it as input bytes, never as an ambient syscall.

"Wasm" stays the underlying mechanism and keeps the existing identifiers
(`wasm_tool`, `wasm-tools check`, `wasm_host`). "Agent Compute Unit" is how to
think about *what it is for*: a small, reviewable, deterministic unit of compute
the agent can call without granting it any ambient power.

## Trust Boundary & Official Stance

Scoot's safety guarantee for compute units is **not** "we read your code and
judge it." Human or LLM review is advisory and can be evaded by obfuscation or
supply-chain tampering. The guarantee is the sandbox: even a malicious unit can
do nothing but transform its own input, because the host grants no ambient
authority. Blast radius is bounded by what Scoot will run, regardless of who
wrote the package or how it reached disk.

Therefore, by design:

- **Scoot never fetches or executes remote code.** There is no `scoot install
  user/repo`, no registry, and no remote code-loading path for skills or compute
  units. Packages arrive on disk through the user's own ordinary, trusted
  operations (clone, copy, unpack).
- **Any third-party tool that fetches and runs code on your behalf is not Scoot**
  and falls outside Scoot's safety guarantee. A wrapper named like
  `scoot-installer` speaks for itself, not for this project.
- **Transparency is deterministic, not subjective.** `scoot wasm-tools check`
  statically validates package shape, rejects path and symlink escapes, and
  enforces the capability-subset rule — and the audit log records every unit the
  agent actually runs.

## Package Layout

```text
tool/
  component.wasm
  manifest.toml
  policy.toml
  schema/
    input.json
    output.json
```

Validate a package — read-only, never runs the Wasm:

```sh
scoot wasm-tools check path/to/tool
```

The check parses metadata and schemas, verifies referenced files exist, rejects
unsafe paths (absolute, `..`, hidden segments, drive prefixes, empty segments),
and validates `component.wasm` binary structure (magic, version, sections,
LEB128 lengths, and basic index/count consistency). It never executes Wasm.

Build the standalone host when you explicitly want execution:

```sh
zig build -Dwasm-host=true
scoot-wasm check path/to/module.wasm
scoot-wasm run path/to/module.wasm add 2 40
scoot-wasm wasi path/to/module.wasm [args...]
```

Before `run` or `wasi` executes a module, the host validates the supported
function-body subset: operand/control stack shapes, block/loop/if signatures,
branch labels, call signatures, local/global access, memory/table presence, and
immutable globals.

The repo includes a complete compressor example, a copyable template, and a
second deterministic redactor compressor:

```sh
zig build wasm-compressor-example wasm-plugin-template wasm-redactor-compressor
scoot wasm-tools check examples/wasm-compressor
scoot wasm-tools check examples/wasm-plugin-template
scoot wasm-tools check examples/wasm-redactor-compressor
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | scoot-wasm wasi examples/wasm-compressor/component.wasm
scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
  < examples/wasm-redactor-compressor/fixtures/request.json
```

Use `examples/wasm-plugin-template` for new compressor packages. The
`scripts/check-wasm-examples.sh` smoke check builds the host and examples,
validates package boundaries, and runs representative WASI executions.

## Manifest & Policy

`manifest.toml` declares identity, entrypoint, schemas, and **requested**
capabilities:

```toml
kind = "tool"
name = "calculator"
description = "Evaluate simple math expressions"
entry = "call"
component = "component.wasm"
input_schema = "schema/input.json"
output_schema = "schema/output.json"
capabilities = ["compute"]
```

`kind` defaults to `tool` for backward compatibility. External context
compressors use the same static package boundary with `kind = "compressor"`;
Scoot still does not load or execute Wasm from core.

`policy.toml` declares the capabilities actually **granted**, and must be a
**subset** of the manifest's — a package can't silently gain authority it didn't
declare:

```toml
capabilities = ["compute"]
```

Capability names: `compute` (CPU-only, no I/O), `read`, `write`, `net_read`,
`net_write`. The standalone host currently exposes only a minimal WASI preview1
stdin/stdout/stderr/argv/proc-exit subset; environment, clock, randomness,
filesystem, and network authority are not implemented.

## Agent Invocation

`wasm_tool` is the native Agent action for compute-only local packages. It keeps
Wasm execution out of `bash`: the model supplies a package path and JSON input,
while the configured host argv remains trusted runtime configuration.

```json
{ "action": "wasm_tool", "action_input": "{\"package\":\"examples/wasm-plugin-template\",\"input\":{\"expr\":\"1+2\"}}" }
```

The action reuses package validation, requires `entry = "_start"`, and only runs
packages whose `policy.toml` grants `compute` and nothing broader. In `guarded`
and `readonly`, package paths must be project-relative and must not contain
absolute paths, `..`, `~`, or `$` expansion. With the default host config, Scoot
first tries a sibling `scoot-wasm` next to the running `scoot` binary, then falls
back to PATH.

## Schemas

`schema/input.json` and `schema/output.json` are JSON Schemas for the tool I/O.
The validator currently checks that both exist and are valid JSON; runtime
enforcement will build on the same files.

## Non-Goals (v0)

No OCI registry or remote install, no MCP/Wassette dependency, no permission-grant
UI, and no file/network/env access by default. JSON strings precede WIT bindings.
Scoot owns discovery, policy mapping, and audit identity — leaving room to adopt
the Component Model/WIT later without making it a prerequisite for review.
