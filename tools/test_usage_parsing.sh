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

# ============================================================================
# Test with NEW format ("% left" instead of "% used")
# ============================================================================

read -r -d '' SAMPLE_OUTPUT_NEW <<'EOF' || true
 ▐▛███▜▌   Claude Code v2.0.5
▝▜█████▛▘  Sonnet 4.5 · Claude Max
  ▘▘ ▝▝    /Users/alexm/Repository/Codex-History

> /usage
────────────────────────────────────────────────────────────────────────────────
 Settings:  Status   Config   Usage   (tab to cycle)

 Current session
 ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌                80% left
 Resets 10pm (America/Los_Angeles)

 Current week (all models)
 ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌                               53% left
 Resets 8pm (America/Los_Angeles)

 Current week (Opus)
 ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌                                       35% left
 Resets Nov 24 at 10pm (America/Los_Angeles)

 Esc to exit
EOF

echo "" >&2
echo "=== Testing NEW format (% left) ===" >&2
echo "" >&2

# Source the actual script's extract function
# We'll use a simplified inline version that mimics the updated logic
parse_usage_new() {
    local usage_output="$1"

    extract_pct_and_reset() {
      local anchor="$1"
      local block
      block=$(echo "$usage_output" | awk -v a="$anchor" '
        BEGIN{c=0}
        {
          if (index($0,a)>0) { c=4 }
          if (c>0) { print; c-- }
        }
      ')

      # Extract percentage with multiple fallback patterns
      local pct
      pct=$(echo "$block" | awk '
        BEGIN { pct = "" }
        {
          # Skip Resets line
          if (/Resets/) next

          # Pattern 1: "% left" or "%left" (case-insensitive) - invert percentage
          if (tolower($0) ~ /% *left/) {
            if (match($0, /[0-9]+/)) {
              raw = substr($0, RSTART, RLENGTH)
              pct = 100 - raw
              exit
            }
          }

          # Pattern 2: "% used" or "%used" (case-insensitive) - use as-is
          if (tolower($0) ~ /% *used/) {
            if (match($0, /[0-9]+/)) {
              pct = substr($0, RSTART, RLENGTH)
              exit
            }
          }

          # Pattern 3: Fallback - any line with "N%" format (use as-is)
          if (pct == "" && match($0, /[0-9]+%/)) {
            pct = substr($0, RSTART, RLENGTH-1)
            # If line contains "left", invert it
            if (tolower($0) ~ /left/) {
              pct = 100 - pct
            }
          }
        }
        END { print pct }
      ')

      # Extract text after "Resets"
      local resets
      resets=$(echo "$block" | awk '
        /Resets/ {
          sub(/^.*Resets[ \t]*/, "")
          gsub(/^[ \t]+|[ \t]+$/, "")
          print
          exit
        }
      ')

      echo "$pct" "$resets"
    }

    local session_pct session_resets week_all_pct week_all_resets week_opus_pct week_opus_resets
    read session_pct session_resets < <(extract_pct_and_reset "Current session")
    read week_all_pct week_all_resets < <(extract_pct_and_reset "Current week")

    if echo "$usage_output" | grep -q "Current week (Opus)"; then
        read week_opus_pct week_opus_resets < <(extract_pct_and_reset "Current week (Opus)")
        week_opus_json="{\"pct_used\": ${week_opus_pct:-0}, \"resets\": \"${week_opus_resets}\"}"
    else
        week_opus_json="null"
    fi

    # Build JSON
    cat <<JSON
{
  "ok": true,
  "source": "test",
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

result_new=$(parse_usage_new "$SAMPLE_OUTPUT_NEW")
echo "Parsed JSON (new format):" >&2
echo "-------------------------" >&2
echo "$result_new"

# Validate JSON
if echo "$result_new" | python3 -m json.tool >/dev/null 2>&1; then
    echo "" >&2
    echo "✓ Valid JSON produced (new format)" >&2
else
    echo "" >&2
    echo "✗ Invalid JSON (new format)!" >&2
    exit 1
fi

# Check fields (80% left = 20% used)
if echo "$result_new" | grep -q '"pct_used": 20'; then
    echo "✓ session_5h.pct_used = 20 (80% left → 20% used)" >&2
else
    echo "✗ session_5h.pct_used mismatch (expected 20)" >&2
    echo "$result_new" >&2
    exit 1
fi

# 53% left = 47% used
if echo "$result_new" | grep -q '"pct_used": 47'; then
    echo "✓ week_all_models.pct_used = 47 (53% left → 47% used)" >&2
else
    echo "✗ week_all_models.pct_used mismatch (expected 47)" >&2
    echo "$result_new" >&2
    exit 1
fi

# 35% left = 65% used
if echo "$result_new" | grep -q '"pct_used": 65'; then
    echo "✓ week_opus.pct_used = 65 (35% left → 65% used)" >&2
else
    echo "✗ week_opus.pct_used mismatch (expected 65)" >&2
    echo "$result_new" >&2
    exit 1
fi

echo "" >&2
echo "✓ All tests passed: Both old and new formats work correctly" >&2
