#!/usr/bin/env bash

set -euo pipefail

# Minimal tmux + Codex ping test to verify Enter delivery.
# - Starts Codex in a tmux server (label defaults to cx-ping-$$)
# - Dismisses the initial "Press enter to continue" screen
# - Types "ping" and sends Enter variants (Enter, C-m, C-j)
# - Prints the last lines so you can see whether ping executed
#
# Env overrides:
#   LABEL=custom-label      (tmux server label)
#   MODEL=gpt-5             (Codex model)
#   KEEP_TMUX=1             (keep tmux session for manual attach)
#   WAIT=0.6                (pause between key sends)
#   LOOK=2.0                (settle before capture)

LABEL="${LABEL:-cx-ping-$$}"
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

# Start Codex in tmux (detached), make the pane roomy
"$TMUX_CMD" -L "$LABEL" new -d -s s "cd '$WORKDIR'; env TERM=xterm-256color '$CODEX_CMD' -m '$MODEL'"
"$TMUX_CMD" -L "$LABEL" set-option -t s history-limit 5000 >/dev/null 2>&1 || true
"$TMUX_CMD" -L "$LABEL" resize-pane -t s:0.0 -x 132 -y 48
sleep 0.8

# Dismiss the initial prompt if shown
for _ in 1 2 3; do
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -p -t s:0.0 -S -200 | tr -d $'\r')"
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
    sleep "$WAIT"
  else
    break
  fi
done

# Type ping and try Enter variants
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "ping"
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep "$WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-j
sleep "$LOOK"

echo "===== LAST 80 LINES (\$LABEL) ====="
"$TMUX_CMD" -L "$LABEL" capture-pane -J -p -t s:0.0 -S -80

echo
echo "Attach to inspect:  tmux -L $LABEL attach -t s"
if [[ "${KEEP_TMUX:-0}" != "1" ]]; then
  "$TMUX_CMD" -L "$LABEL" kill-server >/dev/null 2>&1 || true
fi

