#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"
export TRIAGE_ROOT="$HERE/.."
export POLICY_FILE="$TRIAGE_ROOT/policy.json"
source "$TRIAGE_ROOT/lib/common.sh"

# policy_get reads scalars + arrays
assert_eq "claude" "$(policy_get '.agent')" "policy agent"
assert_eq "claude-sonnet-5" "$(policy_get '.agent_model')" "policy agent_model"
assert_eq "48" "$(policy_get '.lookback_hours')" "policy lookback_hours"
assert_eq "2" "$(policy_get '.repos | length')" "policy repos count"
# utc_now is Zulu ISO-8601
case "$(utc_now)" in
  ????-??-??T??:??:??Z) pass "utc_now format" ;;
  *) fail "utc_now format" ;;
esac
# require_cmd succeeds for a present binary, fails for an absent one
require_cmd jq && pass "require_cmd finds jq" || fail "require_cmd finds jq"
if require_cmd definitely-not-a-real-binary 2>/dev/null; then fail "require_cmd should fail on missing"; else pass "require_cmd fails on missing"; fi
finish
