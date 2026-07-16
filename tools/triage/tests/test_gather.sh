#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
export GH_FIXTURE_DIR="$HERE/fixtures/gh"
export OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
export LAST_RUN="2026-07-15T08:00:00Z"

# happy path
bash "$TRIAGE_ROOT/gather.sh"
assert_file_exists "$OUT_DIR/snapshot.json" "snapshot written"
assert_eq "0" "$(jq '.errors | length' "$OUT_DIR/snapshot.json")" "no errors on happy path"
assert_eq "UNKNOWN" "$(jq -r '.repos["jazzyalex/agent-sessions"].prs[0].mergeable' "$OUT_DIR/snapshot.json")" "mergeable recorded verbatim"
assert_eq "7" "$(jq -r '.repos["jazzyalex/agent-sessions"].issues[0].number' "$OUT_DIR/snapshot.json")" "issue captured"
case "$(jq -r '.gather_start' "$OUT_DIR/snapshot.json")" in ????-??-??T??:??:??Z) pass "gather_start UTC";; *) fail "gather_start UTC";; esac

# partial failure path: issue list fails for one source -> recorded, not fatal
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
GH_FAIL_SOURCE="issue list" bash "$TRIAGE_ROOT/gather.sh"
assert_file_exists "$OUT_DIR/snapshot.json" "snapshot still written on partial failure"
if [ "$(jq '.errors | length' "$OUT_DIR/snapshot.json")" -ge 1 ]; then pass "error recorded"; else fail "error recorded"; fi
finish
