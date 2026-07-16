#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
echo '{"repos":{},"errors":[]}' > "$OUT_DIR/snapshot.json"
export CLAUDE_LOG="$(mktemp)"; export CLAUDE_PROMPT_LOG="$(mktemp)"

bash "$TRIAGE_ROOT/run-agent.sh"
assert_file_exists "$OUT_DIR/digest.md" "digest parsed from stdout"
assert_file_exists "$OUT_DIR/actions.json" "actions parsed from stdout"
assert_eq "0" "$(jq '.actions | length' "$OUT_DIR/actions.json")" "actions array parses"
# tool-less invocation: adapter ran, deny list passed, prompt fed on stdin
assert_contains "claude -p" "$(cat "$CLAUDE_LOG")" "claude adapter invoked"
assert_contains "--disallowedTools" "$(cat "$CLAUDE_LOG")" "defense-in-depth deny list passed"
assert_contains '"repos"' "$(cat "$CLAUDE_PROMPT_LOG")" "snapshot inlined in the prompt"
assert_contains "OUTPUT CONTRACT" "$(cat "$CLAUDE_PROMPT_LOG")" "output contract appended"

# unparseable stdout -> non-zero exit (triggers triage.sh's fallback digest)
OUT_DIR2="$(mktemp -d)/out"; mkdir -p "$OUT_DIR2"
echo '{"repos":{},"errors":[]}' > "$OUT_DIR2/snapshot.json"
if OUT_DIR="$OUT_DIR2" CLAUDE_STUB_GARBAGE=1 bash "$TRIAGE_ROOT/run-agent.sh" 2>/dev/null; then
  fail "garbage stdout must exit non-zero"; else pass "garbage stdout exits non-zero"; fi
assert_file_absent "$OUT_DIR2/actions.json" "no partial outputs on parse failure"
finish
