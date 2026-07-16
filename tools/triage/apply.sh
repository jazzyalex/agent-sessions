#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

MODE="approval"; DRY=0; POSDIR=""
while [ $# -gt 0 ]; do case "$1" in
  --auto) MODE="auto";; --dry-run) DRY=1;; *) POSDIR="$1";; esac; shift; done
OUT_DIR="${POSDIR:?usage: apply.sh [--auto] [--dry-run] OUT_DIR}"
ACTIONS="$OUT_DIR/actions.json"; LEDGER="$OUT_DIR/apply.log"; touch "$LEDGER"

# Reject the whole file unless it parses AND matches the top-level schema.
jq -e '.actions and (.actions|type=="array")' "$ACTIONS" >/dev/null 2>&1 \
  || { log "actions.json malformed — rejecting whole file"; exit 4; }

do_write() { if [ "$DRY" -eq 1 ]; then echo "DRY: gh $*"; else gh "$@"; fi; }

# --- validation helpers (rules from the spec) ---
label_allowed() { policy_get '.triage_labels[]' | grep -qx "$1"; }
repo_allowed()  { policy_get '.repos[]' | grep -qx "$1"; }

apply_label() { # repo number labels-json
  local repo="$1" num="$2" labels="$3" ok=()
  repo_allowed "$repo" || { log "drop label: repo $repo not in policy"; return; }
  while IFS= read -r l; do label_allowed "$l" && ok+=("$l") || log "drop off-policy label: $l"; done \
    < <(jq -r '.[]' <<<"$labels")
  [ "${#ok[@]}" -gt 0 ] || { log "label action emptied"; return; }
  local csv; csv="$(IFS=,; echo "${ok[*]}")"
  # Record the ledger entry only once the write is confirmed — and never let a
  # single failed gh call (set -e) abort processing of the rest of the batch.
  if do_write issue edit "$num" --repo "$repo" --add-label "$csv"; then
    echo "label $repo#$num -> $csv" >> "$LEDGER"
  else
    log "label write failed: $repo#$num -> $csv"
  fi
}

ack_eligible() { # repo number  -> 0 if all live guardrails pass
  local repo="$1" num="$2"
  [ "$(policy_get '.safe_acks_enabled')" = "true" ] || return 1
  local v; v="$(gh issue view "$num" --repo "$repo" \
      --json number,author,createdAt,labels,comments,body 2>/dev/null)" || return 1
  local login created body maints fresh_h min_c now age
  login="$(jq -r '.author.login' <<<"$v")"
  policy_get '.maintainers[]' | grep -qx "$login" && return 1               # non-maintainer only
  jq -e '.comments | map(.author.login) as $a | $a' >/dev/null 2>&1 <<<"$v" || true
  # no existing maintainer comment:
  for m in $(policy_get '.maintainers[]'); do
    jq -e --arg m "$m" '.comments // [] | any(.author.login==$m)' >/dev/null <<<"$v" && return 1
  done
  jq -e '(.labels // []) | any(.name=="spam" or .name=="duplicate" or .name=="acked")' >/dev/null <<<"$v" && return 1
  min_c="$(policy_get '.ack_min_body_chars')"
  body="$(jq -r '.body // ""' <<<"$v")"; [ "${#body}" -ge "$min_c" ] || return 1
  fresh_h="$(policy_get '.ack_fresh_hours')"
  created="$(jq -r '.createdAt' <<<"$v")"
  now="$(date -u +%s)"; age=$(( (now - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$created" +%s 2>/dev/null || echo "$now")) / 3600 ))
  [ "$age" -le "$fresh_h" ] || return 1
  return 0
}

apply_ack() { # repo number kind
  local repo="$1" num="$2" kind="${3:-issue}"
  [ "$kind" = "issue" ] || { log "drop ack: target.kind=$kind not issue"; return; }
  ack_eligible "$repo" "$num" || { log "ack skipped (guardrail) $repo#$num"; return; }
  local login tmpl body
  login="$(gh issue view "$num" --repo "$repo" --json author -q '.author.login' 2>/dev/null || echo user)"
  tmpl="$(policy_get '.ack_template')"; body="${tmpl/\{user\}/$login}"
  # crash-safe: label THEN comment (at-most-once). Ledger reflects confirmed
  # writes only, and a failed label write must not proceed to the comment nor
  # abort the rest of the batch (set -e is neutralized by the if/else here).
  if do_write issue edit "$num" --repo "$repo" --add-label "acked"; then
    echo "ack-label $repo#$num" >> "$LEDGER"
  else
    log "ack-label write failed: $repo#$num"; return
  fi
  if do_write issue comment "$num" --repo "$repo" --body "$body"; then
    echo "ack $repo#$num" >> "$LEDGER"
  else
    log "ack comment write failed: $repo#$num"
  fi
}

if [ "$MODE" = "auto" ]; then
  # iterate auto actions, type-whitelisted to label|ack
  jq -c '.actions[] | select(.tier=="auto")' "$ACTIONS" | while IFS= read -r a; do
    typ="$(jq -r '.type' <<<"$a")"; repo="$(jq -r '.repo' <<<"$a")"; num="$(jq -r '.target.number' <<<"$a")"
    case "$typ" in
      label) apply_label "$repo" "$num" "$(jq -c '.labels // []' <<<"$a")" ;;
      ack)   apply_ack   "$repo" "$num" "$(jq -r '.target.kind // "issue"' <<<"$a")" ;;
      *) log "drop non-whitelisted auto action: $typ" ;;
    esac
  done
  exit 0
fi

# approval mode implemented in Task 6
exit 0
