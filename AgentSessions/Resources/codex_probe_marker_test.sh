#!/usr/bin/env bash

set -euo pipefail

# Purpose: Send the first Codex probe message "[AS_CX_PROBE v1]" in tmux
# and verify that Enter is delivered (message is submitted).
# This excludes /status entirely to isolate Enter behavior.
#
# Env overrides:
#   LABEL=cx-probe-keep   (tmux server label; default random)
#   MODEL=gpt-5           (Codex model)
#   KEEP_TMUX=1           (keep tmux session alive for attach)
#   WAIT=0.6              (pause between key sends)
#   LOOK=2.0              (settle before capture)

LABEL="${LABEL:-cx-probe-$$}"
TMUX_CMD="${TMUX_BIN:-tmux}"
CODEX_CMD="${CODEX_BIN:-$(command -v codex || true)}"
MODEL="${MODEL:-gpt-5}"
WAIT="${WAIT:-0.6}"
LOOK="${LOOK:-2.0}"

if [[ -z "${CODEX_CMD}" ]]; then
  echo "codex not found on PATH" >&2
  exit 14
fi

WORKDIR="${WORKDIR:-$HOME/Library/Application Support/AgentSessions/AgentSessions-codex-usage}"
mkdir -p "$WORKDIR"

# 1) Launch Codex in tmux (detached), roomy pane
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

# 3) Type the probe marker and deliver Enter (variants for robustness)
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "[AS_CX_PROBE v1]"
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-j
sleep "$LOOK"

# 4) Show tail so we can see if it submitted
echo "===== LAST 100 LINES ($LABEL) ====="
"$TMUX_CMD" -L "$LABEL" capture-pane -J -p -t s:0.0 -S -100

echo
echo "Attach to inspect:  tmux -L $LABEL attach -t s"
if [[ "${KEEP_TMUX:-0}" != "1" ]]; then
  "$TMUX_CMD" -L "$LABEL" kill-server >/dev/null 2>&1 || true
fi
