#!/usr/bin/env bash
#
# codex_status_capture.sh
# Headless collector for Codex CLI "/status" using detached tmux session
#
# Output: JSON to stdout
# Exit codes:
#   0  - Success
#   14 - Codex CLI not found
#   15 - tmux not found
#   16 - Parsing failed
#
set -euo pipefail

# Note: Do not force a model by default; Codex may reject some flags
# under certain account types. If you really need to pin a model,
# export MODEL=... before invoking this script.
MODEL="${MODEL:-}"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"
SLEEP_AFTER_STATUS="${SLEEP_AFTER_STATUS:-3.0}"
WORKDIR="${WORKDIR:-$(pwd)}"
# Extra timings tuned from interactive experiments
WAIT_AFTER_MSG="${WAIT_AFTER_MSG:-10}"
THINK_WAIT="${THINK_WAIT:-0.5}"

LABEL="${TMUX_LABEL:-}"
if [[ -z "$LABEL" ]]; then
  uuid=$(uuidgen 2>/dev/null || true)
  uuid=${uuid//-/}
  if [[ -n "$uuid" ]]; then
    LABEL="as-cx-${uuid:0:12}"
  else
    LABEL="as-cx-${RANDOM}${RANDOM}$(date +%s)"
  fi
fi
SESSION="status"
PANE_PID=""

error_json() { local code="$1"; local hint="$2"; echo "{\"ok\":false,\"error\":\"$code\",\"hint\":\"$hint\"}"; }

cleanup() {
  set +e
  set +o pipefail
  local tmux_cmd="${TMUX_BIN:-tmux}"
  local pane_pid="$PANE_PID"
  if command -v "$tmux_cmd" >/dev/null 2>&1; then
    if [[ -z "$pane_pid" ]]; then
      pane_pid=$("$tmux_cmd" -L "$LABEL" display-message -p -t "$SESSION:0.0" "#{pane_pid}" 2>/dev/null || true)
    fi
    if [[ -n "$pane_pid" ]]; then
      local pgid=""
      pgid=$(ps -o pgid= -p "$pane_pid" 2>/dev/null | tr -d ' ')
      if [[ -n "$pgid" ]]; then
        kill -TERM -"$pgid" 2>/dev/null || true
        sleep 0.4
        kill -KILL -"$pgid" 2>/dev/null || true
      else
        kill -TERM "$pane_pid" 2>/dev/null || true
        sleep 0.4
        kill -KILL "$pane_pid" 2>/dev/null || true
      fi
    fi
    "$tmux_cmd" -L "$LABEL" kill-session -t "$SESSION" 2>/dev/null || true
    "$tmux_cmd" -L "$LABEL" kill-server 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

# tmux check
if [[ -n "${TMUX_BIN:-}" ]]; then
  if [[ ! -x "$TMUX_BIN" ]]; then echo "$(error_json tmux_not_found "Binary not executable: $TMUX_BIN")"; exit 15; fi
else
  if ! command -v tmux >/dev/null 2>&1; then echo "$(error_json tmux_not_found 'Install tmux: brew install tmux')"; exit 15; fi
fi
TMUX_CMD="${TMUX_BIN:-tmux}"

# Ensure tmux socket lives in a writable, isolated directory to avoid permission issues
# Use a short, globally-writable socket base to avoid UNIX socket path limits
if [[ -z "${TMUX_TMPDIR:-}" ]]; then export TMUX_TMPDIR="/tmp"; fi

# codex CLI check
CODEX_CMD="${CODEX_BIN:-codex}"
if [[ -n "${CODEX_BIN:-}" ]]; then
  [[ -x "$CODEX_BIN" ]] || { echo "$(error_json codex_cli_not_found "Binary not executable: $CODEX_BIN")"; exit 14; }
else
  command -v codex >/dev/null 2>&1 || { echo "$(error_json codex_cli_not_found 'Install codex CLI')"; exit 14; }
fi

# Launch codex in detached tmux
if [[ -n "$MODEL" ]]; then
  CMD="cd '$WORKDIR' && env TERM=xterm-256color '$CODEX_CMD' -m $MODEL"
else
  CMD="cd '$WORKDIR' && env TERM=xterm-256color '$CODEX_CMD'"
fi
set +e
"$TMUX_CMD" -L "$LABEL" new-session -d -s "$SESSION" "$CMD"
rc=$?
if [[ $rc -ne 0 ]]; then
  # Retry once after a short delay in case tmux server was still initializing
  sleep 0.3
  "$TMUX_CMD" -L "$LABEL" new-session -d -s "$SESSION" "$CMD"
  rc=$?
fi
set -e
if [[ $rc -ne 0 ]]; then
  echo "$(error_json tmux_start_failed "Failed to start tmux session (rc=$rc). TMUX_TMPDIR=$TMUX_TMPDIR")"; exit 1
fi
# Mark this tmux server as an Agent Sessions probe.
"$TMUX_CMD" -L "$LABEL" set-environment -g AS_PROBE "1" 2>/dev/null || true
"$TMUX_CMD" -L "$LABEL" set-environment -g AS_PROBE_KIND "codex" 2>/dev/null || true
"$TMUX_CMD" -L "$LABEL" set-environment -g AS_PROBE_APP "com.triada.AgentSessions" 2>/dev/null || true
"$TMUX_CMD" -L "$LABEL" set-option -t "$SESSION" history-limit 5000 2>/dev/null || true

"$TMUX_CMD" -L "$LABEL" resize-pane -t "$SESSION:0.0" -x 132 -y 48 2>/dev/null || true
PANE_PID=$("$TMUX_CMD" -L "$LABEL" display-message -p -t "$SESSION:0.0" "#{pane_pid}" 2>/dev/null || true)

sleep 0.8

wait_for_prompt() {
  local tries=0
  while [ $tries -lt 40 ]; do
    sleep 0.2
    local p=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -200 2>/dev/null || echo "")
    if echo "$p" | grep -q "^› "; then return 0; fi
    tries=$((tries+1))
  done
  return 1
}

# Handle initial one-time prompts (approval screen etc.)
iterations=0
max_iterations=$((TIMEOUT_SECS * 10 / 4))
while [ $iterations -lt $max_iterations ]; do
  sleep 0.25
  iterations=$((iterations+1))
  pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p 2>/dev/null || echo "")
  if echo "$pane" | grep -qi "Press enter to continue"; then
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null
    sleep 0.6
    continue
  fi
  # Once header is visible, proceed
  if echo "$pane" | grep -qi "OpenAI Codex (v"; then
    break
  fi
