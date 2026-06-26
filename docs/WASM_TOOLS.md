# Wasm Tool Packages

Status: design boundary and static validation in the core; the standalone
`scoot-wasm` host now executes integer Wasm functions (W1). The core `scoot`
binary still never loads or executes Wasm.

Scoot's Wasm tool package format is intentionally smaller than Wassette or MCP.
The goal is a local, reviewable boundary for third-party tools before any
runtime is added.

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

Validate a package:

```sh
scoot wasm-tools check path/to/tool
```

The check is read-only. It parses metadata and schemas, checks referenced files,
rejects unsafe paths, and validates `component.wasm` binary structure (magic,
version, sections, LEB128 lengths, and basic index/count consistency). It never
executes Wasm.

## Standalone host (`scoot-wasm`)

Execution lives in a separate binary, built only with `-Dwasm-host=true`, so the
zero-dependency core never embeds a runtime:

```sh
zig build -Dwasm-host=true
scoot-wasm check path/to/module.wasm        # structural validation (W0)
scoot-wasm run path/to/module.wasm add 2 40 # execute an exported function (W1)
```

`scoot-wasm run <module.wasm> <export> [int args...]` invokes an exported
function with the W1 stack machine and prints its integer result(s), or a
structured `TRAP ...` line on fault. Arguments are parsed as integers and
coerced to the function's declared parameter types.

The W1 engine is a dependency-free Zig interpreter covering: structured control
flow (`block`/`loop`/`if`/`else`/`br`/`br_if`/`br_table`/`return`/`call`/
`call_indirect`), i32/i64 arithmetic, comparisons, bit/shift/rotate ops and
`wrap`/`extend` conversions, a bounds-checked 64 KiB-page linear memory
(`load`/`store` plus 8/16/32-bit variants, `memory.size`/`memory.grow`,
`memory.copy`/`memory.fill`), globals, a funcref table, and active data/element
segments. Every fault returns a structured trap instead of panicking
(unreachable, divide-by-zero, integer overflow, out-of-bounds memory/table,
undefined element, indirect-call type mismatch), bounded by fuel,
call-depth, value-stack, and memory-page limits.

Not yet implemented (later phases): WASI host functions (so a module that
imports host functions traps), a full spec-conformant type validator, and
floating-point arithmetic.

## Manifest

`manifest.toml` declares identity, entrypoint, schemas, and requested
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

Rules:

- `kind` must be `tool` or `compressor`; omitted defaults to `tool`.
- `name` uses the same identifier rules as skills: ASCII letters, digits, `.`,
  `_`, and `-`, up to 64 bytes.
- `description` must be non-empty.
- `entry` must be a non-empty ASCII identifier.
- `component`, `input_schema`, and `output_schema` must be safe relative paths.
  Absolute paths, `..`, hidden path segments, drive prefixes, and empty segments
  are rejected.
- `component` must end with `.wasm`.

## Policy

`policy.toml` declares the capabilities actually granted by the package owner:

```toml
capabilities = ["compute"]
```

Policy capabilities must be a subset of manifest capabilities. This prevents a
package from silently receiving authority it did not declare.

Supported capability names:

- `compute`: CPU-only work with no file, network, or environment access.
- `read`: local read access, subject to Scoot policy gates once runtime support
  exists.
- `write`: local write access, subject to Scoot policy gates once runtime
  support exists.
- `net_read`: outbound read-style network access.
- `net_write`: outbound write-style network access.

`compute` is the only capability expected for pure tools in the first iteration.
No capability currently grants runtime authority because execution is not
implemented.

## Schemas

`schema/input.json` and `schema/output.json` are JSON Schemas for the tool input
and output. The validator currently checks that both files exist and contain
valid JSON. Runtime schema enforcement will build on the same files.

Future model invocation shape:

```json
{
  "action": "wasm_tool",
  "action_input": "{\"tool\":\"calculator\",\"input\":{\"expr\":\"1+2\"}}"
}
```

## Non-Goals For v0

- no OCI registry or remote package install flow,
- no MCP dependency,
- no Wassette runtime dependency,
- no permission grant UI,
- no file, network, or environment access by default,
- JSON strings before WIT bindings,
- Scoot owns discovery, policy mapping, and audit identity.

The boundary leaves room to adopt Component Model/WIT later without making that
choice a prerequisite for package review.
