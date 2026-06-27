#!/bin/sh
# Compact storage + audit summary. Prints paths and event counts without dumping
# raw audit lines, which can carry large escaped observations.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

AUDIT="$SCOOT_HOME/logs/audit.jsonl"
SESSIONS="$SCOOT_HOME/state/sessions"

echo "SCOOT_HOME=$SCOOT_HOME"
echo "config=$SCOOT_HOME/config.toml"
echo "skills=$SCOOT_HOME/skills"
echo "runs=$SCOOT_HOME/runs"
echo "reports=$SCOOT_HOME/reports"
echo "audit=$AUDIT"
echo "sessions=$SESSIONS"

if [ -f "$AUDIT" ]; then
  echo "audit_event_counts:"
  awk '
    match($0, /"kind":"[^"]+"/) {
      kind = substr($0, RSTART + 8, RLENGTH - 9)
      count[kind]++
    }
    END {
      split("run thought tool_call observation final policy_deny system_error", keys, " ")
      for (i in keys) {
        k = keys[i]
        print k "=" (count[k] + 0)
      }
    }
  ' "$AUDIT" | sort
else
  echo "audit_event_counts: none"
fi

if [ -d "$SESSIONS" ]; then
  echo "session_files:"
  for f in "$SESSIONS"/*.jsonl; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f" | tr -d ' ')
    echo "$(basename "$f")=$lines"
  done
else
  echo "session_files: none"
fi

echo "recent_run_transcripts:"
if [ -d "$SCOOT_HOME/runs" ]; then
  # Intentional time-sorted listing of our own timestamped *.out files.
  # shellcheck disable=SC2012
  ls -t "$SCOOT_HOME"/runs/*.out 2>/dev/null | head -10 | while IFS= read -r f; do
    exit_line=$(grep '^EXIT=' "$f" | tail -1 || true)
    [ -n "$exit_line" ] || continue
    echo "$(basename "$f"):$exit_line"
  done
else
  echo "none"
fi
