#!/usr/bin/env bash
#
# Demo: How to use claude_usage_capture.sh
#

echo "=========================================="
echo "Claude Usage Capture - Demo"
echo "=========================================="
echo ""

SCRIPT="$(dirname "$0")/claude_usage_capture.sh"

# Demo 1: Basic usage
echo "[Demo 1] Basic usage"
echo "$ ./claude_usage_capture.sh"
echo ""
"$SCRIPT" 2>/dev/null | python3 -m json.tool
echo ""
echo ""

# Demo 2: Check exit code
echo "[Demo 2] Check exit code"
echo "$ ./claude_usage_capture.sh && echo \"Exit code: \$?\""
echo ""
"$SCRIPT" >/dev/null 2>&1
echo "Exit code: $?"
echo ""
echo ""

# Demo 3: Extract specific field with jq (if available)
echo "[Demo 3] Extract specific field (session percentage)"
if command -v jq &>/dev/null; then
    echo "$ ./claude_usage_capture.sh | jq -r '.session_5h.pct_used'"
    echo ""
    "$SCRIPT" 2>/dev/null | jq -r '.session_5h.pct_used'
    echo ""
else
    echo "(jq not installed - skipping)"
    echo ""
fi

echo ""
echo "=========================================="
echo "Demo complete!"
echo "=========================================="
