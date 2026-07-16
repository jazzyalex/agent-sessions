#!/usr/bin/env bash
# run_approval OUT_DIR DRY — interactive approval tier.
#
# Idempotency: an action's id is skipped once "posted <id>" is present in the
# ledger (OUT_DIR/apply.log), so re-running never double-posts.
#
# Staleness guard: before prompting, the live target is re-fetched. If it is
# closed/merged, or has picked up new comments since the snapshot was
# captured, the maintainer is warned and the prompt defaults to "n" instead of
# trusting the stale snapshot.
#
# stdin footgun (why this isn't `jq ... | while read -r a; do ... done`):
# piping jq's output straight into the while loop rebinds fd 0 for the WHOLE
# loop body to jq's stream. Any nested `read -r -p ... ans` inside that body
# would then read from the (already-exhausted) jq stream instead of the real
# interactive stdin -- every prompt hits immediate EOF and silently falls back
# to its default, no matter what the maintainer actually types. Feeding the
# action list via fd 3 (a process substitution) keeps fd 0 free and correctly
# bound to the real interactive stdin for the `read -r -p` prompts.
run_approval() {
  local OUT_DIR="$1" DRY="$2"
  local ACTIONS="$OUT_DIR/actions.json" LEDGER="$OUT_DIR/apply.log"
  touch "$LEDGER"

  local a
  while IFS= read -r a <&3; do
    local id typ repo num body
    id="$(jq -r '.id' <<<"$a")"
    if grep -qx "posted $id" "$LEDGER"; then
      echo "skip $id (already posted)"
      continue
    fi
    typ="$(jq -r '.type' <<<"$a")"
    repo="$(jq -r '.repo' <<<"$a")"
    num="$(jq -r '.target.number' <<<"$a")"
    body="$(jq -r '.body // ""' <<<"$a")"

    # Staleness guard.
    local dflt="y" live
    live="$(gh issue view "$num" --repo "$repo" --json state,comments 2>/dev/null || echo '{}')"
    if jq -e '(.state=="CLOSED" or .state=="MERGED") or ((.comments // []) | length > 0)' \
         >/dev/null 2>&1 <<<"$live"; then
      echo "WARNING: $repo#$num changed since the snapshot was captured (closed/merged or new comments)"
      dflt="n"
    fi

    while true; do
      echo "---- $typ  $repo#$num ----"
      echo "$body" | sed 's/^/  | /'
      local ans
      read -r -p "[y]es / [n]o / [e]dit (default $dflt): " ans || ans=""
      ans="${ans:-$dflt}"
      case "$ans" in
        e|E)
          local tmp
          tmp="$(mktemp)"
          printf '%s\n' "$body" > "$tmp"
          "${VISUAL:-${EDITOR:-vi}}" "$tmp"
          body="$(cat "$tmp")"
          rm -f "$tmp"
          continue
          ;;
        y|Y)
          case "$typ" in
            comment)
              if [ "$DRY" -eq 1 ]; then
                echo "DRY: gh issue comment $num --repo $repo --body $body"
                echo "posted $id" >> "$LEDGER"
              elif gh issue comment "$num" --repo "$repo" --body "$body"; then
                echo "posted $id" >> "$LEDGER"
              else
                echo "post failed: $repo#$num ($id)" >&2
              fi
              ;;
            *)
              echo "skip $id: unsupported approval type '$typ'" >&2
              echo "skipped $id" >> "$LEDGER"
              ;;
          esac
          break
          ;;
        *)
          echo "skipped $id" >> "$LEDGER"
          break
          ;;
      esac
    done
  done 3< <(jq -c '.actions[] | select(.tier=="approval")' "$ACTIONS")
}
