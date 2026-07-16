#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"
export OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"

# fresh issue-view fixture inside 48h window
FRESH="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
sed "s/__FRESH__/$FRESH/" "$HERE/fixtures/gh/issue_view_eligible.json" > "$OUT_DIR/issue_view.json"
export GH_ISSUE_VIEW="$OUT_DIR/issue_view.json"

# 1) dry-run on valid actions prints a label + an ack, using the POLICY template
cp "$HERE/fixtures/actions/good_auto.json" "$OUT_DIR/actions.json"
out="$(bash "$TRIAGE_ROOT/apply.sh" --auto --dry-run "$OUT_DIR")"
assert_contains "label" "$out" "dry-run shows label"
assert_contains "taking a look" "$out" "ack uses policy template"
case "$out" in *"MODEL TRIED TO WRITE THIS"*) fail "model ack body must be ignored";; *) pass "model ack body ignored";; esac

# 2) injection: auto comment dropped, off-policy label dropped
cp "$HERE/fixtures/actions/escalation.json" "$OUT_DIR/actions.json"
out="$(bash "$TRIAGE_ROOT/apply.sh" --auto --dry-run "$OUT_DIR")"
case "$out" in *"comment"*) fail "auto comment must be dropped";; *) pass "auto comment dropped";; esac
case "$out" in *"not-a-real-label"*) fail "off-policy label must be dropped";; *) pass "off-policy label dropped";; esac

# 3) malformed actions.json rejected wholesale (non-zero)
cp "$HERE/fixtures/actions/malformed.json" "$OUT_DIR/actions.json"
if bash "$TRIAGE_ROOT/apply.sh" --auto --dry-run "$OUT_DIR" >/dev/null 2>&1; then
  fail "malformed actions must be rejected"; else pass "malformed actions rejected"; fi
finish
