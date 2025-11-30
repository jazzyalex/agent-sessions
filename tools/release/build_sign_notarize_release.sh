#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, staple, and upload a DMG for Agent Sessions.
# Requirements:
# - Xcode CLT (xcodebuild, notarytool)
# - Developer ID Application certificate installed in login keychain
# - notarytool keychain profile configured (default: AgentSessionsNotary)
# - gh CLI authenticated to github.com (gh auth login)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

APP_NAME_DEFAULT=$(sed -n 's/.*BuildableName = "\([^"]\+\)\.app".*/\1/p' AgentSessions.xcodeproj/xcshareddata/xcschemes/AgentSessions.xcscheme | head -n1)
APP_NAME=${APP_NAME:-${APP_NAME_DEFAULT:-AgentSessions}}
VERSION_DEFAULT=$(sed -n 's/.*MARKETING_VERSION = \([0-9.][0-9.]*\).*/\1/p' AgentSessions.xcodeproj/project.pbxproj | head -n1)
VERSION=${VERSION:-${VERSION_DEFAULT:-0.1.0}}
TAG=${TAG:-v$VERSION}

NOTARY_PROFILE=${NOTARY_PROFILE:-AgentSessionsNotary}

# Try to auto-detect a Developer ID Application identity if not provided
DEV_ID_APP=${DEV_ID_APP:-}
TEAM_ID=${TEAM_ID:-}
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
echo "Notary   : $NOTARY_PROFILE"
echo "Tag      : $TAG"

DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
VOL="Agent Sessions"

echo "==> Building Release to $DIST"
rm -rf "$DIST" build || true
mkdir -p "$DIST"
xattr -w com.apple.xcode.CreatedByBuildSystem true "$DIST" || true
xcodebuild -scheme AgentSessions -configuration Release -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$DIST" clean build

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
  local profile="$2"
  local interval=30
  local max_wait=1200 # 20 minutes
  local log_file="/tmp/notarization-${VERSION:-unknown}-$(date +%s).log"

  echo "==> Notarizing DMG asynchronously (log: $log_file)"
  echo "Monitor in another shell: tail -f $log_file"

  # Submit for notarization without blocking
  local submission_json submission_id
  if ! submission_json=$(xcrun notarytool submit "$dmg" --keychain-profile "$profile" --output-format json 2>&1 | tee "$log_file"); then
    echo "ERROR: Notarization submission failed" >&2
    exit 7
  fi

  submission_id=$(python3 <<'PYEOF'
import json, re, sys
text = sys.stdin.read()
data = {}
try:
    data = json.loads(text)
except Exception:
    # Fall back to last JSON object in the stream
    matches = list(re.finditer(r'{.*}', text, re.S))
    if matches:
        data = json.loads(matches[-1].group(0))
print(data.get("id", ""))
PYEOF
<<< "$submission_json")

  if [[ -z "$submission_id" ]]; then
    echo "ERROR: Could not parse notarization submission ID" >&2
    exit 7
  fi

  echo "Submission ID: $submission_id"

  local status="In Progress"
  local elapsed=0
  while [[ "$status" == "In Progress" ]]; do
    sleep "$interval"
    ((elapsed+=interval))

    local info_json
    if ! info_json=$(xcrun notarytool info "$submission_id" --keychain-profile "$profile" --output-format json 2>&1 | tee -a "$log_file"); then
      echo "ERROR: Failed to poll notarization status" >&2
      exit 7
    fi

    status=$(python3 <<'PYEOF'
import json, re, sys
text = sys.stdin.read()
data = {}
try:
    data = json.loads(text)
except Exception:
    matches = list(re.finditer(r'{.*}', text, re.S))
    if matches:
        data = json.loads(matches[-1].group(0))
print(data.get("status", ""))
PYEOF
<<< "$info_json")

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
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  notarize_background "$DMG" "$NOTARY_PROFILE"
fi

echo "==> Stapling and verifying Gatekeeper"
xcrun stapler staple "$DMG"
spctl --assess --type open -vv "$DMG" || echo "Note: spctl assessment may fail in some environments"

echo "==> Checksumming"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

if command -v gh >/dev/null 2>&1; then
  echo "==> Uploading to GitHub Release $TAG"
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  else
    gh release create "$TAG" "$DMG" "$DMG.sha256" \
      --title "$APP_NAME $VERSION" \
      --notes "Release $VERSION"
  fi
  echo "Done."
else
  echo "gh CLI not found. Skipping GitHub release upload."
  echo "Run: gh auth login; then rerun this script or run:\n  gh release create $TAG \"$DMG\" \"$DMG.sha256\" --title \"$APP_NAME $VERSION\" --notes \"Release $VERSION\"" 
fi
