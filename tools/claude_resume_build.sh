#!/usr/bin/env bash
set -euo pipefail

# Build a Claude CLI command for resume/continue.
# Usage:
#   tools/claude_resume_build.sh --mode resume --id <session-id> --cwd <path> [--bin claude]
#   tools/claude_resume_build.sh --mode continue --cwd <path> [--bin claude]

MODE=
SID=
CWD=
BIN=${CLAUDE_BIN:-claude}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --id) SID=$2; shift 2 ;;
    --cwd) CWD=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$MODE" ]]; then echo "--mode is required (resume|continue)" >&2; exit 2; fi
if [[ "$MODE" == "resume" && -z "$SID" ]]; then echo "--id is required for resume mode" >&2; exit 2; fi

_q() { printf '%q' "$1"; }

CMD=""
if [[ -n "${CWD:-}" ]]; then
  CMD+="cd $(_q "$CWD"); "
fi

if [[ "$MODE" == "resume" ]]; then
  CMD+="$(_q "$BIN") --resume $(_q "$SID")"
elif [[ "$MODE" == "continue" ]]; then
  CMD+="$(_q "$BIN") --continue"
else
  echo "invalid --mode: $MODE" >&2; exit 2
fi

echo "$CMD"

