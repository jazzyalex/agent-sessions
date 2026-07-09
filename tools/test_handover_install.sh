#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")/handover" && pwd)"
INSTALL="$SRC/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
PASSED=0; FAILED=0
pass() { echo "✓ $1"; PASSED=$((PASSED+1)); }
fail() { echo "✗ $1"; FAILED=$((FAILED+1)); }

# Ensure SKILL.md exists (stub tolerated for this task)
[ -f "$SRC/SKILL.md" ] || echo "# handover (stub)" > "$SRC/SKILL.md"

bash "$INSTALL"

CH="$HOME/.claude"
[ -f "$CH/skills/handover/SKILL.md" ] && pass "SKILL.md installed" || fail "SKILL.md missing"
[ -x "$CH/hooks/handover-offer.sh" ] && pass "hook installed + executable" || fail "hook missing/not executable"

if jq -e . "$CH/settings.json" >/dev/null 2>&1; then pass "settings.json is valid JSON"; else fail "settings.json invalid"; fi

cmd="$(jq -r '.hooks.Stop[].hooks[].command' "$CH/settings.json" 2>/dev/null | grep -c 'handover-offer.sh' || true)"
[ "$cmd" = "1" ] && pass "exactly one Stop hook entry" || fail "expected 1 Stop entry, got $cmd"

# Idempotency: run again, still exactly one
bash "$INSTALL"
cmd="$(jq -r '.hooks.Stop[].hooks[].command' "$CH/settings.json" 2>/dev/null | grep -c 'handover-offer.sh' || true)"
[ "$cmd" = "1" ] && pass "idempotent: still one Stop entry" || fail "duplicate after re-install, got $cmd"

# Preserve unrelated pre-existing settings keys
echo '{"model":"opusish","hooks":{"Stop":[]}}' > "$CH/settings.json"
bash "$INSTALL"
[ "$(jq -r '.model' "$CH/settings.json")" = "opusish" ] && pass "preserves unrelated keys" || fail "clobbered unrelated keys"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
