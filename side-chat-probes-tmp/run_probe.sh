#!/usr/bin/env bash
set -euo pipefail

ROOT="${CODEX_HOME:-$HOME/.codex}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.build"
BIN="$OUT_DIR/SideChatShapeProbe"

mkdir -p "$OUT_DIR"

swiftc "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/SideChatShapeProbe.swift" -o "$BIN"

ARGS=()
if [[ -f "$ROOT/state_5.sqlite" ]]; then
  ARGS+=(--state-db "$ROOT/state_5.sqlite")
elif [[ -f "$ROOT/sqlite/state_5.sqlite" ]]; then
  ARGS+=(--state-db "$ROOT/sqlite/state_5.sqlite")
fi

if [[ -d "$ROOT/sessions" ]]; then
  ARGS+=("$ROOT/sessions")
fi
if [[ -d "$ROOT/archived_sessions" ]]; then
  ARGS+=("$ROOT/archived_sessions")
fi

if [[ "${#ARGS[@]}" -eq 0 ]]; then
  echo "No Codex JSONL roots found under $ROOT" >&2
  exit 1
fi

"$BIN" "$@" "${ARGS[@]}"
