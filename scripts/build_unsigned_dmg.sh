#!/usr/bin/env bash
# Builds an UNSIGNED Agent Sessions.app and wraps it in a DMG, for forks and local
# builds that have no Apple Developer certificate.
#
#   ./scripts/build_unsigned_dmg.sh [version]
#
# The signed, notarized release path is tools/release/deploy-agent-sessions.sh; this is
# not a substitute for it. macOS quarantines an unsigned app downloaded from the web, so
# the DMG ships a NOTE with the one-time command that clears it.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-$(git -C "$repo" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
version="${version:-0.0.0}"
build="$repo/dist/.dmg-build"
stage="$repo/dist/.dmg-stage"
dmg="$repo/dist/AgentSessions-$version-unsigned.dmg"

rm -rf "$build" "$stage" "$dmg"
xcodebuild -project "$repo/AgentSessions.xcodeproj" -scheme AgentSessions \
  -configuration Release -derivedDataPath "$build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build >/dev/null

app="$build/Build/Products/Release/AgentSessions.app"
[ -d "$app" ] || { echo "app not found at $app" >&2; exit 1; }

mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
cat > "$stage/NOTE - unsigned build.txt" <<'EOF'
This build is not signed or notarized, so macOS blocks it on first launch.
After dragging Agent Sessions to Applications, run once in Terminal:

    xattr -dr com.apple.quarantine /Applications/AgentSessions.app

Then open it normally. Official signed releases come from the upstream project.
EOF

hdiutil create -volname "Agent Sessions $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null
shasum -a 256 "$dmg" | tee "$dmg.sha256"
rm -rf "$build" "$stage"
