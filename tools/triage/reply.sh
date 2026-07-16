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

# Select EXACTLY one reply. Duplicate ids would otherwise yield a multi-object
# stream whose multiline fields slip the single-repo allowlist below.
n="$(jq --arg id "$ID" '[.[]|select(.id==$id)]|length' "$REPLIES" 2>/dev/null || echo 0)"
[ "$n" = "1" ] || { echo "expected exactly one reply with id '$ID' in $REPLIES (found $n)"; exit 1; }
r="$(jq -c --arg id "$ID" 'map(select(.id==$id))|.[0]' "$REPLIES")"

repo="$(jq -r '.repo' <<<"$r")"
num="$(jq -r '.number' <<<"$r")"
kind="$(jq -r '.kind // "issue"' <<<"$r")"
body="$(jq -r '.body' <<<"$r")"

# repo/number/kind all originate from the (untrusted) model output. You are the
# final gate, but validate the machine-usable fields so a crafted value can't
# turn into a gh flag or a wrong-repo post: number must be a plain integer (else
# e.g. "--web" lands in flag position), repo must be watched, kind is issue|pr.
[[ "$num" =~ ^[0-9]+$ ]] || { echo "refusing: '$num' is not a valid issue/PR number"; exit 1; }
policy_get '.repos[]' | grep -qxF "$repo" || { echo "refusing: $repo is not in policy.repos"; exit 1; }
[ "$kind" = "issue" ] || [ "$kind" = "pr" ] || { echo "refusing: unknown kind '$kind'"; exit 1; }

# Strip control chars from the PREVIEW (keep tab + newline) so terminal escapes
# in the body can't erase text and spoof what you approve. The posted body is the
# raw value — GitHub renders it — but what you read here is the true content.
echo "post to ${repo}#${num} (${kind}):"
printf '%s\n' "$body" | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/  | /'
printf 'post this? [y/N] '
read -r ans
case "$ans" in
  y|Y)
    if [ "$kind" = "pr" ]; then gh pr comment "$num" --repo "$repo" --body "$body"
    else gh issue comment "$num" --repo "$repo" --body "$body"; fi
    echo "posted." ;;
  *) echo "skipped." ;;
esac
