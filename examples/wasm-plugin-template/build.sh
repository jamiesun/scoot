#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")"
zig build-exe src/main.zig \
  -target wasm32-wasi \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  -femit-bin=component.wasm
chmod 644 component.wasm
