#!/bin/bash
# Runs one mode of the SessionIndexer.deinit segv diagnostics and summarizes the result.
# Used by .github/workflows/segv-diagnostics.yml; also runs locally.
#
#   control       Over-releases a subject on purpose. Fails unless the instrument reports it.
#   stress-plain  Stress tests without ASan. Measures the crash rate on this OS.
#   stress-asan   Stress tests with ASan. A crash prints the stack that freed the subject.
#   suite-asan    Full suite with ASan, for a trigger that only the suite's state creates.
#
# Exit 0: the mode ran and did not reproduce the crash (control: the instrument works).
# Exit 1: the crash reproduced. Read the report in $DIAGNOSTICS_DIR.
# Exit 2: the run proved nothing, for example no build or skipped tests.
set -uo pipefail

mode="${1:?usage: ci_segv_diagnostics.sh control|stress-plain|stress-asan|suite-asan}"
out="${DIAGNOSTICS_DIR:-$PWD/segv-diagnostics}"
stress_n="${STRESS_N:-30000}"
iterations="${TEST_ITERATIONS:-1}"
stress_tests=AgentSessionsTests/SessionIndexerLifecycleStressTests
log="$out/xcodebuild.log"
summary="$out/summary.txt"

mkdir -p "$out/asan" "$out/crash-reports"
started=$(mktemp)

xcode_args=(
  -project AgentSessions.xcodeproj
  -scheme AgentSessions
  -configuration Debug
  -destination 'platform=macOS'
  -derivedDataPath .deriveddata-segv
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=NO
)

case "$mode" in
  control)
    xcode_args+=("-only-testing:$stress_tests/testPositiveControlOverReleasedPublishedSubject")
    export TEST_RUNNER_STRESS_POSITIVE_CONTROL=1
    ;;
  stress-plain | stress-asan)
    xcode_args+=(
      "-only-testing:$stress_tests/testIndexerLifecycleOnCooperativeThreads"
      "-only-testing:$stress_tests/testIndexerLifecycleOnMainThreadWithDetachedTasks"
    )
    export TEST_RUNNER_STRESS_N="$stress_n"
    ;;
  suite-asan)
    # xcodebuild rejects -test-iterations 1.
    if [[ "$iterations" -gt 1 ]]; then
      xcode_args+=(-test-iterations "$iterations")
    fi
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

if [[ "$mode" != stress-plain ]]; then
  xcode_args+=(-enableAddressSanitizer YES)
  export TEST_RUNNER_SEGV_DIAGNOSTICS=1
  # handle_segv=0 leaves the crash to SegvDiagnostics. The zero fill makes a freed subject
  # fault on its null lock, which is what macOS 26 does without ASan.
  export TEST_RUNNER_ASAN_OPTIONS="log_path=$out/asan/report:handle_segv=0:handle_sigbus=0:max_free_fill_size=256:free_fill_byte=0:quarantine_size_mb=512:malloc_context_size=40"
fi

xcodebuild "${xcode_args[@]}" test > "$log" 2>&1
xcodebuild_status=$?

# ReportCrash writes the .ips after the process has gone.
crashed=0
if grep -q 'Restarting after unexpected exit' "$log"; then
  for _ in {1..30}; do
    find ~/Library/Logs/DiagnosticReports -name 'AgentSessions*.ips' -newer "$started" 2>/dev/null | grep -q . && break
    /bin/sleep 2
  done
fi
find ~/Library/Logs/DiagnosticReports -name 'AgentSessions*.ips' -newer "$started" \
  -exec cp {} "$out/crash-reports/" \; 2>/dev/null

if grep -q 'PublishedSubject.disassociate' "$out"/crash-reports/*.ips 2>/dev/null; then
  crashed=1
fi

passed=$(grep -c "Test Case '.*' passed" "$log")

{
  echo "mode: $mode"
  echo "os: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "xcodebuild exit: $xcodebuild_status"
  echo "tests started: $(grep -c "Test Case '.*' started" "$log")"
  echo "tests passed: $passed"
  echo "tests failed: $(grep -c "Test Case '.*' failed" "$log")"
  echo "tests skipped: $(grep -c "Test Case '.*' skipped" "$log")"
  echo "host restarts: $(grep -c 'Restarting after unexpected exit' "$log")"
  echo "crash reports: $(find "$out/crash-reports" -name '*.ips' | wc -l | tr -d ' ')"
  echo "PublishedSubject crash: $crashed"
  if compgen -G "$out/asan/report*" > /dev/null; then
    echo
    echo "--- ASan reports (first 45 lines of each, frames in XCTest removed) ---"
    for report in "$out"/asan/report*; do
      echo "## $(basename "$report")"
      grep -v 'XCT' "$report" | head -45 | cut -c1-160
    done
  fi
} > "$summary"

cat "$summary"
gzip -f "$log"

if [[ -z "$(ls "$out"/crash-reports/*.ips 2>/dev/null)" && "$passed" -eq 0 ]]; then
  echo "NO EVIDENCE: nothing crashed and no test passed" >&2
  exit 2
fi

case "$mode" in
  control)
    if [[ "$crashed" == 1 ]] \
      && cat "$out"/asan/report* 2>/dev/null | grep -q 'freed by thread' \
      && cat "$out"/asan/report* 2>/dev/null | grep -q 'PublishedSubject.__allocating_init'; then
      echo "INSTRUMENT OK: the crash reproduced and ASan named the freed subject"
      exit 0
    fi
    echo "INSTRUMENT BROKEN: do not trust the other jobs" >&2
    exit 2
    ;;
  stress-plain | stress-asan)
    if [[ "$crashed" == 0 && "$passed" -ne 2 ]]; then
      echo "NO EVIDENCE: expected 2 passing stress tests" >&2
      exit 2
    fi
    ;;
esac

if [[ "$crashed" == 1 ]]; then
  echo "REPRODUCED: see $out"
  exit 1
fi
echo "Not reproduced in this run"
exit 0
