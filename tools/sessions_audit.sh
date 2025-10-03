#!/usr/bin/env bash
set -euo pipefail

# sessions_audit.sh — Summarize a Codex CLI sessions folder.
#
# Usage:
#   ./tools/sessions_audit.sh \
#     --root "$HOME/.codex/sessions" \
#     --out  "docs/reports/codex-sessions-audit.md"
#
# Safe: read-only; produces a Markdown report.

ROOT="${HOME}/.codex/sessions"
OUT="codex-sessions-audit.md"

have() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift; shift ;;
    --out)  OUT="$2";  shift; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "[ERROR] Sessions root not found: $ROOT" >&2
  exit 3
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

LIST="$TMP_DIR/files.txt"
find "$ROOT" -type f -name 'rollout-*.jsonl' | sort -r > "$LIST"
TOTAL=$(wc -l < "$LIST" | awk '{print $1}')

# Count by day (based on filename)
BY_DAY="$TMP_DIR/by_day.txt"
awk -F/ '{print $NF}' "$LIST" \
  | sed -E 's/^rollout-([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/' \
  | sort | uniq -c | sort -rn > "$BY_DAY"

# Files with session_id and with cwd
if have rg; then
  SID_COUNT=$(rg -l -N '"session_id"' -S -c --no-messages @"$LIST" 2>/dev/null || true)
  CWD_COUNT=$(rg -l -N '"cwd"\s*:\s*"/' -S -c --no-messages @"$LIST" 2>/dev/null || true)
else
  SID_COUNT=$(xargs -a "$LIST" -I{} sh -c 'grep -q "\"session_id\"" "{}" && echo {}' | wc -l | awk '{print $1}')
  CWD_COUNT=$(xargs -a "$LIST" -I{} sh -c 'grep -q "\"cwd\"\s*:\s*\"/" "{}" && echo {}' | wc -l | awk '{print $1}')
fi

# Top models (best-effort grep)
MODELS="$TMP_DIR/models.txt"
if have rg; then
  rg -o -N '"model"\s*:\s*"[A-Za-z0-9._-]+"' -S "$ROOT" \
    | sed -E 's/.*"model"\s*:\s*"([A-Za-z0-9._-]+)".*/\1/' \
    | sort | uniq -c | sort -rn | head -n 20 > "$MODELS"
else
  grep -Rho '"model"\s*:\s*"[A-Za-z0-9._-]\+"' "$ROOT" \
    | sed -E 's/.*"model"\s*:\s*"([A-Za-z0-9._-]+)".*/\1/' \
    | sort | uniq -c | sort -rn | head -n 20 > "$MODELS"
fi

# Top repo names from cwd (last path component)
REPOS="$TMP_DIR/repos.txt"
if have rg; then
  rg -o -N '"cwd"\s*:\s*"/[^"]+"' -S "$ROOT" \
    | sed -E 's/.*"cwd"\s*:\s*"\/(.*)"/\1/' \
    | awk -F/ '{print $NF}' \
    | sed -E 's/^\s*$//g' \
    | sort | uniq -c | sort -rn | head -n 30 > "$REPOS"
else
  grep -Rho '"cwd"\s*:\s*"/[^\"]\+"' "$ROOT" \
    | sed -E 's/.*"cwd"\s*:\s*"\/(.*)"/\1/' \
    | awk -F/ '{print $NF}' \
    | sed -E 's/^\s*$//g' \
    | sort | uniq -c | sort -rn | head -n 30 > "$REPOS"
fi

mkdir -p "$(dirname "$OUT")"

{
  echo "# Codex Sessions Audit"
  echo
  echo "Root: $ROOT  "
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
  echo
  echo "## Overview"
  echo "- Total session files: $TOTAL"
  echo "- Files with session_id: ${SID_COUNT:-0}"
  echo "- Files with cwd: ${CWD_COUNT:-0}"
  echo
  echo "## Sessions by Day (top 20)"
  echo '```'
  head -n 20 "$BY_DAY"
  echo '```'
  echo
  echo "## Top Models (best-effort)"
  echo '```'
  cat "$MODELS"
  echo '```'
  echo
  echo "## Top Repo Names from cwd (best-effort)"
  echo '```'
  cat "$REPOS"
  echo '```'
  echo
  echo "## Notes"
  echo "- 'session_id' presence is a strong indicator a file can be resumed natively."
  echo "- Some older/compacted logs may not resume on newer Codex CLI builds via explicit-path override."
  echo "- Use Agent Sessions → Preferences → Codex CLI Resume → 'Resume Log' for file-by-file diagnostics."
} > "$OUT"

echo "[OK] Wrote report to $OUT"

