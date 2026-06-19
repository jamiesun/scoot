# Embedding API

Scoot can be used as a Zig package by other executables, but the package root is
deliberately a **lifecycle facade**, not a toolbox of internal types.

The public API is:

```zig
pub const version: []const u8;
pub const Runtime = opaque {};
pub const Options = struct { ... };
pub fn start(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Runtime;
pub fn run(rt: *Runtime, goal: []const u8) ![]const u8;
pub fn stop(rt: *Runtime) void;
```

`Runtime` is opaque. Embedders do not receive `Agent`, `Session`, `Config`,
`policy`, `llm.Client`, `tools`, or `Compressor`. Those remain internal so Scoot
can change its engine, configuration schema, compression, tools, MCP/Wasm
integration, and daemon internals without breaking downstream code.

## Options

`Options` accepts configuration **sources**, not structured configuration:

| Field | Meaning |
| --- | --- |
| `env` | Required environment map. Used for `HOME`/`SCOOT_HOME`, `SCOOT_*` overrides, and API token env lookup. |
| `scoot_home` | Optional runtime directory override, equivalent in spirit to CLI `--scoot-home`. |
| `config_file` | Optional explicit config file. `.toml` is parsed as TOML; other extensions use JSON. |

All concrete config structs stay internal. To change model, policy, compactor,
skills, or tool behavior, use the same config file and environment variables as
the CLI.

## Minimal Example

See [`examples/embed/minimal.zig`](https://github.com/jamiesun/scoot/blob/main/examples/embed/minimal.zig).
The example is compiled by `zig build test`, so public API drift is caught.

```zig
const scoot = @import("scoot");

const rt = try scoot.start(arena, init.io, .{
    .env = init.environ_map,
});
defer scoot.stop(rt);

const reply = try scoot.run(rt, "Return a short greeting.");
```

The returned reply is owned by the runtime and remains valid until `stop`.

## Stability Boundary

Stable:

- `version`
- `Options`
- opaque `Runtime`
- `start`
- `run`
- `stop`

Not stable:

- `Agent`, `Session`, `Config`, `policy`, `llm.Client`, `tools`, `Compressor`
  and all other internal modules;
- package-internal names under `src/`;
- generated build internals;
- exact layout of all hidden runtime state.

The repository has a whitelist test for the package root. Accidentally exporting
an internal namespace such as `tools` or `regex` fails `zig build test`.

## Zig Compatibility

Scoot's public API is source-level Zig API, not an ABI. Zig is still pre-1.0, so
Scoot's semver promise assumes the Zig version supported by this repository. If
you embed Scoot, pin the same Zig toolchain used by Scoot's CI/release workflow.

