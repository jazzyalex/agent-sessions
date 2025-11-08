#!/usr/bin/env bash

set -euo pipefail

# Minimal, model-agnostic Codex /status test in tmux.
# 1) Launches Codex (no -m flag; uses your default)
# 2) Sends:  Protocol test [AS_CX_PROBE v1]. just reply Ok
# 3) Waits 10s, then types /status char-by-char (triggers TUI version)
# 4) Polls for status output (with scrolling if needed)
# 5) Prints anchors (5h/weekly) and first 200 lines for inspection
#
# Usage:
#   ./AgentSessions/Resources/codex_status_min_test.sh
#   LABEL=cx-min KEEP_TMUX=1 ./AgentSessions/Resources/codex_status_min_test.sh
#
# Env overrides:
#   LABEL=...            tmux server label
#   WAIT_AFTER_MSG=10    seconds to wait after the protocol test message
#   THINK_WAIT=0.5       pause between key sends
#   LOOK=5.0             settle before each capture attempt

LABEL="${LABEL:-cx-min-$$}"
TMUX_CMD="${TMUX_BIN:-tmux}"
CODEX_CMD="${CODEX_BIN:-$(command -v codex || true)}"
WAIT_AFTER_MSG="${WAIT_AFTER_MSG:-10}"
THINK_WAIT="${THINK_WAIT:-0.5}"
LOOK="${LOOK:-5.0}"

if [[ -z "${CODEX_CMD}" ]]; then
  echo "codex not found on PATH" >&2
  exit 14
fi

# Use the same dedicated working directory as the app
WORKDIR="${WORKDIR:-$HOME/Library/Application Support/AgentSessions/AgentSessions-codex-usage}"
mkdir -p "$WORKDIR"

# Wait for Codex prompt to appear
wait_for_prompt() {
  local tries=0
  while [ $tries -lt 40 ]; do
    sleep 0.2
    local p=$("$TMUX_CMD" -L "$LABEL" capture-pane -t s:0.0 -p -S -200 2>/dev/null || echo "")
    if echo "$p" | grep -q "^› "; then return 0; fi
    tries=$((tries+1))
  done
  return 1
}

# Start Codex in tmux (no model selection)
"$TMUX_CMD" -L "$LABEL" new -d -s s "cd '$WORKDIR'; env TERM=xterm-256color '$CODEX_CMD'"
"$TMUX_CMD" -L "$LABEL" set-option -t s history-limit 5000 >/dev/null 2>&1 || true
"$TMUX_CMD" -L "$LABEL" resize-pane -t s:0.0 -x 132 -y 48
sleep 1

# Dismiss "Press enter to continue" if shown
for _ in 1 2 3; do
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -p -t s:0.0 -S -200 | tr -d $'\r')"
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter
    sleep "$THINK_WAIT"
  else
    break
  fi
done

# Wait for prompt, then send exact non-reasoning message
wait_for_prompt || echo "WARN: prompt never appeared" >&2
MSG="Protocol test [AS_CX_PROBE v1]. just reply Ok"
"$TMUX_CMD" -L "$LABEL" send-keys -l -t s:0.0 "$MSG"
sleep "$THINK_WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter

# Fixed wait, then ensure command starts at column 1 and send /status
sleep "$WAIT_AFTER_MSG"
wait_for_prompt || echo "WARN: prompt never reappeared after probe" >&2
# Clear any partial input and move cursor to start of line (no Escape to avoid conflicts)
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 C-u Home
sleep "$THINK_WAIT"
# Type /status character by character to trigger TUI autocomplete
for char in / s t a t u s; do
  "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 "$char"
  sleep 0.15
done
sleep "$THINK_WAIT"
"$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Enter

# Wait and poll for status output to appear
found=0
for attempt in 1 2; do
  sleep "$LOOK"
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -J -p -t s:0.0 -S -9999 || echo "")"
  if echo "$pane" | grep -Eqi "5[ -]?h[[:space:]]+limit:|weekly[[:space:]]+limit:"; then
    found=1
    break
  fi
  # Try scrolling down to reveal usage bars
  for scroll in 1 2 3; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t s:0.0 Down 2>/dev/null
    sleep 0.2
    pane="$($TMUX_CMD -L "$LABEL" capture-pane -J -p -t s:0.0 -S -9999 || echo "")"
    if echo "$pane" | grep -Eqi "5[ -]?h[[:space:]]+limit:|weekly[[:space:]]+limit:"; then
      found=1
      break 2
    fi
  done
done

if [[ "$found" -eq 0 ]]; then
  echo "===== WARNING: Status output not found after $attempt attempts ====="
  pane="$($TMUX_CMD -L "$LABEL" capture-pane -J -p -t s:0.0 -S -9999 || echo "")"
fi

echo "===== Anchors ====="
echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:|weekly[[:space:]]+limit:" || echo "(anchors not found)"

echo
echo "===== First 200 lines (context) ====="
echo "$pane" | sed -n '1,200p'

echo
echo "Attach to inspect:  tmux -L $LABEL attach -t s"
if [[ "${KEEP_TMUX:-0}" != "1" ]]; then
  "$TMUX_CMD" -L "$LABEL" kill-server >/dev/null 2>&1 || true
fi
