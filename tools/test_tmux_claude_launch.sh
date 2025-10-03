#!/usr/bin/env bash
# POC Test: Launch Claude CLI in detached tmux and capture output
set -euo pipefail

# Config
LABEL="as-cc-test-$$"
SESSION="usage-test"
MODEL="${MODEL:-sonnet}"
WORKDIR="${WORKDIR:-$(pwd)}"  # Use current directory to avoid trust prompts
TIMEOUT_SECS=10
SLEEP_BOOT=0.4

echo "=== POC: Launching Claude in detached tmux ===" >&2

# Cleanup trap
cleanup() {
    echo "Cleaning up tmux session..." >&2
    tmux -L "$LABEL" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# Check tmux
if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux not found" >&2
    exit 15
fi

# Check claude
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude not found" >&2
    exit 14
fi

# Launch Claude in detached tmux
echo "Starting tmux session with Claude CLI..." >&2
tmux -L "$LABEL" new-session -d -s "$SESSION" \
    "cd '$WORKDIR' && env TERM=xterm-256color claude --model $MODEL"

# Resize for predictable rendering
tmux -L "$LABEL" resize-pane -t "$SESSION:0.0" -x 120 -y 32

# Wait for TUI to boot
echo "Waiting for TUI to boot..." >&2
iterations=0
max_iterations=$((TIMEOUT_SECS * 10 / 4))  # TIMEOUT / SLEEP_BOOT in tenths
booted=false
while [ $iterations -lt $max_iterations ]; do
    sleep "$SLEEP_BOOT"
    ((iterations++))

    output=$(tmux -L "$LABEL" capture-pane -t "$SESSION:0.0" -p 2>/dev/null || echo "")

    # Check for trust prompt first (handle before boot check)
    if echo "$output" | grep -q "Do you trust the files in this folder?"; then
        echo "Detected trust prompt, sending '1'..." >&2
        tmux -L "$LABEL" send-keys -t "$SESSION:0.0" "1" Enter
        sleep 1.0
        continue  # Re-check in next iteration
    fi

    # Check for boot indicators (but not if we're on trust prompt)
    if echo "$output" | grep -qE '(Claude Code v|Try "|Thinking on|tab to toggle)'; then
        # Make sure we're not on the trust prompt
        if ! echo "$output" | grep -q "Do you trust the files in this folder?"; then
            booted=true
            elapsed=$(echo "$iterations * $SLEEP_BOOT" | bc)
            echo "✓ TUI booted after ${elapsed}s" >&2
            break
        fi
    fi

    # Check for auth errors
    if echo "$output" | grep -qE '(sign in|login|authentication|unauthorized)'; then
        echo "ERROR: Auth required or login prompt detected" >&2
        echo "Current output:" >&2
        echo "$output" >&2
        exit 13
    fi
done

if [ "$booted" = false ]; then
    echo "ERROR: TUI failed to boot within ${TIMEOUT_SECS}s" >&2
    echo "Last captured output:" >&2
    tmux -L "$LABEL" capture-pane -t "$SESSION:0.0" -p 2>/dev/null || echo "(capture failed)"
    exit 12
fi

# Send /usage command
echo "" >&2
echo "Sending /usage command..." >&2
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" "/"
sleep 0.2
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" "usage"
sleep 0.3
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" Enter

# Wait longer for the settings dialog to fully load
sleep 1.5

# Tab to Usage section (3 tabs: Status [initial] -> Config -> Usage)
echo "Tabbing to Usage section (3 tabs)..." >&2
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" Tab
sleep 0.3
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" Tab
sleep 0.3
tmux -L "$LABEL" send-keys -t "$SESSION:0.0" Tab
sleep 0.5

# Capture the output
echo "" >&2
echo "=== Captured Usage Screen ===" >&2
output=$(tmux -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -300)
echo "$output"

echo "" >&2
echo "✓ POC successful: Claude CLI launched, /usage sent and captured" >&2
