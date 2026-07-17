#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/harness.sh"; with_stubs
export TRIAGE_ROOT="$HERE/.."; export POLICY_FILE="$TRIAGE_ROOT/policy.json"
DEST="$(mktemp -d)/com.agentsessions.triage.plist"

bash "$TRIAGE_ROOT/install.sh" --render-only "$DEST"
assert_file_exists "$DEST" "plist rendered"
case "$(cat "$DEST")" in
  *"__TRIAGE_SH__"*|*"__HOME__"*|*"__OUT_ROOT__"*) fail "a placeholder was left unsubstituted";;
  *) pass "all placeholders substituted";;
esac
assert_contains "/opt/homebrew/bin" "$(cat "$DEST")" "PATH includes homebrew"
CANON="$(cd "$TRIAGE_ROOT" && pwd)"   # install.sh canonicalizes its own dir
assert_contains "$CANON/triage.sh" "$(cat "$DEST")" "absolute triage.sh path"
# regression: the resolved tool dirs (esp. claude, often in ~/.local/bin off the
# default PATH) must be baked into the plist PATH or the scheduled run can't find them.
CLAUDE_DIR="$(dirname "$(command -v claude)")"
assert_contains "$CLAUDE_DIR" "$(cat "$DEST")" "resolved claude dir baked into launchd PATH"
# lean: plain daily schedule, no RunAtLoad catch-up
case "$(cat "$DEST")" in *RunAtLoad*) fail "should have no RunAtLoad (lean daily)";; *) pass "no RunAtLoad (lean daily)";; esac
finish
