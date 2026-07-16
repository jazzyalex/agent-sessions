#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
OUT_DIR="$(mktemp -d)/out"; mkdir -p "$OUT_DIR"
export GH_WRITE_LOG="$OUT_DIR/writes.log"; : > "$GH_WRITE_LOG"
cat > "$OUT_DIR/replies.json" <<'EOF'
[{"id":"R1","repo":"jazzyalex/agent-sessions","number":12,"kind":"issue","body":"Thanks, taking a look."},
 {"id":"R2","repo":"attacker/evil","number":1,"kind":"issue","body":"pwned"},
 {"id":"R3","repo":"jazzyalex/agent-sessions","number":"--web","kind":"issue","body":"flag injection"}]
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

# non-integer number refused (would otherwise land in gh flag position)
if printf 'y\n' | bash "$TRIAGE_ROOT/reply.sh" R3 "$OUT_DIR" >/dev/null 2>&1; then
  fail "non-integer number should be refused"; else pass "non-integer number refused"; fi
assert_eq "1" "$(grep -c 'issue comment' "$GH_WRITE_LOG")" "no bad posts landed"

# duplicate id refused (would defeat the single-repo allowlist)
DUP="$(mktemp -d)/out"; mkdir -p "$DUP"; : > "$DUP/writes.log"
cat > "$DUP/replies.json" <<'EOF'
[{"id":"R1","repo":"jazzyalex/agent-sessions","number":12,"kind":"issue","body":"ok"},
 {"id":"R1","repo":"attacker/evil","number":1,"kind":"issue","body":"pwned"}]
EOF
if printf 'y\n' | GH_WRITE_LOG="$DUP/writes.log" bash "$TRIAGE_ROOT/reply.sh" R1 "$DUP" >/dev/null 2>&1; then
  fail "duplicate id should be refused"; else pass "duplicate id refused"; fi
assert_eq "0" "$(grep -c 'issue comment' "$DUP/writes.log")" "no post on duplicate id"

# control chars stripped from the preview so what you read is the true content.
# jq encodes the ESC as  in the file; jq -r in reply.sh decodes it back to
# a real ESC, which in a raw terminal would erase the "SAFE" prefix.
CTL="$(mktemp -d)/out"; mkdir -p "$CTL"
jq -nc '[{id:"R1",repo:"jazzyalex/agent-sessions",number:9,kind:"issue",body:"SAFE[2K[1AHIDDEN"}]' > "$CTL/replies.json"
out="$(printf 'n\n' | bash "$TRIAGE_ROOT/reply.sh" R1 "$CTL" 2>/dev/null)"
if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; then
  fail "preview must strip ESC control chars"; else pass "preview strips ESC control chars"; fi
assert_contains "HIDDEN" "$out" "preview shows the true (previously hidden) text"
finish
