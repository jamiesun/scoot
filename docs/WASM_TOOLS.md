# Wasm Tool Packages

Status: design boundary and static validation in the core; the standalone
`scoot-wasm` host now executes integer and floating-point Wasm functions
(W1/W4) and runs `wasm32-wasi` command modules over a minimal WASI preview1
subset (W2), with a static type validation pass for the current host subset
before execution (W3). The core `scoot` binary still never loads or executes
Wasm.

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

The exposed WASI preview1 surface is deliberately minimal: a plugin is a pure
data transform whose only channels are stdin, stdout/stderr, argv, and the exit
code. By construction it gains no ambient authority:

- `args_sizes_get` / `args_get` (argv, the only configuration channel)
- `fd_read` (fd 0 / stdin only), `fd_write` (fd 1/2 / stdout+stderr only)
- `proc_exit`

The host exposes **no** environment, clock, or randomness, and **no** filesystem
or network: `environ_*`, `clock_time_get`, `random_get`, and every other WASI
import resolve to `unsupported` and trap when called. This keeps a plugin's
output a pure function of its (stdin, argv): if a plugin needs a timestamp,
seed, or nonce, the host must pass it as input bytes, never as an ambient
syscall. Writing to a non-stdio descriptor returns `EBADF`, and an
out-of-bounds guest pointer returns `EFAULT` rather than corrupting host
memory. Resource use stays bounded by the same fuel / call-depth / memory-page
caps as `run`, and the core additionally wraps the subprocess with a hard
wall-clock timeout.

The repository includes runnable compressor packages and a copyable template:

```sh
zig build wasm-compressor-example wasm-plugin-template wasm-redactor-compressor
./zig-out/bin/scoot wasm-tools check examples/wasm-compressor
./zig-out/bin/scoot wasm-tools check examples/wasm-plugin-template
./zig-out/bin/scoot wasm-tools check examples/wasm-redactor-compressor
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-compressor/component.wasm
./zig-out/bin/scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
  < examples/wasm-redactor-compressor/fixtures/request.json
```

Use `examples/wasm-plugin-template` as the starting point for new compressor
plugins. `examples/wasm-redactor-compressor` is a second, deterministic example
that scans elided messages for secret-like hints without returning message
content. `scripts/check-wasm-examples.sh` builds the host and all example
components, validates package boundaries, and runs the template/redactor smoke
checks.

Not yet implemented (later phases): full spec-conformant validation and
floating-point conformance against the official Wasm spec test suite beyond the
current host subset, and the broader WASI surface (files, sockets, environment,
clocks, randomness) — all of which the pure data-transform sandbox excludes by
design.

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
exposes only the stdin/stdout/stderr/argv/proc-exit subset, and it does not map
`read`, `write`, `net_read`, or `net_write` to filesystem, environment, or
network authority.

## Agent Invocation

`wasm_tool` is a native Agent action for compute-only local packages. It avoids
granting the model a broad `bash` command just to run a Wasm tool:

```json
{
  "action": "wasm_tool",
  "action_input": "{\"package\":\"examples/wasm-plugin-template\",\"input\":{\"expr\":\"1+2\"}}"
}
```

The action reuses the same package validation, requires `entry = "_start"`, and
only runs packages whose `policy.toml` grants `compute` and nothing broader. In
`guarded` and `readonly`, package paths must be project-relative and must not
contain absolute paths, `..`, `~`, or `$` expansion. The configured host argv is
trusted runtime configuration; the model supplies only JSON input and the local
package path. With the default host config, Scoot first tries a `scoot-wasm`
binary next to the running `scoot` executable, then falls back to PATH.

## Schemas

`schema/input.json` and `schema/output.json` are JSON Schemas for the tool input
and output. The validator currently checks that both files exist and contain
valid JSON. Runtime schema enforcement will build on the same files.

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
