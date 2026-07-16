#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"
export OUT_ROOT="$(mktemp -d)/out"; export STATE_FILE="$(mktemp -d)/state.json"
# NOTE: the real PROMPT.md exists since Task 3 — do not overwrite it here.

# time gate: before 08:00 -> no run
NOW_HHMM="0600" bash "$TRIAGE_ROOT/triage.sh" || true
assert_eq "0" "$(find "$OUT_ROOT" -name status.json 2>/dev/null | wc -l | tr -d ' ')" "no run before 08:00"

# at/after 08:00, first run -> produces status.json success and advances lastRun
NOW_HHMM="1000" bash "$TRIAGE_ROOT/triage.sh"
assert_eq "1" "$(find "$OUT_ROOT" -name status.json | wc -l | tr -d ' ')" "one run after 08:00"
assert_contains "success" "$(cat "$OUT_ROOT"/*/status.json)" "status success"
assert_file_exists "$STATE_FILE" "state written"

# second invocation same day -> catch-up gate skips (still one run)
NOW_HHMM="1100" bash "$TRIAGE_ROOT/triage.sh" || true
assert_eq "1" "$(find "$OUT_ROOT" -name status.json | wc -l | tr -d ' ')" "catch-up skips completed day"

# C1 regression: a `failed` status.json must NOT count as "today done" — a later
# same-day catch-up run must re-attempt and overwrite it (gate is value-aware).
FAIL_ROOT="$(mktemp -d)/out"; FAIL_STATE="$(mktemp -d)/state.json"
TODAY="$(date +%Y-%m-%d)"
mkdir -p "$FAIL_ROOT/$TODAY"
echo '{"status":"failed","at":"2026-07-16T08:05:00Z"}' > "$FAIL_ROOT/$TODAY/status.json"
echo '{"lastRun":"2000-01-01T00:00:00Z"}' > "$FAIL_STATE"   # seed an OLD lastRun to prove advancement
OUT_ROOT="$FAIL_ROOT" STATE_FILE="$FAIL_STATE" NOW_HHMM="1000" bash "$TRIAGE_ROOT/triage.sh"
assert_contains "success" "$(cat "$FAIL_ROOT/$TODAY/status.json")" "failed marker is retried and overwritten with success"
case "$(jq -r '.lastRun' "$FAIL_STATE")" in
  2000-01-01*) fail "lastRun advanced past the seeded failed-run value";;
  *)           pass "lastRun advanced past the seeded failed-run value";;
esac
finish
