#!/bin/sh
# Verify the configured backend answers an OpenAI-compatible request.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

API_KEY=${SCOOT_PLAYGROUND_API_KEY:-}
BASE_URL=${SCOOT_PLAYGROUND_BASE_URL:-http://127.0.0.1:11434/v1}
MODEL=${SCOOT_PLAYGROUND_MODEL:-qwen2.5}

if [ -z "$API_KEY" ]; then
  echo "error: SCOOT_PLAYGROUND_API_KEY is empty; set it in playground/.env" >&2
  exit 1
fi

echo "Checking OpenAI-compatible backend..."
echo "Endpoint: $BASE_URL"
echo "Model: $MODEL"

RESPONSE=$(curl -sS --max-time 20 \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}]}" \
  "$BASE_URL/chat/completions")

case "$RESPONSE" in
  *'content":"ok'*)
    echo "Result: ok"
    ;;
  *)
    echo "Result: unexpected response"
    printf '%s\n' "$RESPONSE" | head -c 1000
    echo
    exit 1
    ;;
esac
