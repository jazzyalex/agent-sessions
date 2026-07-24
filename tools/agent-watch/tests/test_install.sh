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

# The command names must come from agent-watch-config.json, not a lookalike
# list. `agy` and `cursor-agent` are the two that a guess gets wrong.
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
for cmd in agy cursor-agent; do
  resolved="$(command -v "$cmd" 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    assert_contains "$(dirname "$resolved")" "$PLIST" "config-derived command '$cmd' baked into launchd PATH"
  else
    pass "config-derived command '$cmd' not installed here (skipped)"
  fi
done
CONFIG_CMDS="$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
print(" ".join(sorted({a["installed_version_cmd"][0] for a in c["agents"].values() if a.get("installed_version_cmd")})))
' "$REPO_ROOT/docs/agent-support/agent-watch-config.json")"
case "$CONFIG_CMDS" in
  *agy*) pass "config still names 'agy' (test stays meaningful)";;
  *) fail "config no longer names 'agy' — update this test";;
esac

# Weekly, not daily — Weekday must be pinned or launchd runs it every morning.
assert_contains "<key>Weekday</key>" "$PLIST" "schedule is weekly (Weekday pinned)"
case "$PLIST" in *RunAtLoad*) fail "should have no RunAtLoad (no catch-up storm on login)";;
                 *) pass "no RunAtLoad";; esac

echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"; [ "$FAILED" -eq 0 ] || exit 1
