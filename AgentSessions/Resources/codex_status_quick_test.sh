#!/usr/bin/env bash

set -euo pipefail

# Quick, robust Codex /status test in tmux that:
# 1) Sends a non-reasoning marker message so the model replies immediately
# 2) Waits until the prompt returns (no "• Working ...")
# 3) Issues /status and scrolls to reveal usage bars
# 4) Prints anchors and a short context block
#
# Usage:
#   ./AgentSessions/Resources/codex_status_quick_test.sh
#   LABEL=cx-quick KEEP_TMUX=1 ./AgentSessions/Resources/codex_status_quick_test.sh
#
# Env overrides:
#   LABEL=...       tmux server label
#   MODEL=gpt-5-mini  (default)
#   THINK_WAIT=0.6  pause between key sends
#   LOOK=2.0        settle before capture

LABEL="${LABEL:-cx-quick-$$}"
TMUX_CMD="${TMUX_BIN:-tmux}"
CODEX_CMD="${CODEX_BIN:-$(command -v codex || true)}"
MODEL="${MODEL:-gpt-5-mini}"
THINK_WAIT="${THINK_WAIT:-0.6}"
LOOK="${LOOK:-2.0}"
WAIT_AFTER_MSG="${WAIT_AFTER_MSG:-10.0}"

if [[ -z "${CODEX_CMD}" ]]; then
  echo "codex not found on PATH" >&2
  exit 14
fi

WORKDIR="$(mktemp -d)"

"$TMUX_CMD" -L "$LABEL" new -d -s s "cd '$WORKDIR'; env TERM=xterm-256color '$CODEX_CMD' -m '$MODEL'"
"$TMUX_CMD" -L "$LABEL" set-option -t s history-limit 5000 >/dev/null 2>&1 || true
"$TMUX_CMD" -L "$LABEL" resize-pane -t s:0.0 -x 132 -y 48
sleep 0.8

# Dismiss initial prompt if needed
for _ in 1 2 3; do
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -p -t s:0.0 -S -200 | tr -d $'\r')"
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
    sleep "$THINK_WAIT"
  else
    break
  fi
done

is_idle_prompt() {
  # Idle when we see a bare prompt (›) and no busy/reconnecting lines nearby
  local p="$1"
  echo "$p" | grep -q "^›[[:space:]]*$" || return 1
  echo "$p" | grep -q "• Working" && return 1
  echo "$p" | grep -qi "Re-connecting" && return 1
  return 0
}

# Send the exact non-reasoning test message, then wait a fixed interval
MSG="Protocol test [AS_CX_PROBE v1].  just reply Ok"
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "$MSG"
sleep "$THINK_WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter C-m C-j
sleep "$WAIT_AFTER_MSG"

# Issue /status and deliver Enter; allow render
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "/status"
sleep "$THINK_WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter C-m C-j
sleep "$LOOK"

# Optional: nudge page a bit (commented out by default)
# for _ in 1 2 3 4 5 6; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Down; sleep 0.10; done
# for _ in 1 2 3; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 PageDown; sleep 0.20; done

pane="$($TMUX_CMD -L "$LABEL" capture-pane -J -p -t s:0.0 -S -9999 || echo "")"

echo "===== Anchors ====="
echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:|weekly[[:space:]]+limit:" || echo "(anchors not found)"

echo
echo "===== Blocks (anchor + 3 lines) ====="
echo "$pane" | awk '/5[hH]([ -])?[lL]imit:|[Ww]eekly[[:space:]]+[lL]imit:/ {print; for(i=1;i<=3;i++){getline; print}}'

echo
echo "===== First 200 lines (context) ====="
echo "$pane" | sed -n '1,200p'

echo
echo "Attach to inspect:  tmux -L $LABEL attach -t s"
if [[ "${KEEP_TMUX:-0}" != "1" ]]; then
  "$TMUX_CMD" -L "$LABEL" kill-server >/dev/null 2>&1 || true
fi
