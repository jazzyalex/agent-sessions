#!/usr/bin/env bash
set -euo pipefail

# Stable XCTest invocation for this repo.
# Uses isolated DerivedData and an explicit destination to avoid intermittent
# macOS nested test-bundle code-sign failures in shared/incremental state.

PROJECT="AgentSessions.xcodeproj"
SCHEME="AgentSessions"
CONFIGURATION="Debug"
DESTINATION="platform=macOS,arch=arm64"
DERIVED_DATA_PATH=".deriveddata-tests"

exec env AGENT_SESSIONS_TEST_MODE=1 \
  TEST_RUNNER_AS_REAL_SESSION_REPLAY="${AS_REAL_SESSION_REPLAY:-0}" \
  TEST_RUNNER_AS_TOOL_CORPUS_CHECK="${AS_TOOL_CORPUS_CHECK:-0}" xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -parallel-testing-enabled NO \
  clean test \
  "$@"
