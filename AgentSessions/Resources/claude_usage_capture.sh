#!/usr/bin/env bash
#
# claude_usage_capture.sh
# Headless collector for Claude CLI "/usage" using detached tmux session
#
# Usage: ./claude_usage_capture.sh
# Output: JSON to stdout
# Exit codes:
#   0  - Success
#   12 - TUI failed to boot
#   13 - Auth required or CLI prompted login
#   14 - Claude CLI not found
#   15 - tmux not found
#   16 - Parsing failed
#

set -euo pipefail

# ============================================================================
# Configuration (override via environment)
# ============================================================================
MODEL="${MODEL:-sonnet}"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"
SLEEP_BOOT="${SLEEP_BOOT:-0.4}"
SLEEP_AFTER_USAGE="${SLEEP_AFTER_USAGE:-1.2}"
WORKDIR="${WORKDIR:-$(pwd)}"

# Unique label to avoid interference
LABEL="as-cc-$$"
SESSION="usage"

# ============================================================================
# Error handling
# ============================================================================
error_json() {
    local code="$1"
    local hint="$2"
    cat <<EOF
{"ok":false,"error":"$code","hint":"$hint"}
EOF
}

# ============================================================================
# Cleanup trap
# ============================================================================
cleanup() {
    "${TMUX_CMD:-tmux}" -L "$LABEL" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Dependency checks
# ============================================================================

# Check tmux
TMUX_CMD="${TMUX_BIN:-tmux}"
if [[ -n "${TMUX_BIN:-}" ]]; then
    # Use explicit binary path if provided
    if [[ ! -x "$TMUX_BIN" ]]; then
        echo "$(error_json tmux_not_found "Binary not executable: $TMUX_BIN")"
        echo "ERROR: TMUX_BIN not executable: $TMUX_BIN" >&2
        exit 15
    fi
else
    # Fall back to PATH lookup
    if ! command -v tmux &>/dev/null; then
        echo "$(error_json tmux_not_found 'Install tmux: brew install tmux')"
        echo "ERROR: tmux not found" >&2
        exit 15
    fi
fi

# Check claude CLI
CLAUDE_CMD="${CLAUDE_BIN:-claude}"
if [[ -n "${CLAUDE_BIN:-}" ]]; then
    # Use explicit binary path if provided
    if [[ ! -x "$CLAUDE_BIN" ]]; then
        echo "$(error_json claude_cli_not_found "Binary not executable: $CLAUDE_BIN")"
        echo "ERROR: CLAUDE_BIN not executable: $CLAUDE_BIN" >&2
        exit 14
    fi
else
    # Fall back to PATH lookup
    if ! command -v claude &>/dev/null; then
        echo "$(error_json claude_cli_not_found 'Install Claude CLI from https://docs.claude.com')"
        echo "ERROR: claude CLI not found on PATH" >&2
        exit 14
    fi
fi

# ============================================================================
# Launch Claude in detached tmux
# ============================================================================

# Launch Claude in temp directory (prevents project scanning)
"$TMUX_CMD" -L "$LABEL" new-session -d -s "$SESSION" \
    "cd '$WORKDIR' && env TERM=xterm-256color '$CLAUDE_CMD' --model $MODEL"

# Resize pane for predictable rendering
"$TMUX_CMD" -L "$LABEL" resize-pane -t "$SESSION:0.0" -x 120 -y 32

# ============================================================================
# Wait for TUI to boot
# ============================================================================

# Give Claude a moment to initialize before starting checks
sleep 1

iterations=0
max_iterations=$((TIMEOUT_SECS * 10 / 4))  # Convert timeout to iterations
booted=false

while [ $iterations -lt $max_iterations ]; do
    sleep "$SLEEP_BOOT"
    ((iterations++))

    output=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p 2>/dev/null || echo "")

    # Check for trust prompt first (handle before boot check)
    if echo "$output" | grep -q "Do you trust the files in this folder?"; then
        "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter
        sleep 1.0
        continue  # Re-check in next iteration
    fi

    # Check for theme selection (first run)
    if echo "$output" | grep -qE '(Choose the text style|Dark mode|Light mode)'; then
        "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter
        sleep 1.0
        continue  # Re-check in next iteration
    fi

    # Check for boot indicators
    if echo "$output" | grep -qE '(Claude Code v|Try "|Thinking on|tab to toggle)'; then
        # Make sure we're not on a prompt
        if ! echo "$output" | grep -qE '(Do you trust|Choose the text style)'; then
            booted=true
            break
        fi
    fi

    # Check for auth/login prompts
    if echo "$output" | grep -qE '(sign in|login|authentication|unauthorized|Please run.*claude login|Select login method)'; then
        echo "$(error_json auth_required_or_cli_prompted_login 'Run: claude login')"
        echo "ERROR: Authentication/login required" >&2
        echo "$output" >&2
        exit 13
    fi
done

if [ "$booted" = false ]; then
    echo "$(error_json tui_failed_to_boot "TUI did not boot within ${TIMEOUT_SECS}s")"
    echo "ERROR: TUI failed to boot within ${TIMEOUT_SECS}s" >&2
    last_output=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p 2>/dev/null || echo "(capture failed)")
    echo "Last output:" >&2
    echo "$last_output" >&2
    exit 12
fi

# ============================================================================
# Send /usage command and navigate to Usage tab
# ============================================================================

# Send /usage
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "/" 2>/dev/null
sleep 0.2
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "usage" 2>/dev/null
sleep 0.3
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null

# Wait for settings dialog to open
sleep "$SLEEP_AFTER_USAGE"

# Tab to Usage section (Status [default] -> Config -> Usage = 2 tabs)
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Tab 2>/dev/null
sleep 0.3
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Tab 2>/dev/null
sleep 0.3
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Tab 2>/dev/null
sleep 0.5

# Capture the usage screen
usage_output=$("$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -300 2>/dev/null || echo "")

# ============================================================================
# Parse usage output
# ============================================================================

# Extract Current session
session_pct=$(echo "$usage_output" | grep -A2 "Current session" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "")
session_resets=$(echo "$usage_output" | grep -A2 "Current session" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")

# Extract Current week (all models)
week_all_pct=$(echo "$usage_output" | grep -A2 "Current week (all models)" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "")
week_all_resets=$(echo "$usage_output" | grep -A2 "Current week (all models)" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")

# Extract Current week (Opus) - may not exist
if echo "$usage_output" | grep -q "Current week (Opus)"; then
    week_opus_pct=$(echo "$usage_output" | grep -A2 "Current week (Opus)" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "")
    week_opus_resets=$(echo "$usage_output" | grep -A2 "Current week (Opus)" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")
    week_opus_json="{\"pct_used\": $week_opus_pct, \"resets\": \"$week_opus_resets\"}"
else
    week_opus_json="null"
fi

# Validate we got data
if [ -z "$session_pct" ] || [ -z "$week_all_pct" ]; then
    echo "$(error_json parsing_failed 'Failed to extract usage data from TUI')"
    echo "ERROR: Failed to parse usage data" >&2
    echo "Captured output:" >&2
    echo "$usage_output" >&2
    exit 16
fi

# ============================================================================
# Output JSON
# ============================================================================

cat <<EOF
{
  "ok": true,
  "source": "tmux-capture",
  "session_5h": {
    "pct_used": $session_pct,
    "resets": "$session_resets"
  },
  "week_all_models": {
    "pct_used": $week_all_pct,
    "resets": "$week_all_resets"
  },
  "week_opus": $week_opus_json
}
EOF

exit 0
