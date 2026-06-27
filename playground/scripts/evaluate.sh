#!/bin/sh
# Full playground evaluation: validate the build surface, run every task prompt
# end-to-end, exercise the wasm_tool and mcp_call boundaries, then write a
# Markdown report under playground/reports/. Designed to be safe to run
# repeatedly; clean state first with scripts/clean.sh when you want a fresh run.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

mkdir -p "$SCOOT_HOME/runs" "$SCOOT_HOME/reports" "$SCOOT_HOME/logs" \
  "$SCOOT_HOME/state/sessions" "$SCOOT_HOME/tmp"

STAMP=$(date "+%Y%m%d-%H%M%S")
REPORT="$SCOOT_HOME/reports/$STAMP-evaluation.md"
PYTHON=${PYTHON:-python3}
MCP_HOST=${SCOOT_PLAYGROUND_MCP_HOST:-127.0.0.1}
MCP_PORT=${SCOOT_PLAYGROUND_MCP_PORT:-18799}

SUITE_STATUS=0
note() { printf '%s\n' "$1" >> "$REPORT"; }

# --- header ---------------------------------------------------------------
{
  echo "# Scoot Playground Evaluation"
  echo
  echo "- Time (local): $STAMP"
  echo "- SCOOT_HOME: \`$SCOOT_HOME\`"
  echo "- scoot: \`$("$SCOOT_BIN" --version 2>/dev/null | head -1)\`"
  echo "- Backend: \`${SCOOT_PLAYGROUND_BASE_URL:-config default}\` (model \`${SCOOT_PLAYGROUND_MODEL:-config default}\`)"
  echo
  echo "## Environment & Build"
  echo
  echo '```text'
} > "$REPORT"

"$SCOOT_BIN" config >> "$REPORT" 2>&1 || true
echo >> "$REPORT"
echo "-- skills --" >> "$REPORT"
"$SCOOT_BIN" skills >> "$REPORT" 2>&1 || true
echo >> "$REPORT"
echo "-- wasm tools --" >> "$REPORT"
if "$SCOOT_HOME/scripts/build-wasm-tools.sh" >> "$REPORT" 2>&1; then
  WASM_BUILD=ok
else
  WASM_BUILD=FAILED
  SUITE_STATUS=1
fi
note '```'
note ""

# --- backend reachability -------------------------------------------------
note "## Backend Reachability"
note ""
note '```text'
if "$SCOOT_HOME/scripts/check-backend.sh" >> "$REPORT" 2>&1; then
  BACKEND=reachable
else
  BACKEND=unreachable
fi
note '```'
note ""

# --- policy dry-runs ------------------------------------------------------
note "## Policy Dry-Runs (readonly)"
note ""
note '```text'
"$SCOOT_HOME/scripts/policy-dry-runs.sh" readonly >> "$REPORT" 2>&1 || true
note '```'
note ""

# --- task prompts ---------------------------------------------------------
note "## Task Prompts"
note ""
for task in "$SCOOT_HOME"/tasks/*.txt; do
  [ -f "$task" ] || continue
  name=$(basename "$task")
  # mcp_echo and recall run in their own verified sections below.
  [ "$name" = "mcp_echo.txt" ] && continue
  [ "$name" = "recall.txt" ] && continue
  echo "Running task: $name"
  set +e
  TASK_OUTPUT=$("$SCOOT_HOME/scripts/run-task.sh" "$task" 2>&1)
  TASK_STATUS=$?
  set -e
  [ "$TASK_STATUS" -eq 0 ] || SUITE_STATUS=1
  OUT=$(printf '%s\n' "$TASK_OUTPUT" | tail -1)
  note "### $name"
  note ""
  note "- Exit: $TASK_STATUS"
  note "- Transcript: \`$OUT\`"
  note ""
done

# --- MCP smoke (self-managed server) --------------------------------------
note "## MCP Smoke (mcp_call)"
note ""
note '```text'
"$PYTHON" "$SCOOT_HOME/scripts/mcp-echo-server.py" "$MCP_HOST" "$MCP_PORT" \
  > "$SCOOT_HOME/runs/$STAMP-mcp-server.log" 2>&1 &
MCP_PID=$!
cleanup() { kill "$MCP_PID" 2>/dev/null || true; wait "$MCP_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

i=0
while [ "$i" -lt 50 ]; do
  if "$PYTHON" - "$MCP_HOST" "$MCP_PORT" <<'PY' >/dev/null 2>&1
import sys
from urllib.request import urlopen
urlopen("http://%s:%s/health" % (sys.argv[1], sys.argv[2]), timeout=0.2).read()
PY
  then break; fi
  i=$((i + 1)); sleep 0.1
done

set +e
MCP_OUTPUT=$("$SCOOT_HOME/scripts/run-task.sh" "$SCOOT_HOME/tasks/mcp_echo.txt" 2>&1)
MCP_STATUS=$?
set -e
printf '%s\n' "$MCP_OUTPUT" | tail -40 >> "$REPORT"
[ "$MCP_STATUS" -eq 0 ] || SUITE_STATUS=1
cleanup
trap - EXIT INT TERM
note '```'
note ""

# --- recall smoke (best-effort probe) -------------------------------------
# recall reads the visible transcript, so a real model can answer without
# dispatching the action; recall-smoke.sh probes whether a genuine recall action
# is dispatched (with retries) and is intentionally non-fatal.
note "## Recall Smoke (best-effort)"
note ""
note '```text'
RECALL_OUTPUT=$("$SCOOT_HOME/scripts/recall-smoke.sh" 2>&1 || true)
printf '%s\n' "$RECALL_OUTPUT" | grep -E 'attempt|verified|WARNING' >> "$REPORT"
if printf '%s\n' "$RECALL_OUTPUT" | grep -q 'recall verified'; then
  RECALL_RESULT=verified
else
  RECALL_RESULT="not dispatched (best-effort)"
fi
note '```'
note ""

# --- state summary --------------------------------------------------------
note "## State Summary"
note ""
note '```text'
"$SCOOT_HOME/scripts/state-brief.sh" >> "$REPORT" 2>&1 || true
note '```'
note ""

# --- verdict --------------------------------------------------------------
{
  echo "## Verdict"
  echo
  echo "- wasm build/validate: $WASM_BUILD"
  echo "- backend: $BACKEND"
  echo "- mcp_call smoke exit: ${MCP_STATUS:-n/a}"
  echo "- recall smoke: ${RECALL_RESULT:-n/a}"
  echo "- overall suite status: $([ "$SUITE_STATUS" -eq 0 ] && echo PASS || echo "FAIL (see exit codes above)")"
} >> "$REPORT"

echo
echo "Report written: $REPORT"
exit "$SUITE_STATUS"
