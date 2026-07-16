#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"
export TRIAGE_ROOT="$HERE/.."
export POLICY_FILE="$TRIAGE_ROOT/policy.json"
source "$TRIAGE_ROOT/lib/common.sh"

# policy_get reads a scalar
assert_eq "21" "$(policy_get '.out_retention_days')" "policy retention"
assert_eq "claude" "$(policy_get '.agent')" "policy agent"
# repos is a two-element array
assert_eq "2" "$(policy_get '.repos | length')" "policy repos count"
# utc_now is Zulu ISO-8601
case "$(utc_now)" in
  ????-??-??T??:??:??Z) pass "utc_now format" ;;
  *) fail "utc_now format" ;;
esac
# lock is exclusive
LOCK="$(mktemp -d)/lock"
acquire_lock "$LOCK" && pass "first lock acquired" || fail "first lock"
if acquire_lock "$LOCK" 2>/dev/null; then fail "second lock should fail"; else pass "second lock refused"; fi
release_lock "$LOCK"
acquire_lock "$LOCK" && pass "lock reacquired after release" || fail "reacquire"
release_lock "$LOCK"
finish
