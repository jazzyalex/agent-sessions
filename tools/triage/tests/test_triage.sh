#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"
export OUT_ROOT="$(mktemp -d)/out"
export CLAUDE_LOG="$(mktemp)"

bash "$TRIAGE_ROOT/triage.sh"
TODAY="$(date +%Y-%m-%d)"
assert_file_exists "$OUT_ROOT/$TODAY/snapshot.json" "snapshot produced"
assert_file_exists "$OUT_ROOT/$TODAY/digest.md" "digest produced"
assert_file_exists "$OUT_ROOT/$TODAY/replies.json" "replies produced"
if jq -e 'type=="array"' "$OUT_ROOT/$TODAY/replies.json" >/dev/null 2>&1; then
  pass "replies.json is a JSON array"; else fail "replies.json is a JSON array"; fi
assert_contains "claude -p" "$(cat "$CLAUDE_LOG")" "agent invoked"
# lean: none of the stripped machinery leaves artifacts
assert_file_absent "$OUT_ROOT/$TODAY/status.json" "no status.json (no state machine)"
assert_file_absent "$OUT_ROOT/.lock" "no lock dir"

# agent failure -> minimal fallback digest, still produces both outputs
OUT_ROOT2="$(mktemp -d)/out"
OUT_ROOT="$OUT_ROOT2" CLAUDE_STUB_GARBAGE=1 bash "$TRIAGE_ROOT/triage.sh"
assert_file_exists "$OUT_ROOT2/$TODAY/digest.md" "fallback digest written on agent failure"
assert_file_exists "$OUT_ROOT2/$TODAY/replies.json" "fallback replies written on agent failure"
finish
