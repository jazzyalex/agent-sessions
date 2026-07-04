#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, staple, and upload a DMG for Agent Sessions.
# Requirements:
# - Xcode CLT (xcodebuild, notarytool)
# - Developer ID Application certificate installed in login keychain
# - notarytool keychain profile configured (default: AgentSessionsNotary), or
#   explicit NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD credentials
# - gh CLI authenticated to github.com (gh auth login)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/tools/release/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME_DEFAULT=$(sed -n 's/.*BuildableName = "\([^"]\+\)\.app".*/\1/p' AgentSessions.xcodeproj/xcshareddata/xcschemes/AgentSessions.xcscheme | head -n1)
APP_NAME=${APP_NAME:-${APP_NAME_DEFAULT:-AgentSessions}}
VERSION_DEFAULT=$(sed -n 's/.*MARKETING_VERSION = \([0-9.][0-9.]*\).*/\1/p' AgentSessions.xcodeproj/project.pbxproj | head -n1)
VERSION=${VERSION:-${VERSION_DEFAULT:-0.1}}
TAG=${TAG:-v$VERSION}

NOTARY_PROFILE=${NOTARY_PROFILE:-AgentSessionsNotary}

# Try to auto-detect a Developer ID Application identity if not provided
DEV_ID_APP=${DEV_ID_APP:-}
TEAM_ID=${TEAM_ID:-}

source "$REPO_ROOT/tools/release/notary-auth.sh"

build_notary_auth_args || exit $?

if [[ -z "$DEV_ID_APP" ]]; then
  if [[ -n "$TEAM_ID" ]]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | grep "(${TEAM_ID})" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"([^\"]+)\".*$/\1/') || true
    if [[ -n "$DETECTED" ]]; then DEV_ID_APP="$DETECTED"; fi
  fi
  if [[ -z "$DEV_ID_APP" ]]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"([^\"]+)\".*$/\1/') || true
    if [[ -n "$DETECTED" ]]; then DEV_ID_APP="$DETECTED"; fi
  fi
fi

if [[ -z "$DEV_ID_APP" ]]; then
  echo "ERROR: Could not locate a Developer ID Application identity in your keychain." >&2
  echo "Provide DEV_ID_APP (and optionally TEAM_ID to filter), e.g.:" >&2
  echo "  TEAM_ID=24NDRU35WD DEV_ID_APP=\"Developer ID Application: Your Name (24NDRU35WD)\" $0" >&2
  exit 2
fi

echo "App      : $APP_NAME"
echo "Version  : $VERSION"
echo "Identity : $DEV_ID_APP"
if [[ -n "$TEAM_ID" ]]; then echo "Team ID  : $TEAM_ID"; fi
echo "Notary   : $NOTARY_AUTH_LABEL"
echo "Tag      : $TAG"

DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
VOL="Agent Sessions"

echo "==> Building Release to $DIST"
echo "    Note: Xcode may spend several minutes in swift-frontend during Release whole-module optimization."
echo "    This is expected for universal release builds; progress heartbeats will print every 60s."
rm -rf "$DIST" build || true
mkdir -p "$DIST"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$DIST" || true

