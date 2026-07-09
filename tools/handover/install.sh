#!/usr/bin/env bash
# Install the handover skill + Stop hook into the global Claude config.
# Honors CLAUDE_HOME (default: $HOME/.claude). Idempotent. Never commits.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILL_DIR="$CLAUDE_HOME/skills/handover"
HOOK_DIR="$CLAUDE_HOME/hooks"
SETTINGS="$CLAUDE_HOME/settings.json"
HOOK_DST="$HOOK_DIR/handover-offer.sh"

mkdir -p "$SKILL_DIR" "$HOOK_DIR"

install -m 0644 "$SRC/SKILL.md" "$SKILL_DIR/SKILL.md"
install -m 0755 "$SRC/handover-lint.sh" "$SKILL_DIR/handover-lint.sh"
install -m 0755 "$SRC/handover-offer.sh" "$HOOK_DST"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "install: $SETTINGS is not valid JSON; refusing to modify" >&2
  exit 1
fi

tmp="$(mktemp)"
jq --arg cmd "$HOOK_DST" '
  .hooks //= {} |
  .hooks.Stop //= [] |
  # Drop any prior entry that references our hook, then add a fresh one (idempotent).
  .hooks.Stop |= map(select((.hooks // [] | map(.command) | index($cmd)) | not)) |
  .hooks.Stop += [ { "matcher": "", "hooks": [ { "type": "command", "command": $cmd, "timeout": 10 } ] } ]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "handover installed:"
echo "  skill:    $SKILL_DIR/SKILL.md"
echo "  linter:   $SKILL_DIR/handover-lint.sh"
echo "  hook:     $HOOK_DST"
echo "  settings: $SETTINGS (Stop hook merged)"
