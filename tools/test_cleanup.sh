#!/usr/bin/env bash
# POC Test: Verify tmux cleanup doesn't leak sessions
set -euo pipefail

echo "=== POC: Testing tmux cleanup ===" >&2
echo "" >&2

LABEL="as-cc-cleanup-test"

# Kill any existing test sessions
echo "Cleaning up any pre-existing test sessions..." >&2
tmux -L "$LABEL" kill-server 2>/dev/null || true
sleep 0.5

# Verify no sessions exist
if tmux -L "$LABEL" ls 2>/dev/null; then
    echo "✗ Found leftover sessions before test!" >&2
    exit 1
fi
echo "✓ No pre-existing sessions" >&2

# Test 1: Normal cleanup via trap
echo "" >&2
echo "Test 1: Normal cleanup via trap" >&2
(
    trap 'tmux -L "$LABEL" kill-server 2>/dev/null || true' EXIT
    tmux -L "$LABEL" new-session -d -s "test1" "sleep 100"
    echo "  Created session test1" >&2
    tmux -L "$LABEL" ls >&2
)

sleep 0.5
if tmux -L "$LABEL" ls 2>/dev/null; then
    echo "✗ Trap cleanup failed - session still exists!" >&2
    exit 1
fi
echo "✓ Trap cleanup succeeded" >&2

# Test 2: Cleanup on error
echo "" >&2
echo "Test 2: Cleanup on error" >&2
(
    trap 'tmux -L "$LABEL" kill-server 2>/dev/null || true' EXIT
    tmux -L "$LABEL" new-session -d -s "test2" "sleep 100"
    echo "  Created session test2" >&2
    echo "  Simulating error..." >&2
    exit 1  # Trigger error
) || true  # Capture error

sleep 0.5
if tmux -L "$LABEL" ls 2>/dev/null; then
    echo "✗ Error cleanup failed - session still exists!" >&2
    exit 1
fi
echo "✓ Error cleanup succeeded" >&2

# Test 3: Multiple rapid cleanup cycles (simulating re-entrancy)
echo "" >&2
echo "Test 3: Running 5 rapid cleanup cycles" >&2
for i in {1..5}; do
    (
        trap 'tmux -L "$LABEL-$i" kill-server 2>/dev/null || true' EXIT
        tmux -L "$LABEL-$i" new-session -d -s "cycle$i" "sleep 100" 2>/dev/null || true
    )
    sleep 0.1
done

sleep 0.5

# Check all labels are clean
leaked=0
for i in {1..5}; do
    if tmux -L "$LABEL-$i" ls 2>/dev/null; then
        echo "✗ Leaked session on label $i!" >&2
        ((leaked++))
    fi
done

if [ $leaked -gt 0 ]; then
    echo "✗ Found $leaked leaked sessions!" >&2
    exit 1
fi
echo "✓ All 5 cycles cleaned up successfully" >&2

echo "" >&2
echo "✓ POC successful: Cleanup mechanism is reliable" >&2
