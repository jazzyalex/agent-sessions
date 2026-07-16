#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"

# fresh_out: mint an isolated OUT_DIR with its own write-log, and truncate the
# gh stub's shared write log. Sets OUT_DIR + GH_WRITE_LOG for the caller.
fresh_out() {
  OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
  export OUT_DIR
  export GH_WRITE_LOG="$OUT_DIR/writes.log"; : > "$GH_WRITE_LOG"
}

# ── Scenario A: approve one comment with "y", then re-run (idempotent) ──
fresh_out
echo '{"state":"OPEN","comments":[]}' > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"c1","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"Thanks, investigating."}
]}
EOF
printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "comment posted once"
assert_contains "posted c1" "$(cat "$OUT_DIR/apply.log")" "ledger records posted"
# re-run: id already posted -> no second write
printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "no double-post on re-run"

# ── Scenario B: explicit "n" must NOT post, records skipped ──
fresh_out
echo '{"state":"OPEN","comments":[]}' > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"cn","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"nope"}
]}
EOF
printf 'n\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_eq "0" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "explicit n does not post"
assert_contains "skipped cn" "$(cat "$OUT_DIR/apply.log")" "ledger records skipped on n"

# ── Scenario C (C1 regression): --dry-run + y must NOT touch the ledger ──
fresh_out
echo '{"state":"OPEN","comments":[]}' > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"cd","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"dry body"}
]}
EOF
printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" --dry-run "$OUT_DIR" >/dev/null
assert_eq "0" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "dry-run makes no write"
touch "$OUT_DIR/apply.log"
assert_eq "0" "$(grep -c 'posted cd' "$OUT_DIR/apply.log")" "dry-run leaves ledger clean (C1)"

# ── Scenario D: edit path posts the EDITED body ──
fresh_out
echo '{"state":"OPEN","comments":[]}' > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
EDSTUB="$OUT_DIR/editor.sh"
cat > "$EDSTUB" <<'EOS'
#!/usr/bin/env bash
printf '%s EDITED\n' "$(cat "$1")" > "$1"
EOS
chmod +x "$EDSTUB"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"ce","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"original"}
]}
EOF
printf 'e\ny\n' | EDITOR="$EDSTUB" bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR" >/dev/null
assert_contains "original EDITED" "$(cat "$GH_WRITE_LOG")" "edit path posts edited body"
assert_contains "posted ce" "$(cat "$OUT_DIR/apply.log")" "edited comment recorded posted"

# ── Scenario E: staleness — a comment newer than capture_time defaults to skip ──
fresh_out
echo '{"capture_time":"2026-01-01T00:00:00Z","gather_start":"2026-01-01T00:00:00Z","repos":{},"errors":[]}' \
  > "$OUT_DIR/snapshot.json"
# live view: OPEN, but with a comment created AFTER the snapshot capture_time
echo '{"state":"OPEN","comments":[{"createdAt":"2026-06-01T00:00:00Z","author":{"login":"someone"}}]}' \
  > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"cs","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"stale body"}
]}
EOF
# feed empty Enter -> takes the (staleness-forced) default of "n"
out="$(printf '\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR")"
assert_contains "changed since the snapshot" "$out" "staleness warning printed"
assert_eq "0" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "stale target defaults to skip (no post)"
assert_contains "skipped cs" "$(cat "$OUT_DIR/apply.log")" "stale target recorded skipped"

# ── Scenario F: prior comment present at capture_time must NOT trip the guard ──
fresh_out
echo '{"capture_time":"2026-06-01T00:00:00Z","gather_start":"2026-06-01T00:00:00Z","repos":{},"errors":[]}' \
  > "$OUT_DIR/snapshot.json"
# live view: OPEN, comment predates capture_time (was already there at snapshot)
echo '{"state":"OPEN","comments":[{"createdAt":"2026-01-01T00:00:00Z","author":{"login":"someone"}}]}' \
  > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"
cat > "$OUT_DIR/actions.json" <<'EOF'
{"generated_at":"t","snapshot_ref":"s","actions":[
 {"id":"cf","tier":"approval","type":"comment","repo":"jazzyalex/agent-sessions","target":{"kind":"issue","number":7},"body":"fresh enough"}
]}
EOF
out="$(printf 'y\n' | bash "$TRIAGE_ROOT/apply.sh" "$OUT_DIR")"
case "$out" in *"changed since the snapshot"*) fail "old comment must NOT trip staleness (I3)";; *) pass "pre-snapshot comment does not trip staleness (I3)";; esac
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "non-stale target posts on y"

finish
