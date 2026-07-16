#!/usr/bin/env bash
# reply.sh <id> [OUT_DIR] — post one agent-suggested reply after you confirm it.
# Looks the id up in the newest run's replies.json (or the given OUT_DIR),
# shows the exact target + text, and posts via gh only on an explicit y.
# You are the gate: nothing posts without your yes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

ID="${1:?usage: reply.sh <id> [OUT_DIR]}"
OUT_DIR="${2:-}"
if [ -z "$OUT_DIR" ]; then
  REPLIES="$(ls -dt "${OUT_ROOT:-$HERE/out}"/*/replies.json 2>/dev/null | head -1 || true)"
else
  REPLIES="$OUT_DIR/replies.json"
fi
[ -n "${REPLIES:-}" ] && [ -f "$REPLIES" ] || { echo "no replies.json found (run triage.sh first)"; exit 1; }

r="$(jq -c --arg id "$ID" '.[] | select(.id==$id)' "$REPLIES" 2>/dev/null || true)"
[ -n "$r" ] || { echo "no reply with id '$ID' in $REPLIES"; exit 1; }

repo="$(jq -r '.repo' <<<"$r")"
num="$(jq -r '.number' <<<"$r")"
kind="$(jq -r '.kind // "issue"' <<<"$r")"
body="$(jq -r '.body' <<<"$r")"

# One cheap guard worth keeping: the repo field comes from the model, so refuse
# to post outside the watched repos even if you fat-finger the confirm.
policy_get '.repos[]' | grep -qxF "$repo" || { echo "refusing: $repo is not in policy.repos"; exit 1; }

echo "post to ${repo}#${num} (${kind}):"
echo "$body" | sed 's/^/  | /'
printf 'post this? [y/N] '
read -r ans
case "$ans" in
  y|Y)
    if [ "$kind" = "pr" ]; then gh pr comment "$num" --repo "$repo" --body "$body"
    else gh issue comment "$num" --repo "$repo" --body "$body"; fi
    echo "posted." ;;
  *) echo "skipped." ;;
esac
