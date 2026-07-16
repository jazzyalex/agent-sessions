#!/usr/bin/env bash
# Shared assertion + stub helpers. Source after `set -euo pipefail`.
PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); echo "  ok - $1"; }
fail() { FAILED=$((FAILED+1)); echo "  NOT OK - $1" >&2; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected [$1] got [$2])"; fi; }
assert_contains() { case "$2" in *"$1"*) pass "$3";; *) fail "$3 (missing [$1])";; esac; }
assert_file_exists() { if [ -f "$1" ]; then pass "$2"; else fail "$2 (no file $1)"; fi; }
assert_file_absent() { if [ -e "$1" ]; then fail "$2 (unexpected $1)"; else pass "$2"; fi; }
# with_stubs: prepend the stub dir to PATH. Resolved lazily — `stubs/` is only
# created in later tasks, so eager resolution here would abort Task 1 under set -e.
with_stubs() {
  local stubs; stubs="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stubs" && pwd)"
  export PATH="$stubs:$PATH"
}
finish() { echo "----"; echo "PASSED=$PASSED FAILED=$FAILED"; [ "$FAILED" -eq 0 ] || exit 1; exit 0; }
