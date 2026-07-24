#!/usr/bin/env bash
# Renders the LaunchAgent plist to a tempdir and checks it. Installs nothing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); echo "  ok - $1"; }
fail() { FAILED=$((FAILED+1)); echo "  NOT OK - $1" >&2; }
assert_contains() { case "$2" in *"$1"*) pass "$3";; *) fail "$3 (missing [$1])";; esac; }

DEST="$(mktemp -d)/com.agentsessions.agent-watch.plist"
bash "$ROOT/install.sh" --render-only "$DEST"
[ -f "$DEST" ] && pass "plist rendered" || fail "plist rendered"
PLIST="$(cat "$DEST")"

case "$PLIST" in
  *__RUN_WEEKLY_SH__*|*__HOME__*|*__OUT_ROOT__*|*__PATH__*) fail "a placeholder was left unsubstituted";;
  *) pass "all placeholders substituted";;
esac

assert_contains "$ROOT/run-weekly.sh" "$PLIST" "absolute run-weekly.sh path"
assert_contains "/opt/homebrew/bin" "$PLIST" "PATH includes homebrew"

# The whole point of baking PATH in: python3 must resolve under launchd's bare
# environment or the job dies before agent_watch.py prints anything.
PY_DIR="$(dirname "$(command -v python3)")"
assert_contains "$PY_DIR" "$PLIST" "resolved python3 dir baked into launchd PATH"

# Weekly, not daily — Weekday must be pinned or launchd runs it every morning.
assert_contains "<key>Weekday</key>" "$PLIST" "schedule is weekly (Weekday pinned)"
case "$PLIST" in *RunAtLoad*) fail "should have no RunAtLoad (no catch-up storm on login)";;
                 *) pass "no RunAtLoad";; esac

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"; [ "$FAILED" -eq 0 ] || exit 1
