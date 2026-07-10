#!/usr/bin/env bash
# Install the manual /handover skill into the global Claude config.
# Honors CLAUDE_HOME (default: $HOME/.claude). Idempotent. Never commits.
# NOTE: this installs the MANUAL skill only — no Stop hook, no settings.json changes.
# The mid-session auto-offer hook was removed (it nagged). An auto-on-close path can be
# added separately once its mechanism is chosen.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_HOME/skills/handover"

mkdir -p "$SKILL_DIR"
install -m 0644 "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md"
install -m 0755 "$SRC/handover-lint.sh" "$SKILL_DIR/handover-lint.sh"

echo "handover skill installed (manual /handover only):"
echo "  skill:  $SKILL_DIR/SKILL.md"
echo "  linter: $SKILL_DIR/handover-lint.sh"
echo "Restart any open session to pick up the new skill."
