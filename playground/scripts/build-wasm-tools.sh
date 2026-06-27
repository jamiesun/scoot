#!/bin/sh
# Build all playground Wasm tool packages and validate their boundaries.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

STATUS=0
for dir in "$SCOOT_HOME"/tools/wasm/*/; do
  [ -f "$dir/manifest.toml" ] || continue
  name=$(basename "$dir")
  echo "== $name =="
  if [ -f "$dir/build.sh" ]; then
    sh "$dir/build.sh"
  fi
  if "$SCOOT_BIN" wasm-tools check "$dir"; then
    echo "validate: ok"
  else
    echo "validate: FAILED"
    STATUS=1
  fi
  echo
done
exit "$STATUS"
