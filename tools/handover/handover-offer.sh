#!/usr/bin/env bash
# Claude Code Stop hook: offer a handover once per substantive session.
# Reads hook JSON on stdin; prints a soft offer (stdout JSON) at most once/session.
# Never blocks, never writes RepoHandover.md — it only nudges. Always exits 0.
set -euo pipefail

MIN_LINES="${HANDOVER_MIN_TRANSCRIPT_LINES:-50}"
MODE="${HANDOVER_OFFER_MODE:-context}"
OFFER_TEXT="This was a substantive session. Offer the user a one-line handover they can save via the /handover skill (which appends to RepoHandover.md); do not write anything unless they say yes."

input="$(cat)"
jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# Gate 1: loop guard
[ "$(jqr '.stop_hook_active // false')" = "true" ] && exit 0

session_id="$(jqr '.session_id // ""')"
cwd="$(jqr '.cwd // ""')"
transcript="$(jqr '.transcript_path // ""')"
[ -n "$session_id" ] || exit 0

# Gate 2: once per session
sentinel="${TMPDIR:-/tmp}/claude-handover-${session_id}"
[ -e "$sentinel" ] && exit 0

# Gate 3: substantiveness — long transcript OR a dirty working tree.
tlines=0
[ -f "$transcript" ] && tlines="$(wc -l < "$transcript" | tr -d '[:space:]')"
dirty=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git -C "$cwd" status --porcelain 2>/dev/null | head -1)"
fi
substantive=false
[ "${tlines:-0}" -ge "$MIN_LINES" ] && substantive=true
[ -n "$dirty" ] && substantive=true
[ "$substantive" = true ] || exit 0

# All gates passed: mark sentinel, emit the soft offer.
: > "$sentinel" 2>/dev/null || true
if [ "$MODE" = "systemMessage" ]; then
  jq -n --arg m "$OFFER_TEXT" '{systemMessage:$m}'
else
  jq -n --arg m "$OFFER_TEXT" \
    '{hookSpecificOutput:{hookEventName:"Stop", additionalContext:$m}}'
fi
exit 0
