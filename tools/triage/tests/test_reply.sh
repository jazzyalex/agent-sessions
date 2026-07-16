#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
export GH_WRITE_LOG="$OUT_DIR/writes.log"; : > "$GH_WRITE_LOG"
cat > "$OUT_DIR/replies.json" <<'EOF'
[{"id":"R1","repo":"jazzyalex/agent-sessions","number":12,"kind":"issue","body":"Thanks, taking a look."},
 {"id":"R2","repo":"attacker/evil","number":1,"kind":"issue","body":"pwned"}]
EOF

# y posts the reply via gh
printf 'y\n' | bash "$TRIAGE_ROOT/reply.sh" R1 "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "reply posted on y"

# n does not post
printf 'n\n' | bash "$TRIAGE_ROOT/reply.sh" R1 "$OUT_DIR" >/dev/null
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "no post on n"

# unknown id errors, no post
if printf 'y\n' | bash "$TRIAGE_ROOT/reply.sh" NOPE "$OUT_DIR" >/dev/null 2>&1; then
  fail "unknown id should error"; else pass "unknown id errors"; fi

# out-of-policy repo refused even on y
if printf 'y\n' | bash "$TRIAGE_ROOT/reply.sh" R2 "$OUT_DIR" >/dev/null 2>&1; then
  fail "out-of-policy repo should be refused"; else pass "out-of-policy repo refused"; fi
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "no post to out-of-policy repo"
finish
