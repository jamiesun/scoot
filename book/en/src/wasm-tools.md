# Wasm Tool Packages

**Status: design boundary and static validation only.** Scoot does **not**
execute Wasm tools yet. The full reference is
[`docs/WASM_TOOLS.md`](https://github.com/jamiesun/scoot/blob/main/docs/WASM_TOOLS.md); this is the overview.

The goal is a small, local, **reviewable** boundary for third-party tools —
deliberately smaller than MCP or Wassette — so a package can be inspected and
its requested authority understood *before* any runtime is ever added.

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

Validate a package — read-only, never loads or runs the Wasm:

```sh
scoot wasm-tools check path/to/tool
```

The check parses metadata and schemas, verifies referenced files exist, rejects
unsafe paths (absolute, `..`, hidden segments, drive prefixes, empty segments),
and validates `component.wasm` binary structure (magic, version, sections,
LEB128 lengths, and basic index/count consistency). It never executes Wasm.

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
`net_write`. For the first iteration `compute` is the only one expected, and
**no capability currently grants runtime authority** because execution isn't
implemented.

## Schemas

`schema/input.json` and `schema/output.json` are JSON Schemas for the tool I/O.
The validator currently checks that both exist and are valid JSON; runtime
enforcement will build on the same files. The planned model-invocation shape:

```json
{ "action": "wasm_tool", "action_input": "{\"tool\":\"calculator\",\"input\":{\"expr\":\"1+2\"}}" }
```

## Non-Goals (v0)

No OCI registry or remote install, no MCP/Wassette dependency, no permission-grant
UI, and no file/network/env access by default. JSON strings precede WIT bindings.
Scoot owns discovery, policy mapping, and audit identity — leaving room to adopt
the Component Model/WIT later without making it a prerequisite for review.
