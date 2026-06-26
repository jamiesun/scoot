# Wasm Plugin Template

This directory is a copyable starting point for Scoot Wasm compressor plugins.
It is intentionally small: the module reads JSON from stdin, writes one JSON
object to stdout, and only imports the minimal WASI calls currently supported by
`scoot-wasm wasi`.

Build the component:

```sh
zig build wasm-plugin-template
```

Or compile just this package:

```sh
./examples/wasm-plugin-template/build.sh
```

Validate and run it:

```sh
zig build -Dwasm-host=true wasm-plugin-template
./zig-out/bin/scoot wasm-tools check examples/wasm-plugin-template
printf '%s\n' '{"version":1,"kind":"compressor","messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-plugin-template/component.wasm
```

When creating a new plugin, change `manifest.toml` first: set a unique `name`,
keep `kind = "compressor"` for context compactor plugins, and keep
`capabilities = ["compute"]` unless the host and policy gates grow a real I/O
surface.
