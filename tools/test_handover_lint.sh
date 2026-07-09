#!/usr/bin/env bash
set -euo pipefail

LINT="$(dirname "$0")/handover/handover-lint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# assert_exit <expected-code> <file> <label>
assert_exit() {
  local want="$1" file="$2" label="$3" got=0
  bash "$LINT" "$file" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (want exit $want, got $got)"; fi
}

# Valid entry
cat > "$WORK/good.md" <<'EOF'
## 2026-07-09 14:32 · runway-auth · AS-owned OAuth (P2)
status: in-progress
branch: main @ 9ade2753 (dirty: 2 files)

**State in one line:** next is P2.
EOF
assert_exit 0 "$WORK/good.md" "valid entry passes"

# superseded-by status is valid
cat > "$WORK/superseded.md" <<'EOF'
## 2026-07-09 14:32 · runway-auth · title
status: superseded-by:2026-07-10
branch: main @ abc1234 (clean)
EOF
assert_exit 0 "$WORK/superseded.md" "superseded-by status passes"

# Bad status value
cat > "$WORK/badstatus.md" <<'EOF'
## 2026-07-09 14:32 · slug · title
status: wip
branch: main @ abc1234
EOF
assert_exit 1 "$WORK/badstatus.md" "invalid status fails"

# Missing branch line
cat > "$WORK/nobranch.md" <<'EOF'
## 2026-07-09 14:32 · slug · title
status: done
**State:** x
EOF
assert_exit 1 "$WORK/nobranch.md" "missing branch line fails"

# Heading without timestamp
cat > "$WORK/badhead.md" <<'EOF'
## runway-auth notes
status: done
branch: main
EOF
assert_exit 1 "$WORK/badhead.md" "heading without timestamp fails"

# Empty file
: > "$WORK/empty.md"
assert_exit 1 "$WORK/empty.md" "empty file fails"

# Missing file
assert_exit 1 "$WORK/does-not-exist.md" "missing file fails"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
