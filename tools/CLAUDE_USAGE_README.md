# Claude Usage Capture Tool

Headless collector for Claude CLI `/usage` metrics using detached tmux sessions.

## Installation

### Prerequisites

```bash
# macOS (Homebrew)
brew install tmux

# Verify Claude CLI is installed
claude --version
```

## Usage

```bash
./claude_usage_capture.sh
```

### Output (JSON to stdout)

```json
{
  "ok": true,
  "source": "tmux-capture",
  "session_5h": {
    "pct_used": 2,
    "resets": "1am (America/Los_Angeles)"
  },
  "week_all_models": {
    "pct_used": 7,
    "resets": "Oct 9 at 2pm (America/Los_Angeles)"
  },
  "week_opus": {
    "pct_used": 3,
    "resets": "Oct 9 at 2pm (America/Los_Angeles)"
  }
}
```

*Note: `week_opus` will be `null` if no Opus usage is tracked.*

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL` | `sonnet` | Claude model to launch |
| `TIMEOUT_SECS` | `10` | Boot wait deadline (seconds) |
| `SLEEP_BOOT` | `0.4` | Polling interval during boot (seconds) |
| `SLEEP_AFTER_USAGE` | `1.2` | Wait after sending /usage (seconds) |
| `WORKDIR` | `$(pwd)` | Working directory (use trusted dir to avoid prompts) |

### Example with Custom Settings

```bash
MODEL=opus TIMEOUT_SECS=15 ./claude_usage_capture.sh
```

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | - |
| `12` | TUI failed to boot | Check if Claude CLI is responsive |
| `13` | Auth required | Run `claude login` |
| `14` | Claude CLI not found | Install Claude CLI |
| `15` | tmux not found | Run `brew install tmux` |
| `16` | Parsing failed | TUI format may have changed |

## Error Output

On error, JSON is still emitted:

```json
{"ok":false,"error":"tmux_not_found","hint":"Install tmux: brew install tmux"}
```

## Testing

```bash
# Quick test
./claude_usage_capture.sh | python3 -m json.tool

# Run 5 times to verify no process leaks
for i in {1..5}; do ./claude_usage_capture.sh >/dev/null; done
ps aux | grep tmux  # Should show no leaked processes
```

## Performance

- **Target:** < 10 seconds under normal conditions
- **Typical:** 3-6 seconds
- **Safe for:** 60-second polling intervals

## Notes

- Uses isolated tmux server (`-L as-cc-$$`) to avoid interference with user sessions
- Handles first-run trust prompts automatically (best-effort)
- No GUI/AppleScript required - fully headless
- Cleanup is guaranteed via EXIT trap
