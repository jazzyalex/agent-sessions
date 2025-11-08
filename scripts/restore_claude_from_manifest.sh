#!/usr/bin/env bash
# Restore Claude sessions listed in the manifest, excluding the true probe project.
# Tries Time Machine latest backup first. Does NOT delete anything.

set -euo pipefail

MANIFEST=${1:-scripts/probe_scan_output/claude_probe_sessions.txt}
EXCLUDE_PREFIX="${EXCLUDE_PREFIX:-$HOME/.claude/projects/-Users-alexm-Library-Application-Support-AgentSessions-ClaudeProbeProject/}"
OUT_DIR="scripts/probe_scan_output"
RESTORE_LIST="$OUT_DIR/claude_restore_candidates.txt"
MISSING_LIST="$OUT_DIR/claude_missing_to_restore.txt"
NOTFOUND_LIST="$OUT_DIR/claude_restore_notfound.txt"
RESTORED_LIST="$OUT_DIR/claude_restored.txt"

mkdir -p "$OUT_DIR"
>"$RESTORE_LIST"; >"$MISSING_LIST"; >"$NOTFOUND_LIST"; >"$RESTORED_LIST"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 2
fi

# 1) Candidates excluding the true probe project path
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    "$EXCLUDE_PREFIX"*) continue;;
  esac
  echo "$f" >> "$RESTORE_LIST"
done < "$MANIFEST"

TOTAL=$(wc -l < "$RESTORE_LIST" | tr -d ' ')

# 2) Split into existing vs missing
while IFS= read -r f; do
  [[ -f "$f" ]] || echo "$f" >> "$MISSING_LIST"
done < "$RESTORE_LIST"

MISSING=$(wc -l < "$MISSING_LIST" | tr -d ' ')
EXISTING=$((TOTAL - MISSING))

echo "Claude restore audit"
echo "- Total candidates (excluding probe dir): $TOTAL"
echo "- Already present: $EXISTING"
echo "- Missing (need restore): $MISSING"

if [[ "$MISSING" -eq 0 ]]; then
  echo "Nothing to restore."
  exit 0
fi

# 3) Attempt restore from latest Time Machine backup, if available
LATEST="${BACKUP_ROOT:-$(tmutil latestbackup 2>/dev/null || true)}"
if [[ -z "$LATEST" ]]; then
  echo "No Time Machine backup found via tmutil, and BACKUP_ROOT not set." >&2
  echo "Set BACKUP_ROOT to your backup snapshot or mount (e.g., \"/Volumes/Time Machine/Backups.backupdb/<MacName>/<date>\")." >&2
  echo "List of missing files recorded at $MISSING_LIST" >&2
  exit 3
fi

echo "Attempting restore from: $LATEST"

RESTORED=0
NOTFOUND=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # Map /Users/alexm/... → */Users/alexm/...
  rel="${f#/}"
  # Search the latest backup for the relative path (first hit)
  candidate=$(find "$LATEST" -type f -path "*/$rel" -print -quit 2>/dev/null || true)
  if [[ -n "$candidate" ]]; then
    mkdir -p "$(dirname "$f")"
    cp -p "$candidate" "$f"
    echo "$f" >> "$RESTORED_LIST"
    RESTORED=$((RESTORED+1))
  else
    echo "$f" >> "$NOTFOUND_LIST"
    NOTFOUND=$((NOTFOUND+1))
  fi
done < "$MISSING_LIST"

echo "Restore complete"
echo "- Restored: $RESTORED (list: $RESTORED_LIST)"
echo "- Not found in latest backup: $NOTFOUND (list: $NOTFOUND_LIST)"

exit 0
