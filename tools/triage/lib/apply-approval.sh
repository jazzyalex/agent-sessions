#!/usr/bin/env bash
# run_approval OUT_DIR DRY — interactive approval tier.
#
# Idempotency: an action's id is skipped once "posted <id>" is present in the
# ledger (OUT_DIR/apply.log), so re-running never double-posts.
#
# Staleness guard: before prompting, the live target is re-fetched. If it is
# closed/merged, or has picked up comments *newer than* the snapshot's
# capture_time, the maintainer is warned and the prompt defaults to "n" instead
# of trusting the stale snapshot. The comparison is snapshot-relative — prior
# discussion that was already present at capture time must NOT trip the guard,
# only genuinely new activity since then. When capture_time is unavailable we
# fall back to the conservative "any comment trips it" behavior.
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

  # Snapshot capture time — the reference point for "new since snapshot".
  # Empty when snapshot.json is missing/lacks the field; the guard then falls
  # back to the conservative "any comment trips it" branch below.
  local CAP
  CAP="$(jq -r '.capture_time // empty' "$OUT_DIR/snapshot.json" 2>/dev/null || true)"

  local a
  while IFS= read -r a <&3; do
    local id typ repo num body
    id="$(jq -r '.id' <<<"$a")"
    # grep -qxF: exact, whole-line, FIXED-STRING match — the id is untrusted
    # (from the injection-tainted actions.json), so regex metacharacters must
    # be matched literally (same -qxF convention as label_allowed/repo_allowed).
    if grep -qxF "posted $id" "$LEDGER"; then
      echo "skip $id (already posted)"
      continue
    fi
    typ="$(jq -r '.type' <<<"$a")"
    repo="$(jq -r '.repo' <<<"$a")"
    num="$(jq -r '.target.number' <<<"$a")"
    body="$(jq -r '.body // ""' <<<"$a")"

    # Staleness guard — snapshot-relative.
    local dflt="y" live stale=0
    live="$(gh issue view "$num" --repo "$repo" --json state,comments 2>/dev/null || echo '{}')"
    jq -e '.state=="CLOSED" or .state=="MERGED"' >/dev/null 2>&1 <<<"$live" && stale=1
    if [ -n "$CAP" ]; then
      jq -e --arg cap "$CAP" '(.comments // []) | any(.createdAt > $cap)' \
        >/dev/null 2>&1 <<<"$live" && stale=1
    else
      jq -e '(.comments // []) | length > 0' >/dev/null 2>&1 <<<"$live" && stale=1
    fi
    if [ "$stale" -eq 1 ]; then
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
              # DRY must NOT touch the ledger: recording "posted" on a dry-run
              # would make a later REAL run on the same OUT_DIR skip this id via
              # the idempotency guard, so the comment would never actually post.
              # Only a real, successful post records "posted <id>".
              if [ "$DRY" -eq 1 ]; then
                echo "DRY: gh issue comment $num --repo $repo --body $body"
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
