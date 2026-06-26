# Wasm Redactor Compressor

This example is a slightly more realistic Scoot compressor plugin. It reads a
`CompactionRequest` from stdin, scans the elided messages for common secret
hints, and emits a deterministic marker. It never returns user content.

Build the plugin:

```sh
zig build wasm-redactor-compressor
```

Or compile just the module directly:

```sh
./examples/wasm-redactor-compressor/build.sh
```

Validate and run it through the same host shape used by
`agent.compactor_plugin`:

```sh
zig build -Dwasm-host=true wasm-redactor-compressor
./zig-out/bin/scoot wasm-tools check examples/wasm-redactor-compressor
./zig-out/bin/scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
  < examples/wasm-redactor-compressor/fixtures/request.json
```

Expected output:

```json
{"marker":"wasm redactor compressed 2 messages / 456 bytes; redaction hints 2"}
```
