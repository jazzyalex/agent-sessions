#!/usr/bin/env bash
set -euo pipefail

HOOK="$(dirname "$0")/handover/handover-offer.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# make_input <session_id> <cwd> <transcript> <stop_active>
make_input() {
  jq -n --arg s "$1" --arg c "$2" --arg t "$3" --argjson a "$4" \
    '{session_id:$s, cwd:$c, transcript_path:$t, stop_hook_active:$a}'
}

# A substantive transcript (>= 50 lines) and a trivial one
BIG="$WORK/big.jsonl";  for i in $(seq 1 60); do echo "{\"i\":$i}"; done > "$BIG"
SMALL="$WORK/small.jsonl"; echo '{"i":1}' > "$SMALL"
REPO="$WORK/repo"; mkdir -p "$REPO"   # not a git repo; substantiveness comes from transcript size

# 1. all gates pass -> emits additionalContext offer
out="$(make_input sess1 "$REPO" "$BIG" false | HANDOVER_OFFER_MODE=context bash "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("handover")' >/dev/null 2>&1; then
  pass "substantive session emits additionalContext offer"; else fail "expected offer, got: $out"; fi

# 2. sentinel now exists -> second call is silent
out="$(make_input sess1 "$REPO" "$BIG" false | bash "$HOOK")"
[ -z "$out" ] && pass "once-per-session: second call silent" || fail "second call should be silent, got: $out"

# 3. stop_hook_active=true -> silent (loop guard), fresh session
out="$(make_input sess2 "$REPO" "$BIG" true | bash "$HOOK")"
[ -z "$out" ] && pass "loop guard: stop_hook_active silent" || fail "loop guard failed, got: $out"

# 4. trivial session (short transcript, no git changes) -> silent
out="$(make_input sess3 "$REPO" "$SMALL" false | bash "$HOOK")"
[ -z "$out" ] && pass "trivial session stays silent" || fail "trivial should be silent, got: $out"

# 5. systemMessage mode
out="$(make_input sess4 "$REPO" "$BIG" false | HANDOVER_OFFER_MODE=systemMessage bash "$HOOK")"
if echo "$out" | jq -e '.systemMessage | test("handover")' >/dev/null 2>&1; then
  pass "systemMessage mode emits systemMessage"; else fail "expected systemMessage, got: $out"; fi

# 6. git-dirty short session -> offers (git signal ORs in)
GITREPO="$WORK/gitrepo"; mkdir -p "$GITREPO"
git -C "$GITREPO" init -q && echo x > "$GITREPO/f.txt"   # untracked change = dirty
out="$(make_input sess5 "$GITREPO" "$SMALL" false | bash "$HOOK")"
if echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "git-dirty short session offers"; else fail "git-dirty should offer, got: $out"; fi

# 7. always exits 0 even on gate fail
if make_input sess6 "$REPO" "$SMALL" false | bash "$HOOK" >/dev/null 2>&1; then
  pass "exits 0 on silent path"; else fail "should exit 0"; fi

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
