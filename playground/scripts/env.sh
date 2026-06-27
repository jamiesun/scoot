#!/bin/sh
# Shared environment for playground scripts.
#
# Responsibilities:
#   1. Resolve repo root, SCOOT_HOME (this playground), and the scoot binary.
#   2. Load playground/.env (gitignored secrets and backend overrides).
#   3. Regenerate playground/config.toml (gitignored) from config.default.toml,
#      applying any SCOOT_PLAYGROUND_BASE_URL / SCOOT_PLAYGROUND_MODEL overrides.
#
# Source it from every script:  . "$(dirname -- "$0")/env.sh"
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
export SCOOT_REPO="$ROOT_DIR"
export SCOOT_HOME="$ROOT_DIR/playground"
export SCOOT_BIN="$ROOT_DIR/zig-out/bin/scoot"
export SCOOT_WASM_BIN="$ROOT_DIR/zig-out/bin/scoot-wasm"

if [ ! -x "$SCOOT_BIN" ]; then
  echo "error: scoot binary not found at $SCOOT_BIN; run: zig build" >&2
  exit 1
fi

# Load local environment (secrets + dynamic backend overrides) if present.
ENV_FILE="$SCOOT_HOME/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Regenerate the runtime config from the committed default plus .env overrides.
DEFAULT_CONFIG="$SCOOT_HOME/config.default.toml"
RUNTIME_CONFIG="$SCOOT_HOME/config.toml"
if [ -f "$DEFAULT_CONFIG" ]; then
  cp "$DEFAULT_CONFIG" "$RUNTIME_CONFIG"
  if [ -n "${SCOOT_PLAYGROUND_BASE_URL:-}" ]; then
    esc=$(printf '%s' "$SCOOT_PLAYGROUND_BASE_URL" | sed 's/[\\&|]/\\&/g')
    sed "s|^base_url = .*|base_url = \"$esc\"|" "$RUNTIME_CONFIG" > "$RUNTIME_CONFIG.tmp" \
      && mv "$RUNTIME_CONFIG.tmp" "$RUNTIME_CONFIG"
  fi
  if [ -n "${SCOOT_PLAYGROUND_MODEL:-}" ]; then
    esc=$(printf '%s' "$SCOOT_PLAYGROUND_MODEL" | sed 's/[\\&|]/\\&/g')
    sed "s|^model = .*|model = \"$esc\"|" "$RUNTIME_CONFIG" > "$RUNTIME_CONFIG.tmp" \
      && mv "$RUNTIME_CONFIG.tmp" "$RUNTIME_CONFIG"
  fi
fi