done

# Ensure prompt is ready and the cursor is at column 1 before typing /status
wait_for_prompt || true
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" C-u Home 2>/dev/null || true
sleep "$THINK_WAIT"

ensure_status() {
  # Single /status attempt typed char-by-char to guarantee column-1 command
  for c in / s t a t u s; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "$c" 2>/dev/null || true
    sleep 0.15
  done
  sleep "$THINK_WAIT"
  "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null || true

  # Wait for the page to fully render; check multiple times
  for __ in 1 2 3 4 5 6 7 8 9 10; do
    sleep "$SLEEP_AFTER_STATUS"
    pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -J -t "$SESSION:0.0" -p -S -4000 2>/dev/null || echo "")
    # Succeed if we see at least the 5h limit; weekly may or may not be present in some views
    if echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:" >/dev/null; then return 0; fi
    if echo "$pane" | grep -Ei "weekly[[:space:]]+limit:"   >/dev/null; then return 0; fi
  done
  # Try to scroll down to reveal the usage bars
  for __ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Down 2>/dev/null
    sleep 0.15
    pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -J -t "$SESSION:0.0" -p -S -4000 2>/dev/null || echo "")
    if echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:" >/dev/null; then return 0; fi
  done
  # Page down a few times, then check again
  for __ in 1 2 3 4; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" PageDown 2>/dev/null || true
    sleep 0.25
    pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -J -t "$SESSION:0.0" -p -S -4000 2>/dev/null || echo "")
    if echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:" >/dev/null; then return 0; fi
  done
  # Space (common pager-like scroll)
  for __ in 1 2 3; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Space 2>/dev/null || true
    sleep 0.3
    pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -J -t "$SESSION:0.0" -p -S -4000 2>/dev/null || echo "")
    if echo "$pane" | grep -Ei "5[ -]?h[[:space:]]+limit:" >/dev/null; then return 0; fi
  done
  return 1
}

if ! ensure_status; then
  pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -500 2>/dev/null || echo "")
fi

# Extract helper: returns "<pct_remaining> <resets>"
# Post Nov 24, 2025: Codex /status shows "X% left" instead of "X% used"
extract() {
  local anchor="$1"
  local block=$(echo "$pane" | awk -v a="$anchor" 'BEGIN{c=0} { if (index(tolower($0),tolower(a))>0) {c=4} if (c>0){print; c--} }')
  # Look for "X% left" or "X% remaining" patterns - extract number immediately before %
  local pct=$(echo "$block" | awk '{
    if (match($0, /[0-9]+% *(left|remaining)/)) {
      # Extract the matched substring, then get just the number part
      matched = substr($0, RSTART, RLENGTH)
      if (match(matched, /[0-9]+/)) {
        print substr(matched, RSTART, RLENGTH)
        exit
      }
    }
  }')
  local resets=$(echo "$block" | awk '/[Rr]esets/{ sub(/^.*[Rr]esets[[:space:]]*/, ""); sub(/[[:space:]]*│.*/, ""); sub(/[[:space:]]*\)$/, ""); sub(/[[:space:]]*$/, ""); print; exit }')
  echo "$pct" "$resets"
}

read p5 r5 < <(extract "5h limit:")
if [[ -z "$p5" ]]; then read p5 r5 < <(extract "5 h limit:"); fi
if [[ -z "$p5" ]]; then read p5 r5 < <(extract "5-hour limit:"); fi
read pw rw < <(extract "weekly limit:")

if [[ -z "$p5" && -z "$pw" ]]; then
  if [[ "${CODEX_TUI_DEBUG:-0}" != "0" ]]; then f=$(mktemp -t codex_status_pane); echo "$pane" > "$f"; echo "DEBUG pane saved to $f" >&2; fi
  echo "$(error_json parsing_failed 'Failed to extract /status')"; exit 16
fi

cat <<EOF
{
  "ok": true,
  "five_hour": { "pct_left": ${p5:-0}, "resets": "${r5}" },
  "weekly": { "pct_left": ${pw:-0}, "resets": "${rw}" }
}
EOF

exit 0
