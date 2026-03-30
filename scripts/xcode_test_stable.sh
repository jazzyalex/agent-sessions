#!/usr/bin/env bash
set -euo pipefail

# Stable XCTest invocation for this repo.
# Uses isolated DerivedData and an explicit destination to avoid intermittent
# macOS nested test-bundle code-sign failures in shared/incremental state.

PROJECT="AgentSessions.xcodeproj"
SCHEME="AgentSessions"
CONFIGURATION="Debug"
DESTINATION="platform=macOS,arch=arm64"
DERIVED_DATA_PATH="${PWD}/.deriveddata-tests"

exec env AGENT_SESSIONS_TEST_MODE=1 xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -parallel-testing-enabled NO \
  clean test \
  "$@"
