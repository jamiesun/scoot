#!/bin/sh
# Fixed execution-policy dry-runs. Dangerous literals stay inside this wrapper so
# agent prompts can call a safe helper instead of synthesizing them in a shell.
set -eu
# shellcheck disable=SC1091
. "$(dirname -- "$0")/env.sh"

MODE=${1:-readonly}

run_check() {
  label=$1
  action=$2
  input=$3
  echo "## $label"
  "$SCOOT_BIN" --scoot-home "$SCOOT_HOME" policy check "$action" "$input" --mode "$MODE"
  echo
}

DANGEROUS_ROOT_DELETE="rm -rf /"

echo "mode=$MODE"
echo
run_check "bash_root_delete" "bash" "$DANGEROUS_ROOT_DELETE"
run_check "file_read_readme" "file_read" '{"path":"README.md"}'
run_check "file_write_playground_tmp" "file_write" '{"path":"playground/tmp/agent-write.txt","content":"x"}'
run_check "http_request_loopback" "http_request" '{"method":"GET","url":"http://127.0.0.1/"}'
