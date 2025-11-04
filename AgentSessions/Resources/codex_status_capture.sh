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

MODEL="${MODEL:-gpt-5}"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"
SLEEP_AFTER_STATUS="${SLEEP_AFTER_STATUS:-2.0}"
WORKDIR="${WORKDIR:-$(pwd)}"

LABEL="as-cx-$$"
SESSION="status"

error_json() { local code="$1"; local hint="$2"; echo "{\"ok\":false,\"error\":\"$code\",\"hint\":\"$hint\"}"; }

cleanup() { "${TMUX_BIN:-tmux}" -L "$LABEL" kill-server 2>/dev/null || true; }
trap cleanup EXIT

# tmux check
if [[ -n "${TMUX_BIN:-}" ]]; then
  if [[ ! -x "$TMUX_BIN" ]]; then echo "$(error_json tmux_not_found "Binary not executable: $TMUX_BIN")"; exit 15; fi
else
  if ! command -v tmux >/dev/null 2>&1; then echo "$(error_json tmux_not_found 'Install tmux: brew install tmux')"; exit 15; fi
fi
TMUX_CMD="${TMUX_BIN:-tmux}"

# codex CLI check
CODEX_CMD="${CODEX_BIN:-codex}"
if [[ -n "${CODEX_BIN:-}" ]]; then
  [[ -x "$CODEX_BIN" ]] || { echo "$(error_json codex_cli_not_found "Binary not executable: $CODEX_BIN")"; exit 14; }
else
  command -v codex >/dev/null 2>&1 || { echo "$(error_json codex_cli_not_found 'Install codex CLI')"; exit 14; }
fi

# Launch codex in detached tmux
"$TMUX_CMD" -L "$LABEL" new-session -d -s "$SESSION" \
  "cd '$WORKDIR' && env TERM=xterm-256color '$CODEX_CMD' -m $MODEL"

"$TMUX_CMD" -L "$LABEL" resize-pane -t "$SESSION:0.0" -x 120 -y 32

sleep 0.8

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

# Send marker then /status
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "[AS_CX_PROBE v1] usage probe" Enter 2>/dev/null
sleep 0.6

ensure_status() {
  # Try up to 8 times to render /status fully
  for _ in 1 2 3 4 5 6 7 8; do
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "/status" Enter 2>/dev/null
    # Wait for the page to fully render; check multiple times
    for __ in 1 2 3 4 5 6 7 8 9 10; do
      sleep "$SLEEP_AFTER_STATUS"
      pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -2000 2>/dev/null || echo "")
      # Succeed if we see at least the 5h limit; weekly may or may not be present in some views
      if echo "$pane" | grep -qi "5h limit:"; then return 0; fi
    done
  done
  return 1
}

if ! ensure_status; then
  pane=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -500 2>/dev/null || echo "")
fi

# Extract helper: returns "<pct> <resets>"
extract() {
  local anchor="$1"
  local block=$(echo "$pane" | awk -v a="$anchor" 'BEGIN{c=0} { if (index(tolower($0),tolower(a))>0) {c=4} if (c>0){print; c--} }')
  local pct=$(echo "$block" | awk '/% used/{ if (match($0, /[0-9]+/)) { print substr($0,RSTART,RLENGTH); exit }}')
  local resets=$(echo "$block" | awk '/[Rr]esets/{ sub(/^.*[Rr]esets[ ]*/, ""); print; exit }')
  echo "$pct" "$resets"
}

read p5 r5 < <(extract "5h limit:")
read pw rw < <(extract "weekly limit:")

if [[ -z "$p5" && -z "$pw" ]]; then
  if [[ "${CODEX_TUI_DEBUG:-0}" != "0" ]]; then f=$(mktemp -t codex_status_pane); echo "$pane" > "$f"; echo "DEBUG pane saved to $f" >&2; fi
  echo "$(error_json parsing_failed 'Failed to extract /status')"; exit 16
fi

cat <<EOF
{
  "ok": true,
  "five_hour": { "pct_used": ${p5:-0}, "resets": "${r5}" },
  "weekly": { "pct_used": ${pw:-0}, "resets": "${rw}" }
}
EOF

exit 0
