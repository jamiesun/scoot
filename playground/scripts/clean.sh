#!/bin/sh
# Quickly reset playground runtime state for a fresh evaluation, while KEEPING
# .env, committed config defaults, skills, tasks, scripts, and wasm sources.
#
# Removes: runs/, logs/, state/, reports/, tmp/, the generated config.toml, and
# built component.wasm artifacts. It never touches .env or any committed file.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

echo "Cleaning playground runtime state under $SCOOT_HOME (keeping .env)..."

for d in runs logs state reports tmp; do
  target="$SCOOT_HOME/$d"
  if [ -e "$target" ]; then
    rm -rf "$target"
    echo "  removed $d/"
  fi
done

# Generated runtime config (rebuilt by env.sh on next run).
if [ -f "$SCOOT_HOME/config.toml" ]; then
  rm -f "$SCOOT_HOME/config.toml"
  echo "  removed config.toml (generated)"
fi

# Built wasm artifacts (reproducible via build.sh).
for w in "$SCOOT_HOME"/tools/wasm/*/component.wasm; do
  [ -f "$w" ] || continue
  rm -f "$w"
  echo "  removed $(basename "$(dirname "$w")")/component.wasm"
done

# Recreate empty data dirs so paths are ready for the next run.
mkdir -p "$SCOOT_HOME/runs" "$SCOOT_HOME/reports" "$SCOOT_HOME/logs" \
  "$SCOOT_HOME/state/sessions" "$SCOOT_HOME/tmp"

if [ -f "$SCOOT_HOME/.env" ]; then
  echo "Kept: $SCOOT_HOME/.env"
else
  echo "Note: $SCOOT_HOME/.env not found (copy from .env.example)."
fi
echo "Done."
