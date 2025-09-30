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

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --verbose=4 "$APP" || echo "Note: spctl assessment fails before notarization (expected)"

echo "==> Creating DMG: $DMG"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Notarizing DMG (this may take a minute)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling and verifying Gatekeeper"
xcrun stapler staple "$DMG"
spctl --assess --type open -vv "$DMG"

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
