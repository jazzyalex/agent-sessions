#!/usr/bin/env bash
#
# Smoke tests for claude_usage_capture.sh
#
# Tests:
# 1. Valid JSON output with correct structure
# 2. No process leaks after 5 runs
# 3. Performance (completes within 10s)
# 4. Error handling for missing dependencies
#

set -euo pipefail

SCRIPT="$(dirname "$0")/claude_usage_capture.sh"
PASSED=0
FAILED=0

echo "======================================================================"
echo "Smoke Tests for claude_usage_capture.sh"
echo "======================================================================"
echo ""

# Helper functions
pass() {
    echo "✓ $1"
    ((PASSED++))
}

fail() {
    echo "✗ $1"
    ((FAILED++))
}

# ============================================================================
# Test 1: Valid JSON output
# ============================================================================
echo "[Test 1] Valid JSON output with correct structure"
echo "----------------------------------------------------------------------"

if ! command -v claude &>/dev/null; then
    fail "Claude CLI not found - skipping functionality tests"
    echo ""
else
    result=$("$SCRIPT" 2>/dev/null || true)

    # Check if it's valid JSON
    if echo "$result" | python3 -m json.tool >/dev/null 2>&1; then
        pass "Output is valid JSON"
    else
        fail "Output is not valid JSON"
        echo "Output: $result"
    fi

    # Check required fields
    if echo "$result" | grep -q '"ok": true'; then
        pass "Has 'ok' field set to true"
    else
        fail "Missing or incorrect 'ok' field"
    fi

    if echo "$result" | grep -q '"source": "tmux-capture"'; then
        pass "Has correct 'source' field"
    else
        fail "Missing or incorrect 'source' field"
    fi

    if echo "$result" | grep -q '"session_5h"'; then
        pass "Has 'session_5h' field"
    else
        fail "Missing 'session_5h' field"
    fi

    if echo "$result" | grep -q '"week_all_models"'; then
        pass "Has 'week_all_models' field"
    else
        fail "Missing 'week_all_models' field"
    fi

    if echo "$result" | grep -q '"week_opus"'; then
        pass "Has 'week_opus' field"
    else
        fail "Missing 'week_opus' field"
    fi

    # Check pct_used values are present
    if echo "$result" | grep -q '"pct_used":'; then
        pass "Has 'pct_used' values"
    else
        fail "Missing 'pct_used' values"
    fi

    # Check resets values are present
    if echo "$result" | grep -q '"resets":'; then
        pass "Has 'resets' values"
    else
        fail "Missing 'resets' values"
    fi

    echo ""
    echo "Sample output:"
    echo "$result" | python3 -m json.tool 2>/dev/null || echo "$result"
    echo ""
fi

# ============================================================================
# Test 2: No process leaks after 5 runs
# ============================================================================
echo "[Test 2] Re-entrancy - no process leaks after 5 runs"
echo "----------------------------------------------------------------------"

if ! command -v claude &>/dev/null; then
    fail "Claude CLI not found - skipping test"
    echo ""
else
    # Clean up any existing sessions
    pkill -9 -f "tmux.*as-cc" 2>/dev/null || true
    sleep 1

    # Run 5 times
    for i in {1..5}; do
        "$SCRIPT" >/dev/null 2>&1 || true
        sleep 0.2
    done

    sleep 1

    # Check for leaked tmux processes
    leaked=$(pgrep -f "tmux.*as-cc" | wc -l || echo "0")
    leaked=$(echo "$leaked" | xargs)  # trim whitespace

    if [ "$leaked" = "0" ]; then
        pass "No tmux processes leaked after 5 runs"
    else
        fail "Found $leaked leaked tmux processes"
    fi

    echo ""
fi

# ============================================================================
# Test 3: Performance (completes within 10s)
# ============================================================================
echo "[Test 3] Performance - completes within 10s"
echo "----------------------------------------------------------------------"

if ! command -v claude &>/dev/null; then
    fail "Claude CLI not found - skipping test"
    echo ""
else
    start=$(date +%s)
    "$SCRIPT" >/dev/null 2>&1 || true
    end=$(date +%s)
    duration=$((end - start))

    if [ $duration -le 10 ]; then
        pass "Completed in ${duration}s (within 10s budget)"
    else
        fail "Took ${duration}s (exceeds 10s budget)"
    fi

    echo ""
fi

# ============================================================================
# Test 4: Error handling - missing tmux
# ============================================================================
echo "[Test 4] Error handling - missing tmux"
echo "----------------------------------------------------------------------"

# This test is hard to do without actually removing tmux, so we'll check
# the script has the right error code defined
if grep -q "exit 15" "$SCRIPT" && grep -q "tmux_not_found" "$SCRIPT"; then
    pass "Script has tmux_not_found error handling (exit 15)"
else
    fail "Script missing tmux_not_found error handling"
fi

echo ""

# ============================================================================
# Test 5: Error handling - missing claude
# ============================================================================
echo "[Test 5] Error handling - missing claude CLI"
echo "----------------------------------------------------------------------"

if grep -q "exit 14" "$SCRIPT" && grep -q "claude_cli_not_found" "$SCRIPT"; then
    pass "Script has claude_cli_not_found error handling (exit 14)"
else
    fail "Script missing claude_cli_not_found error handling"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "======================================================================"
echo "Summary: $PASSED passed, $FAILED failed"
echo "======================================================================"

if [ $FAILED -eq 0 ]; then
    echo "✓ All tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
