#!/usr/bin/env bash
# POC Test: Parse /usage output into JSON
set -euo pipefail

# Sample captured output (from actual run)
read -r -d '' SAMPLE_OUTPUT <<'EOF' || true
 ▐▛███▜▌   Claude Code v2.0.5
▝▜█████▛▘  Sonnet 4.5 · Claude Max
  ▘▘ ▝▝    /Users/alexm/Repository/Codex-History

> /usage
────────────────────────────────────────────────────────────────────────────────
 Settings:  Status   Config   Usage   (tab to cycle)

 Current session
 ▌                                                  1% used
 Resets 1am (America/Los_Angeles)

 Current week (all models)
 ███▌                                               7% used
 Resets Oct 9 at 2pm (America/Los_Angeles)

 Current week (Opus)
 █▌                                                 3% used
 Resets Oct 9 at 2pm (America/Los_Angeles)

 Esc to exit
EOF

echo "=== POC: Parsing /usage output ===" >&2
echo "" >&2

# Parse function
parse_usage() {
    local output="$1"

    # Extract Current session
    session_pct=$(echo "$output" | grep -A2 "Current session" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "0")
    session_resets=$(echo "$output" | grep -A2 "Current session" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")

    # Extract Current week (all models)
    week_all_pct=$(echo "$output" | grep -A2 "Current week (all models)" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "0")
    week_all_resets=$(echo "$output" | grep -A2 "Current week (all models)" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")

    # Extract Current week (Opus) - may not exist
    if echo "$output" | grep -q "Current week (Opus)"; then
        week_opus_pct=$(echo "$output" | grep -A2 "Current week (Opus)" | grep "% used" | sed -E 's/.*[^0-9]([0-9]+)% used.*/\1/' || echo "0")
        week_opus_resets=$(echo "$output" | grep -A2 "Current week (Opus)" | grep "Resets" | sed 's/.*Resets *//' | xargs || echo "")
        week_opus_json="{\"pct_used\": $week_opus_pct, \"resets\": \"$week_opus_resets\"}"
    else
        week_opus_json="null"
    fi

    # Build JSON
    cat <<JSON
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
JSON
}

# Test parsing
echo "Input:" >&2
echo "------" >&2
echo "$SAMPLE_OUTPUT" | head -20 >&2
echo "..." >&2
echo "" >&2

echo "Parsed JSON:" >&2
echo "------------" >&2
result=$(parse_usage "$SAMPLE_OUTPUT")
echo "$result"

# Validate JSON
if echo "$result" | python3 -m json.tool >/dev/null 2>&1; then
    echo "" >&2
    echo "✓ Valid JSON produced" >&2
else
    echo "" >&2
    echo "✗ Invalid JSON!" >&2
    exit 1
fi

# Check fields
if echo "$result" | grep -q '"pct_used": 1'; then
    echo "✓ session_5h.pct_used = 1" >&2
else
    echo "✗ session_5h.pct_used mismatch" >&2
    exit 1
fi

if echo "$result" | grep -q '"pct_used": 7'; then
    echo "✓ week_all_models.pct_used = 7" >&2
else
    echo "✗ week_all_models.pct_used mismatch" >&2
    exit 1
fi

if echo "$result" | grep -q '"pct_used": 3'; then
    echo "✓ week_opus.pct_used = 3" >&2
else
    echo "✗ week_opus.pct_used mismatch" >&2
    exit 1
fi

echo "" >&2
echo "✓ POC successful: Parsing logic works correctly" >&2
