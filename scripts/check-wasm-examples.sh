#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

zig build -Dwasm-host=true
zig build wasm-compressor-example wasm-plugin-template wasm-redactor-compressor

for package in \
  examples/wasm-compressor \
  examples/wasm-plugin-template \
  examples/wasm-redactor-compressor
do
  ./zig-out/bin/scoot wasm-tools check "$package"
done

printf '%s\n' '{"version":1,"kind":"compressor","messages":[]}' \
  | ./zig-out/bin/scoot-wasm wasi examples/wasm-plugin-template/component.wasm \
  | grep -E '^\{"marker":"template received [0-9]+ bytes"\}$' >/dev/null

redactor_output="$(
  ./zig-out/bin/scoot-wasm wasi examples/wasm-redactor-compressor/component.wasm \
    < examples/wasm-redactor-compressor/fixtures/request.json
)"
expected_redactor="$(cat examples/wasm-redactor-compressor/fixtures/expected-output.json)"
if [ "$redactor_output" != "$expected_redactor" ]; then
  printf 'unexpected redactor output:\n%s\n' "$redactor_output" >&2
  exit 1
fi
