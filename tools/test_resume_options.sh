#!/usr/bin/env bash
set -euo pipefail

# Orchestrate testing of Claude CLI resume/continue options using local sample sessions.
# By default this prints candidate sessions and dry-run commands.
#
# Usage:
#   tools/test_resume_options.sh [--limit 3] [--root ./.claude] [--bin claude] [--launch]
#
# Flags:
#   --limit N     Number of sessions to test (default 3)
#   --root PATH   Root of Claude logs (default $CLAUDE_ROOT or $HOME/.claude)
#   --bin PATH    Path to claude binary (default `claude`)
#   --launch      Launch commands in Terminal via osascript (default is dry-run)

LIMIT=3
ROOT=
BIN=${CLAUDE_BIN:-claude}
LAUNCH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT=$2; shift 2 ;;
    --root) ROOT=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    --launch) LAUNCH=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "[test] probing CLI..."
tools/claude_cli_probe.sh "$BIN" || true

PICK_ARGS=(--limit "$LIMIT")
if [[ -n "${ROOT:-}" ]]; then PICK_ARGS+=(--root "$ROOT"); fi

echo
echo "[test] selecting $LIMIT session(s)..."
SESS_FILE=$(mktemp)
tools/pick_claude_sessions.py "${PICK_ARGS[@]}" | tee "$SESS_FILE"

echo
echo "[test] building commands (dry-run=${LAUNCH:-0})..."
tail -n +2 "$SESS_FILE" | while IFS=$'\t' read -r SID CWD FILE; do
  echo "- file: $FILE"
  echo "  cwd:  ${CWD:-<none>}"
  echo "  id:   ${SID:-<none>}"

  if [[ -n "${SID:-}" ]]; then
    CMD=$(tools/claude_resume_build.sh --mode resume --id "$SID" ${CWD:+--cwd "$CWD"} --bin "$BIN")
    echo "  resume_cmd: $CMD"
    if [[ "$LAUNCH" == "1" ]]; then
      if command -v osascript >/dev/null 2>&1; then
        osascript -e "tell application \"Terminal\" to do script \"$CMD\"" -e "tell application \"Terminal\" to activate" || true
      else
        echo "  (no osascript; skipping launch)"
      fi
    fi
  else
    echo "  resume_cmd: <skipped: missing sessionId>"
  fi

  if [[ -n "${CWD:-}" ]]; then
    CMD2=$(tools/claude_resume_build.sh --mode continue --cwd "$CWD" --bin "$BIN")
    echo "  continue_cmd: $CMD2"
    if [[ "$LAUNCH" == "1" ]]; then
      if command -v osascript >/dev/null 2>&1; then
        osascript -e "tell application \"Terminal\" to do script \"$CMD2\"" -e "tell application \"Terminal\" to activate" || true
      else
        echo "  (no osascript; skipping launch)"
      fi
    fi
  else
    echo "  continue_cmd: <skipped: missing cwd>"
  fi

  echo
done

rm -f "$SESS_FILE"
echo "[done]"

