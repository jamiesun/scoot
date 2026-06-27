#!/usr/bin/env sh
# Build the byte-stats wasm32-wasi command module into component.wasm.
set -eu

cd "$(dirname "$0")"
zig build-exe src/main.zig \
  -target wasm32-wasi \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  -femit-bin=component.wasm
chmod 644 component.wasm
echo "built: $(pwd)/component.wasm"
