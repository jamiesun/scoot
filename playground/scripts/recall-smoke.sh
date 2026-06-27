#!/bin/sh
# Recall smoke (best-effort probe).
#
# `recall` reads the full session transcript archive (including content compacted
# out of the active context). Its data source is therefore the *visible*
# transcript in a short task, so a real model can answer a recall prompt without
# dispatching the action -- unlike http_request (unguessable timestamp) or
# parallel (observation-only facts), recall cannot be reliably forced by prompt
# wording alone in a one-shot task.
#
# This probe runs the recall task a few times and reports whether a genuine
# `recall` action was actually dispatched (checked in the session transcript).
# It is intentionally non-fatal: persistent model skipping prints a WARNING but
# exits 0, so a model's choice never reddens the suite. The deny/limit and
# mechanism itself are covered by unit tests (issue #99); this is environment
# coverage, not a model conformance gate.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

TASK="$SCOOT_HOME/tasks/recall.txt"
ATTEMPTS=${1:-4}

i=1
while [ "$i" -le "$ATTEMPTS" ]; do
  echo "recall attempt $i/$ATTEMPTS"
  OUT=$("$SCOOT_HOME/scripts/run-task.sh" "$TASK" 2>&1) || true
  TRANSCRIPT=$(printf '%s\n' "$OUT" | sed -n 's/.*transcript=\([^ ]*\).*/\1/p' | tail -1)
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && \
     grep -Fq '\"action\":\"recall\"' "$TRANSCRIPT"; then
    echo "recall verified: genuine recall action in $TRANSCRIPT"
    exit 0
  fi
  echo "attempt $i did not dispatch a genuine recall action"
  i=$((i + 1))
done

echo "recall WARNING: model did not dispatch a recall action in $ATTEMPTS attempts (best-effort coverage; not a suite failure)" >&2
exit 0
