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
SLEEP_AFTER_USAGE="${SLEEP_AFTER_USAGE:-2.0}"
WORKDIR="${WORKDIR:-$(pwd)}"
# CLAUDE_TUI_DEBUG - set to 1 to dump raw tmux capture on parsing failure

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
# NOTE: Unlike Codex, Claude Code's /usage command works immediately without
#       requiring session activation. We go directly to /usage without sending
#       any user messages, which preserves the 5h usage limit.

# Send /usage
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "/" 2>/dev/null
sleep 0.2
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "usage" 2>/dev/null
sleep 0.3
"$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null

## Wait for settings dialog to open, then try to land on Usage tab
sleep "$SLEEP_AFTER_USAGE"

# Tab to Usage section (layout varies; send a few Tabs defensively)
for i in 1 2 3 4; do
  "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Tab 2>/dev/null
  sleep 0.25
done

###############################################################################
# Capture and robustly parse the Usage screen
###############################################################################
# Capture the usage screen
capture_usage() {
  "$TMUX_CMD" -L "$LABEL" capture-pane -t "$SESSION:0.0" -p -S -300 2>/dev/null || echo ""
}

usage_output=$(capture_usage)

# If we don't see the anchors, try to re-open /usage a couple of times
ensure_usage_visible() {
  tries=0
  while [ $tries -lt 3 ]; do
    if echo "$usage_output" | grep -q "Current session"; then
      return 0
    fi
    # Re-open /usage to force navigation
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Escape 2>/dev/null || true
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "/" 2>/dev/null
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "usage" 2>/dev/null
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null
    sleep "$SLEEP_AFTER_USAGE"
    usage_output=$(capture_usage)
    tries=$((tries+1))
  done
}

ensure_usage_visible

# ============================================================================
# Parse usage output
# ============================================================================

extract_pct_and_reset() {
  local anchor="$1"; shift
  # Capture the anchor line + next 3 lines into a small block
  local block
  block=$(echo "$usage_output" | awk -v a="$anchor" '
    BEGIN{c=0}
    {
      if (index($0,a)>0) { c=4 }
      if (c>0) { print; c-- }
    }
  ')

  # Extract percentage with unified "remaining" semantics.
  # Claude /usage may show either:
  #   - "83% used"
  #   - "17% left" / "17% remaining"
  # We always normalize to "percent left" so the app can
  # treat Codex and Claude consistently.
  local pct
  pct=$(echo "$block" | awk '
    BEGIN { pct = "" }
    {
      # Skip Resets line
      if (/Resets/) next

      # Pattern 1: Explicit "X% used" → convert to remaining
      if (tolower($0) ~ /% *used/) {
        if (match($0, /[0-9]+/)) {
          pct = 100 - substr($0, RSTART, RLENGTH)
          if (pct < 0) pct = 0
          if (pct > 100) pct = 100
          exit
        }
      }

      # Pattern 2: "% left" or "% remaining" (case-insensitive) - already remaining
      if (tolower($0) ~ /% *(left|remaining)/) {
        if (match($0, /[0-9]+/)) {
          pct = substr($0, RSTART, RLENGTH)
          exit
        }
      }

      # Pattern 3: Fallback - any line with "N%" format.
      # Assume this already represents "percent left".
      if (pct == "" && match($0, /[0-9]+%/)) {
        pct = substr($0, RSTART, RLENGTH-1)
        exit
      }
    }
    END { print pct }
  ')

  # Extract text after "Resets" (more flexible whitespace handling)
  local resets
  resets=$(echo "$block" | awk '
    /Resets/ {
      sub(/^.*Resets[ \t]*/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")  # trim whitespace
      print
      exit
    }
  ')

  echo "$pct" "$resets"
}

read session_pct session_resets < <(extract_pct_and_reset "Current session")

# Allow variations in label casing and punctuation for weekly all models
week_anchor=$(echo "$usage_output" | awk 'BEGIN{IGNORECASE=1} /Current week \(all models\)|Current week \(all-models\)|Current week/ {print; exit}')
if [ -n "$week_anchor" ]; then
  read week_all_pct week_all_resets < <(extract_pct_and_reset "Current week")
else
  week_all_pct=""; week_all_resets=""
fi

# Opus weekly (optional)
if echo "$usage_output" | grep -q "Current week (Opus)"; then
  read week_opus_pct week_opus_resets < <(extract_pct_and_reset "Current week (Opus)")
  week_opus_json="{\"pct_left\": ${week_opus_pct:-0}, \"resets\": \"${week_opus_resets}\"}"
else
  week_opus_json="null"
fi

# Validate we got data
if [ -z "$session_pct" ] || [ -z "$week_all_pct" ]; then
    # One more attempt: re-open /usage and recapture once
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Escape 2>/dev/null || true
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "/" 2>/dev/null
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" "usage" 2>/dev/null
    sleep 0.2
    "$TMUX_CMD" -L "$LABEL" send-keys -t "$SESSION:0.0" Enter 2>/dev/null
    sleep "$SLEEP_AFTER_USAGE"
    usage_output=$(capture_usage)
    read session_pct session_resets < <(extract_pct_and_reset "Current session")
    read week_all_pct week_all_resets < <(extract_pct_and_reset "Current week")
fi

if [ -z "$session_pct" ] || [ -z "$week_all_pct" ]; then
    if [ "${CLAUDE_TUI_DEBUG:-0}" != "0" ]; then
        debug_file="$(mktemp -t claude_usage_pane)"
        echo "$usage_output" > "$debug_file"
        echo "DEBUG: Raw captured output saved to $debug_file" >&2
        echo "DEBUG: session_pct='$session_pct' week_all_pct='$week_all_pct'" >&2
        echo "DEBUG: session_resets='$session_resets' week_all_resets='$week_all_resets'" >&2
    fi
    echo "$(error_json parsing_failed 'Failed to extract usage data from TUI. Set CLAUDE_TUI_DEBUG=1 for details.')"
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
    "pct_left": $session_pct,
    "resets": "$session_resets"
  },
  "week_all_models": {
    "pct_left": $week_all_pct,
    "resets": "$week_all_resets"
  },
  "week_opus": $week_opus_json
}
EOF

exit 0