BUILD_PID=""
HEARTBEAT_PID=""
cleanup_release_build() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "${HEARTBEAT_PID:-}" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi

  if [[ -n "${BUILD_PID:-}" ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
    echo "==> Stopping Release build process $BUILD_PID"
    kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
  fi

  exit "$status"
}
trap cleanup_release_build EXIT INT TERM

xcodebuild -scheme AgentSessions -configuration Release -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$DIST" clean build &
BUILD_PID=$!
(
  elapsed=0
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 60
    elapsed=$((elapsed + 60))
    if kill -0 "$BUILD_PID" 2>/dev/null; then
      echo "==> Release build still running (${elapsed}s elapsed; whole-module-optimized Release builds typically take ~8-12 min — not stalled while compiler processes are listed below)"
      swift_processes=$(ps -axo pid,etime,comm,args | awk '/swift-frontend/ && !/awk/ { print "    " $0 }' | head -5 || true)
      if [[ -n "$swift_processes" ]]; then
        echo "    Active Swift compiler processes:"
        echo "$swift_processes"
      fi
    fi
  done
) &
HEARTBEAT_PID=$!
BUILD_STATUS=0
if wait "$BUILD_PID"; then
  BUILD_STATUS=0
else
  BUILD_STATUS=$?
fi
kill "$HEARTBEAT_PID" 2>/dev/null || true
wait "$HEARTBEAT_PID" 2>/dev/null || true
trap - EXIT INT TERM
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  exit "$BUILD_STATUS"
fi

if [[ ! -d "$APP" ]]; then
  echo "ERROR: Build did not produce $APP" >&2
  exit 3
fi

echo "==> Codesigning app (hardened runtime)"
ENTITLEMENTS_FILE="AgentSessions/AgentSessions.entitlements"
EXTRA_ENTS=()
if [[ -f "$ENTITLEMENTS_FILE" ]]; then
  EXTRA_ENTS=(--entitlements "$ENTITLEMENTS_FILE")
fi

codesign --deep --force --options runtime --timestamp \
  "${EXTRA_ENTS[@]}" \
  --sign "$DEV_ID_APP" "$APP"

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# Verify we're using Developer ID, not ad-hoc signing
SIGNING_AUTHORITY=$(codesign -dv --verbose=4 "$APP" 2>&1 | grep "Authority=Developer ID Application" || true)
if [[ -z "$SIGNING_AUTHORITY" ]]; then
  echo "ERROR: App is not signed with Developer ID Application certificate!" >&2
  echo "This will cause notarization to fail." >&2
  codesign -dv --verbose=4 "$APP" 2>&1 | grep "Authority=" >&2
  exit 6
fi
echo "✅ Developer ID signature verified: $SIGNING_AUTHORITY"

spctl --assess --verbose=4 "$APP" || echo "Note: spctl assessment fails before notarization (expected)"

echo "==> Creating DMG: $DMG"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Verifying DMG integrity"
if ! hdiutil verify "$DMG"; then
  echo "ERROR: DMG verification failed! The DMG is corrupted." >&2
  echo "This usually means the app bundle was incomplete or damaged." >&2
  exit 4
fi
echo "✅ DMG verification passed"

echo "==> Verifying DMG is a valid disk image"
FILE_TYPE=$(file "$DMG")
if [[ ! "$FILE_TYPE" =~ "Macintosh HFS Extended" ]] && [[ ! "$FILE_TYPE" =~ "Apple partition map" ]] && [[ ! "$FILE_TYPE" =~ "zlib compressed data" ]]; then
  echo "ERROR: DMG does not appear to be a valid disk image!" >&2
  echo "File type: $FILE_TYPE" >&2
  exit 5
fi
echo "✅ DMG file type validated"

notarize_background() {
  local dmg="$1"
  local interval=30
  local max_wait=1200 # 20 minutes
  local log_file="/tmp/notarization-${VERSION:-unknown}-$(date +%s).log"

  echo "==> Notarizing DMG asynchronously (log: $log_file)"
  echo "Monitor in another shell: tail -f $log_file"

  # Submit for notarization without blocking
  local submission_json submission_id
  if ! submission_json=$(xcrun notarytool submit "$dmg" "${NOTARY_AUTH_ARGS[@]}" --output-format json 2>&1 | tee "$log_file"); then
    echo "ERROR: Notarization submission failed" >&2
    exit 7
  fi

  # Try jq first (most reliable), fallback to python
  if command -v jq >/dev/null 2>&1; then
    submission_id=$(echo "$submission_json" | jq -r '.id // empty' 2>/dev/null)
  fi

  # Fallback to python if jq failed or not available
  if [[ -z "$submission_id" ]]; then
    submission_id=$(printf '%s' "$submission_json" | python3 -c '
import json, re, sys
text = sys.stdin.read().strip()
data = {}
try:
    # First try: parse as-is
    data = json.loads(text)
except Exception as e:
    try:
        # Second try: extract last complete JSON object
        objects = []
        depth = 0
        start = -1
        for i, c in enumerate(text):
            if c == "{":
                if depth == 0:
                    start = i
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0 and start >= 0:
                    objects.append(text[start:i+1])
                    start = -1
        if objects:
            data = json.loads(objects[-1])
    except Exception as e2:
        # Debug output
        print(f"Parse error: {e}, {e2}", file=sys.stderr)
        pass
print(data.get("id", ""), end="")
' 2>&1)
  fi

  if [[ -z "$submission_id" ]]; then
    echo "ERROR: Could not parse notarization submission ID" >&2
    echo "Submission output was:" >&2
    echo "$submission_json" | head -20 >&2
    echo "Check log file: $log_file" >&2
    exit 7
  fi

  echo "Submission ID: $submission_id"

  local status="In Progress"
  local elapsed=0
  while [[ "$status" == "In Progress" ]]; do
    sleep "$interval"
    ((elapsed+=interval))

    local info_json
    if ! info_json=$(xcrun notarytool info "$submission_id" "${NOTARY_AUTH_ARGS[@]}" --output-format json 2>&1 | tee -a "$log_file"); then
      echo "ERROR: Failed to poll notarization status" >&2
      exit 7
    fi

    if command -v jq >/dev/null 2>&1; then
      status=$(echo "$info_json" | jq -r '.status // empty' 2>/dev/null)
    fi

    if [[ -z "${status:-}" ]]; then
      status=$(python3 -c '
import json, re, sys
text = sys.stdin.read().strip()
data = {}
try:
    # First try: parse as-is
    data = json.loads(text)
except Exception:
    try:
        # Second try: find JSON object with status field
        match = re.search(r"\{[^{}]*\"status\"[^{}]*\}", text)
        if match:
            data = json.loads(match.group(0))
    except Exception:
        try:
            # Third try: extract last complete JSON object
            objects = []
            depth = 0
            start = -1
            for i, c in enumerate(text):
                if c == "{":
                    if depth == 0:
                        start = i
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0 and start >= 0:
                        objects.append(text[start:i+1])
                        start = -1
            if objects:
                data = json.loads(objects[-1])
        except Exception:
            pass
print(data.get("status", ""), end="")
' <<< "$info_json" 2>/dev/null || true)
    fi

    echo "Notarization status: ${status:-unknown} (elapsed ${elapsed}s)" | tee -a "$log_file"

    if (( elapsed >= max_wait )); then
      echo "ERROR: Notarization polling timed out after ${max_wait}s" >&2
      exit 7
    fi
  done

  case "$status" in
    Accepted)
      echo "✅ Notarization accepted" | tee -a "$log_file"
      ;;
    *)
      echo "ERROR: Notarization finished with status '$status'" >&2
      echo "See log: $log_file" >&2
      exit 7
      ;;
  esac
}

if [[ "${NOTARIZE_SYNC:-0}" == "1" ]]; then
  echo "==> Notarizing DMG (synchronous mode)"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH_ARGS[@]}" --wait
else
  notarize_background "$DMG"
fi

echo "==> Stapling and verifying Gatekeeper"
xcrun stapler staple "$DMG"
spctl --assess --type open -vv "$DMG" || echo "Note: spctl assessment may fail in some environments"

echo "==> Checksumming"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
