#!/bin/sh
# Run the playground's local unauthenticated MCP echo server in the foreground.
# The committed config.toml already points the "playground-echo" server here.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

PYTHON=${PYTHON:-python3}
HOST=${SCOOT_PLAYGROUND_MCP_HOST:-127.0.0.1}
PORT=${SCOOT_PLAYGROUND_MCP_PORT:-18799}

echo "Starting playground MCP echo server on http://$HOST:$PORT/mcp (Ctrl-C to stop)"
exec "$PYTHON" "$SCOOT_HOME/scripts/mcp-echo-server.py" "$HOST" "$PORT"
