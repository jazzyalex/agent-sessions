#!/usr/bin/env bash
# Shared helpers for the triage pipeline. Source, don't exec.
TRIAGE_ROOT="${TRIAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
POLICY_FILE="${POLICY_FILE:-$TRIAGE_ROOT/policy.json}"

policy_get() { jq -er "$1" "$POLICY_FILE"; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(utc_now)] $*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; return 1; }; }
