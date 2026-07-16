#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

OUT_DIR="${OUT_DIR:?OUT_DIR required}"; mkdir -p "$OUT_DIR"
LAST_RUN="${LAST_RUN:?LAST_RUN required}"
GATHER_START="$(utc_now)"
ERR_FILE="$(mktemp)"; trap 'rm -f "$ERR_FILE"' EXIT
REPOS_JSON='{}'

# fetch() runs inside $(...) (a subshell), so mutating a variable there is lost.
# record_error appends one JSON object per line to a sidecar FILE instead —
# file appends survive the subshell; we slurp them into an array at the end.
record_error() { jq -cn --arg s "$1" --arg e "$2" '{source:$s,error:$e}' >> "$ERR_FILE"; }

# fetch <source-label> <jq-default> <gh args...>  -> echoes JSON or records error and echoes default
fetch() {
  local label="$1" dflt="$2"; shift 2
  local out
  if out="$(gh "$@" 2>/dev/null)"; then printf '%s' "$out"
  else record_error "$label" "gh failed"; printf '%s' "$dflt"; fi
}

for repo in $(policy_get '.repos[]'); do
  issues="$(fetch "issue list:$repo" '[]' issue list --repo "$repo" --state open \
             --json number,title,author,createdAt,labels,body)"
  prs="$(fetch "pr list:$repo" '[]' pr list --repo "$repo" --state open \
             --json number,title,author,mergeable,statusCheckRollup)"
  icmts="$(fetch "issue comments:$repo" '[]' api \
             "repos/$repo/issues/comments?since=$LAST_RUN")"
  pcmts="$(fetch "pr comments:$repo" '[]' api \
             "repos/$repo/pulls/comments?since=$LAST_RUN")"
  # discussions: main repo only (tap has them disabled)
  discs='[]'
  if [ "$repo" = "jazzyalex/agent-sessions" ]; then
    graphql='query($o:String!,$n:String!){repository(owner:$o,name:$n){discussions(first:50){nodes{number title updatedAt}}}}'
    owner="${repo%%/*}"; name="${repo##*/}"
    raw="$(fetch "discussions:$repo" '{}' api graphql -f query="$graphql" -F o="$owner" -F n="$name")"
    discs="$(jq -c --arg since "$LAST_RUN" \
      '(.data.repository.discussions.nodes // []) | map(select(.updatedAt >= $since))' <<<"$raw")"
  fi
  new_comments="$(jq -c -s 'add' <(printf '%s' "$icmts") <(printf '%s' "$pcmts"))"
  REPOS_JSON="$(jq -c --arg r "$repo" \
      --argjson issues "$issues" --argjson prs "$prs" \
      --argjson discs "$discs" --argjson nc "$new_comments" \
      '. + {($r):{issues:$issues,prs:$prs,discussions:$discs,new_comments:$nc}}' <<<"$REPOS_JSON")"
done

ERRORS="$(jq -cs '.' "$ERR_FILE")"   # slurp sidecar ndjson into an array ([] if empty)
jq -n --arg cap "$(utc_now)" --arg gs "$GATHER_START" --arg lr "$LAST_RUN" \
      --argjson repos "$REPOS_JSON" --argjson errors "$ERRORS" \
      '{capture_time:$cap,gather_start:$gs,last_run:$lr,repos:$repos,errors:$errors}' \
      > "$OUT_DIR/snapshot.json"
