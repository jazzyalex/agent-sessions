#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
echo '{"repos":{},"errors":[]}' > "$OUT_DIR/snapshot.json"
printf '# prompt\n' > "$TRIAGE_ROOT/PROMPT.md"   # temp; Task 9 writes the real one
export AGENT_STAGE_ROOT="$(mktemp -d)/stage"
export CLAUDE_LOG="$(mktemp)"

bash "$TRIAGE_ROOT/run-agent.sh"
assert_file_exists "$OUT_DIR/digest.md" "digest copied back"
assert_file_exists "$OUT_DIR/actions.json" "actions copied back"
# stage cleaned up
assert_file_absent "$AGENT_STAGE_ROOT" "stage removed after run"
# the claude adapter was actually invoked (stub logs its argv to CLAUDE_LOG)
assert_contains "claude" "$(cat "$CLAUDE_LOG")" "claude adapter invoked"
finish
