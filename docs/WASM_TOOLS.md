# Wasm Tool Packages

Status: design boundary and static validation in the core; the standalone
`scoot-wasm` host now executes integer Wasm functions (W1) and runs
`wasm32-wasi` command modules over a minimal WASI preview1 subset (W2), with a
static type validation pass for the current host subset before execution (W3).
The core `scoot` binary still never loads or executes Wasm.

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
scoot-wasm check path/to/module.wasm         # structural validation (W0)
scoot-wasm run path/to/module.wasm add 2 40  # execute an exported function (W1)
scoot-wasm wasi path/to/module.wasm [args..] # run a wasm32-wasi command (W2)
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

Before `run` or `wasi` executes a module, W3 validation checks the supported
function-body subset: operand/control stack shapes, block/loop/if signatures,
branch label arity/types, direct and indirect call signatures, local/global
access, memory/table presence, and immutable globals. Type/index mistakes fail
module loading instead of reaching the interpreter.

### WASI command modules (`scoot-wasm wasi`, W2)

`scoot-wasm wasi <module.wasm> [args...]` runs a `wasm32-wasi` command module:
it instantiates the module, runs its start section and `_start` export, reads
this process's stdin as fd 0, forwards the module's stdout/stderr, and exits
with the module's `proc_exit` status (a normal `_start` return exits 0). This is
the intended subprocess host for external compression plugins: the core invokes
`scoot-wasm wasi <component>` and speaks the JSON-in/JSON-out plugin protocol
over stdio.

Only a deliberately small WASI preview1 surface is exposed, so a module gains no
ambient authority by construction:

- `args_sizes_get` / `args_get`, `environ_sizes_get` / `environ_get`
- `fd_read` (fd 0 only), `fd_write` (fd 1/2 only), `fd_close`, `fd_seek`
  (stdio is not seekable → `ESPIPE`), `fd_fdstat_get` (stdio character device)
- `clock_time_get` (realtime/monotonic), `random_get` (seeded, deterministic)
- `proc_exit`

The host does **not** expose its own environment (environ is empty by default)
and implements **no** filesystem or network functions: any other WASI import
traps when called, and an out-of-bounds guest pointer returns `EFAULT` rather
than corrupting host memory. Bad file descriptors return `EBADF`. Resource use
stays bounded by the same fuel / call-depth / memory-page caps as `run`, and the
core additionally wraps the subprocess with a hard wall-clock timeout.

The repository includes a runnable compressor package under
`examples/wasm-compressor`. Build it with:

```sh
zig build wasm-compressor-example
./zig-out/bin/scoot wasm-tools check examples/wasm-compressor
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-compressor/component.wasm
```

Not yet implemented (later phases): full spec-conformant validation beyond the
current host subset, floating-point conformance, and the broader WASI surface
(files, sockets, clocks beyond realtime/monotonic).

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
Package capabilities are still admission metadata: the standalone host currently
exposes only stdio/args/environ/clock/random/proc-exit, and it does not map
`read`, `write`, `net_read`, or `net_write` to filesystem, environment, or
network authority.

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
