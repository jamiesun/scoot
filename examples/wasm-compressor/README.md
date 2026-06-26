# Wasm Compressor Example

This directory is a minimal Scoot compressor plugin package. It compiles a
`wasm32-wasi` command module that reads a Scoot `CompactionRequest` from stdin
and writes a JSON object containing a `marker` string to stdout.

Build the plugin:

```sh
zig build wasm-compressor-example
```

Or compile just the module directly:

```sh
./examples/wasm-compressor/build.sh
```

Build the optional standalone host when you want to execute it:

```sh
zig build -Dwasm-host=true
```

Validate the package without executing the module:

```sh
./zig-out/bin/scoot wasm-tools check examples/wasm-compressor
```

Run the module through the same host shape used by `agent.compactor_plugin`:

```sh
printf '%s\n' '{"version":1,"kind":"compressor","keep_recent":2,"elided_count":3,"elided_bytes":1200,"messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-compressor/component.wasm
```

Configure Scoot to use it:

```toml
[agent]
compactor = "plugin:wasm-example"

[agent.compactor_plugin.wasm-example]
package = "/absolute/path/to/examples/wasm-compressor"
host = ["/absolute/path/to/zig-out/bin/scoot-wasm", "wasi", "{component}"]
timeout_ms = 30000
stdout_limit = 1048576
stderr_limit = 262144
```

The example intentionally uses only `fd_read`, `fd_write`, and `proc_exit`.
That keeps it inside the current `scoot-wasm` minimal WASI surface.
