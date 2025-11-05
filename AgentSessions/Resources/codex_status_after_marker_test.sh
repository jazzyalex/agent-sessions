#!/usr/bin/env bash

set -euo pipefail

# Purpose: prove end-to-end that Codex accepts the probe marker AND a subsequent /status
# via tmux, and that we can see the usage anchors in the captured pane.
# This mirrors the working marker flow, then adds /status + light scrolling.
#
# Env overrides:
#   LABEL=cx-status-keep   (tmux server label; default random)
#   MODEL=gpt-5            (Codex model)
#   KEEP_TMUX=1            (keep tmux session alive for attach)
#   WAIT=0.6               (pause between key sends)
#   LOOK=2.0               (settle before capture)

LABEL="${LABEL:-cx-status-$$}"
TMUX_CMD="${TMUX_BIN:-tmux}"
CODEX_CMD="${CODEX_BIN:-$(command -v codex || true)}"
MODEL="${MODEL:-gpt-5}"
WAIT="${WAIT:-0.6}"
LOOK="${LOOK:-2.0}"

if [[ -z "${CODEX_CMD}" ]]; then
  echo "codex not found on PATH" >&2
  exit 14
fi

WORKDIR="$(mktemp -d)"

# 1) Launch Codex in tmux (detached), large pane
"$TMUX_CMD" -L "$LABEL" new -d -s s "cd '$WORKDIR'; env TERM=xterm-256color '$CODEX_CMD' -m '$MODEL'"
"$TMUX_CMD" -L "$LABEL" set-option -t s history-limit 5000 >/dev/null 2>&1 || true
"$TMUX_CMD" -L "$LABEL" resize-pane -t s:0.0 -x 132 -y 48
sleep 0.8

# 2) Dismiss initial approval prompt if present
for _ in 1 2 3; do
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -p -t s:0.0 -S -200 | tr -d $'\r')"
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
    sleep "$WAIT"
  else
    break
  fi
done

# 3) Send probe marker and verify Enter delivery (as in working marker test)
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "[AS_CX_PROBE v1]"
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-j
sleep "$LOOK"

# 4) Now issue /status and deliver Enter (variants), then nudge the page
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "/status"
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-j
sleep "$LOOK"

# Nudge: a few Downs and PageDowns to reveal usage bars if below the fold
for _ in 1 2 3 4 5 6; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Down; sleep 0.10; done
for _ in 1 2 3; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 PageDown; sleep 0.20; done

# 5) Capture and show anchors + small blocks
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

