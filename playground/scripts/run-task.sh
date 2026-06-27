#!/bin/sh
# Run one task prompt through `scoot -e` with a hard wall-clock timeout, and
# capture the full transcript under playground/runs/.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

TASK_FILE=${1:-"$SCOOT_HOME/tasks/smoke.txt"}
if [ ! -f "$TASK_FILE" ]; then
  echo "error: task file not found: $TASK_FILE" >&2
  exit 2
fi

STAMP=$(date "+%Y%m%d-%H%M%S")
NAME=$(basename "$TASK_FILE" .txt)
OUT="$SCOOT_HOME/runs/$STAMP-$NAME.out"
PROMPT=$(cat "$TASK_FILE")
TIMEOUT_SEC=${SCOOT_TASK_TIMEOUT_SEC:-180}

mkdir -p "$SCOOT_HOME/runs" "$SCOOT_HOME/reports"

{
  echo "SCOOT_HOME=$SCOOT_HOME"
  echo "TASK=$TASK_FILE"
  echo "START=$STAMP"
  echo "----- scoot output -----"
} > "$OUT"

set +e
"$SCOOT_BIN" -e "$PROMPT" >> "$OUT" 2>&1 &
PID=$!
STATUS=
ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$ELAPSED" -ge "$TIMEOUT_SEC" ]; then
    echo "[playground] task timeout after ${TIMEOUT_SEC}s; terminating pid $PID" >> "$OUT"
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null
    STATUS=124
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
if [ -z "$STATUS" ]; then
  wait "$PID"
  STATUS=$?
fi
set -e

cat "$OUT"

{
  echo "----- end -----"
  echo "EXIT=$STATUS"
  echo "$OUT"
} | tee -a "$OUT"
exit "$STATUS"
