#!/usr/bin/env bash

set -euo pipefail

# Minimal tmux test to render Codex /status and print the usage anchors.
# - Launches Codex in a detached tmux session
# - Dismisses the initial approval prompt if present
# - Sends /status, nudges the page, and captures the pane
# - Prints lines containing "5h limit:" and "Weekly limit:" (case-insensitive)
# - By default, kills the tmux server at the end
#
# Env overrides:
#   TMUX_BIN=/path/to/tmux
#   CODEX_BIN=/path/to/codex
#   MODEL=gpt-5 (default)
#   SLEEP_AFTER_STATUS=2.0 (seconds)
#   KEEP_TMUX=1 (do not kill server at end)

LABEL="${LABEL:-cx-test-$$}"
TMUX_CMD="${TMUX_BIN:-tmux}"
CODEX_CMD="${CODEX_BIN:-$(command -v codex || true)}"
MODEL="${MODEL:-gpt-5}"
SLEEP_AFTER_STATUS="${SLEEP_AFTER_STATUS:-2.0}"

if [[ -z "${CODEX_CMD}" ]]; then
  echo "codex not found on PATH" >&2
  exit 14
fi

# Use a temp working directory to avoid approval prompts from repo settings
WORKDIR="$(mktemp -d)"

# Start Codex in a detached tmux session
"$TMUX_CMD" -L "$LABEL" new-session -d -s s "cd '$WORKDIR'; env TERM=xterm-256color '$CODEX_CMD' -m $MODEL"
"$TMUX_CMD" -L "$LABEL" set-option -t s history-limit 5000 >/dev/null 2>&1 || true
"$TMUX_CMD" -L "$LABEL" resize-pane -t s:0.0 -x 132 -y 48
sleep 0.8

# Dismiss "Press enter to continue" if present
for _ in 1 2 3 4 5; do
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -p -t s:0.0 -S -200 | tr -d $'\r')"
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
    sleep 0.6
  else
    break
  fi
done

# Marker + /status (use explicit C-m to ensure Enter is delivered)
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 "[AS_CX_PROBE v1] manual"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep 0.6
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 "/status"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-m
sleep "$SLEEP_AFTER_STATUS"

# Nudge the page to reveal the usage bars if needed
for _ in 1 2 3 4 5 6; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Down; sleep 0.10; done
for _ in 1 2 3; do "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 PageDown; sleep 0.20; done

# Capture joined lines
pane="$($TMUX_CMD -L "$LABEL" capture-pane -J -p -t s:0.0 -S -9999 || echo "")"

echo "===== Anchors ====="
echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:|weekly[[:space:]]+limit:" || echo "(anchors not found)"

echo
echo "===== Blocks (anchor + 3 lines) ====="
echo "$pane" | awk '/5[hH]([ -])?[lL]imit:|[Ww]eekly[[:space:]]+[lL]imit:/ {print; for(i=1;i<=3;i++){getline; print}}'

echo
echo "===== First 150 lines (context) ====="
echo "$pane" | sed -n '1,150p'

if [[ "${KEEP_TMUX:-0}" != "1" ]]; then
  "$TMUX_CMD" -L "$LABEL" kill-server >/dev/null 2>&1 || true
fi

echo
echo "Done. To inspect interactively, re-run:"
echo "  $TMUX_CMD -L $LABEL attach -t s   (if KEEP_TMUX=1)"
echo "LABEL=$LABEL"
