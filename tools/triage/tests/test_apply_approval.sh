#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"
export OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
export GH_WRITE_LOG="$OUT_DIR/writes.log"; : > "$GH_WRITE_LOG"
# live view: unchanged target (staleness guard should NOT trip)
echo '{"state":"OPEN","comments":[]}' > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"

cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"c1","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"Thanks, investigating."}
]}
EOF

# approve one comment with "y"
printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "comment posted once"
assert_contains "posted c1" "$(cat "$OUT_DIR/apply.log")" "ledger records posted"

# re-run: id already posted -> no second write
printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "no double-post on re-run"
finish
