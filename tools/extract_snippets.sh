#!/usr/bin/env bash
set -euo pipefail

# Extract likely packaging/release command snippets from Codex CLI JSONL sessions.
# Usage: ./tools/extract_snippets.sh --root "$HOME/.codex/sessions" --out snippets/collected-dmg-snippets.md

ROOT="${HOME}/.codex/sessions"
OUT="collected-dmg-snippets.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift; shift ;;
    --out)  OUT="$2";  shift; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "[ERROR] Sessions root not found: $ROOT" >&2
  exit 3
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

KEYWORDS='codesign|notarytool|stapler|hdiutil|create-dmg|ditto|spctl|productbuild|pkgbuild|appcast|sparkle'

{
  echo "# Collected DMG/Packaging Snippets"
  echo
  echo "Scanned: $ROOT"
  echo

  # Iterate newest-first by filename (Codex names begin with rollout-YYYY-MM-...)
  find "$ROOT" -type f -name 'rollout-*.jsonl' | sort -r | while read -r file; do
    # Grep lines that look like commands (reduce JSON noise)
    if rg -IN --max-count 1 -e "$KEYWORDS" "$file" > /dev/null 2>&1; then
      echo "## $(basename "$file")"
      echo
      # Pull matching lines; strip obvious JSON quoting/escapes
      rg -IN -e "$KEYWORDS" "$file" \
        | sed -E 's/\\n/ /g; s/\\"/"/g' \
        | sed -E 's/^\s+//g' \
        | sed -E 's/\s{2,}/ /g' \
        | sed -E '/^\s*$/d' \
        | tee "$TMP" > /dev/null

      if [ -s "$TMP" ]; then
        echo '```bash'
        cat "$TMP"
        echo '```'
        echo
      fi
    fi
  done
} > "$OUT"

echo "[OK] Wrote snippets to $OUT"
