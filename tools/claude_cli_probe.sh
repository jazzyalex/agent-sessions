#!/usr/bin/env bash
set -euo pipefail

# Probe Claude CLI capabilities and print a concise report.
# Usage:
#   CLAUDE_BIN=claude tools/claude_cli_probe.sh
#   tools/claude_cli_probe.sh /usr/local/bin/claude

BIN=${1:-${CLAUDE_BIN:-claude}}

echo "[probe] binary: $BIN"

if ! command -v "$BIN" >/dev/null 2>&1; then
  echo "status=missing"
  echo "error=claude binary not found on PATH"
  exit 0
fi

set +e
VER_STR=$("$BIN" --version 2>&1 | head -n1)
HELP_STR=$("$BIN" --help 2>&1)
EXITCODE=$?
set -e

has_resume=0
has_resume_short=0
has_continue=0
has_continue_short=0

if grep -E -- '--resume\b' <<<"$HELP_STR" >/dev/null 2>&1; then has_resume=1; fi
if grep -E -- '\s-r\b' <<<"$HELP_STR" >/dev/null 2>&1; then has_resume_short=1; fi
if grep -E -- '--continue\b' <<<"$HELP_STR" >/dev/null 2>&1; then has_continue=1; fi
if grep -E -- '\s-c\b' <<<"$HELP_STR" >/dev/null 2>&1; then has_continue_short=1; fi

echo "status=ok"
echo "version=${VER_STR:-unknown}"
echo "has_resume=$has_resume"
echo "has_resume_short=$has_resume_short"
echo "has_continue=$has_continue"
echo "has_continue_short=$has_continue_short"

exit 0

