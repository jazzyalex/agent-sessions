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

bash "$INSTALL"

CH="$HOME/.claude"
[ -f "$CH/skills/handover/SKILL.md" ] && pass "SKILL.md installed" || fail "SKILL.md missing"
[ -x "$CH/skills/handover/handover-lint.sh" ] && pass "linter installed + executable" || fail "linter missing/not executable"

# Manual-only install must NOT create/modify settings.json and must NOT wire any hook.
[ ! -f "$CH/settings.json" ] && pass "no settings.json written (manual-only)" || fail "settings.json should not be touched"
[ ! -e "$CH/hooks/handover-offer.sh" ] && pass "no Stop hook installed (no nag)" || fail "hook should not be installed"

# Idempotency: run again, still fine
bash "$INSTALL"
[ -f "$CH/skills/handover/SKILL.md" ] && pass "idempotent re-install ok" || fail "re-install broke"

# Preserve a pre-existing settings.json untouched
mkdir -p "$CH"; echo '{"model":"opusish"}' > "$CH/settings.json"
bash "$INSTALL"
[ "$(jq -r '.model' "$CH/settings.json")" = "opusish" ] && [ "$(jq -r '.hooks // "none"' "$CH/settings.json")" = "none" ] \
  && pass "pre-existing settings.json left untouched" || fail "settings.json was modified"

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
