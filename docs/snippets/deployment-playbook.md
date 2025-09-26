# Deployment Playbook (macOS DMG / PKG / Notarization)

This page collects reusable, copy‑pasteable snippets you can adapt for your app. The goal is to keep everything parameterized so you can tweak a few variables and ship.

## Quick Vars (Agent Sessions defaults)

```bash
# App basics
APP_NAME="Agent Sessions"
APP_BUNDLE_ID="com.triada.AgentSessions"
VERSION="1.0.0"
# Detected debug build (replace with Release path as needed)
APP="DerivedData/Build/Products/Debug/AgentSessions.app"
ENTITLEMENTS="entitlements.plist"   # optional

# Discover Developer ID identities from your keychain (no manual TEAM_ID needed)
DEV_ID_APP="Developer ID Application: Alex M (24NDRU35WD)"   # detected from keychain
DEV_ID_INSTALLER=""  # (optional) paste your Installer cert if you plan to ship PKG

if [ -z "$DEV_ID_APP" ]; then echo "[WARN] No 'Developer ID Application' identity found in keychain."; fi
if [ -z "$DEV_ID_INSTALLER" ]; then echo "[WARN] No 'Developer ID Installer' identity found in keychain."; fi

# Notarytool (set up once with: xcrun notarytool store-credentials)
NOTARY_PROFILE="AgentSessionsNotary"  # confirmed profile; already used successfully

# DMG / Release
VOL="$APP_NAME Installer"
DMG="$APP_NAME-$VERSION.dmg"
TAG="v$VERSION"
```

Tip: if you haven’t configured `notarytool` yet:

```bash
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "appleid@example.com" \
  --team-id "$TEAM_ID" \
  --password "app-specific-password"
```

---

## 1) Sign the .app

```bash
codesign \
  --deep --force --options runtime --timestamp \
  ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} \
  --sign "$DEV_ID_APP" "$APP"

# Verify (both developer and Gatekeeper views)
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --verbose=4 "$APP"
```

Common pitfall: nested frameworks and helper tools must also be signed; `--deep` helps, but validate with the verify commands above.

---

## 2) Build a DMG

Minimal, built‑in `hdiutil`:

```bash
hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"
```

Alternative (prettier layout): [`create-dmg`](https://github.com/create-dmg/create-dmg)

```bash
# brew install create-dmg   # or: npm i -g create-dmg
create-dmg "$APP" --overwrite --dmg-title "$APP_NAME $VERSION" --out .
```

---

## 3) Notarize & Staple

```bash
# Submit and wait (Xcode CLT 14+)
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

# Staple the ticket and verify Gatekeeper
yes | xcrun stapler staple "$DMG"
spctl --assess --type open -vv "$DMG"
```

If submission fails, re‑check:
- the Developer ID Application signature on the `.app` inside the DMG
- your credentials profile name
- Apple service availability (can be transient)

Verification & history:

```bash
# View recent submissions made with this profile
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --limit 3

# Fetch a specific request log (example from a prior run)
xcrun notarytool log e870b4ad-9c9b-4649-8832-c27227deb5f2 \
  --keychain-profile "$NOTARY_PROFILE"
```

If you need to create the profile (already present for this project), run once:

```bash
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "<your-apple-id@example.com>" \
  --team-id "24NDRU35WD" \
  --password "<app-specific-password>"
```

---

## 4) Optional: Signed PKG Path

```bash
PKG="$APP_NAME-$VERSION.pkg"

pkgbuild --install-location "/Applications" \
  --component "$APP" "$PKG"

productsign --sign "$DEV_ID_INSTALLER" "$PKG" "$PKG"

# Notarize & staple the PKG (same flow as DMG)
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
yes | xcrun stapler staple "$PKG"
spctl --assess --type install -vv "$PKG"
```

---

## 5) Checksums & GitHub Release

```bash
shasum -a 256 "$DMG" > "$DMG.sha256"

# Requires gh CLI authenticated to your repo (replace with your GitHub org/repo)
# gh release create will fail if tag exists; use `upload` to add assets
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
else
  gh release create "$TAG" "$DMG" "$DMG.sha256" \
    --title "$APP_NAME $VERSION" \
    --notes "Release $VERSION"
fi
```

---

## 6) (Optional) Sparkle AppCast Item

```xml
<item>
  <title>Version $VERSION</title>
  <enclosure url="https://example.com/downloads/$DMG" 
             sparkle:version="$VERSION" 
             sparkle:shortVersionString="$VERSION" 
             length="$(stat -f%z "$DMG")" 
             type="application/octet-stream"/>
  <sparkle:releaseNotesLink>https://example.com/notes/$VERSION.html</sparkle:releaseNotesLink>
</item>
```

---

## One‑Shot Script (drop‑in)

```bash
#!/usr/bin/env bash
set -euo pipefail

# 0) Vars (edit to taste)
APP_NAME="MyApp"; VERSION="1.2.3"; TEAM_ID="TEAMID1234"
APP="dist/$APP_NAME.app"; ENTITLEMENTS="entitlements.plist"
DEV_ID_APP="Developer ID Application: Your Name ($TEAM_ID)"
DEV_ID_INSTALLER="Developer ID Installer: Your Name ($TEAM_ID)"
NOTARY_PROFILE="NotaryProfileName"; VOL="$APP_NAME Installer"; DMG="$APP_NAME-$VERSION.dmg"

run(){ echo "+ $*"; "$@"; }

run codesign --deep --force --options runtime --timestamp \
  ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} \
  --sign "$DEV_ID_APP" "$APP"
run codesign --verify --deep --strict --verbose=2 "$APP"
run spctl --assess --verbose=4 "$APP"

run hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"
run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
run xcrun stapler staple "$DMG"
run spctl --assess --type open -vv "$DMG"

run shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Done → $DMG"
```

---

## Troubleshooting Cheatsheet

- “Rejected – The executable does not have the hardened runtime”
  - Ensure `--options runtime` was used; resign nested binaries if needed.
- “The signature does not include a secure timestamp”
  - Add `--timestamp` to codesign.
- “no keychain-profile named …”
  - Run `xcrun notarytool store-credentials` again and confirm the profile name.
- Gatekeeper blocks open
  - Verify with `spctl --assess --type open -vv <dmg>` and check the detailed reason.
- Notarization times out
  - Re‑submit; Apple’s service can be temporarily slow.

---

## What to automate later

- A Makefile with `sign`, `dmg`, `notarize`, `staple`, `release` targets
- A GitHub Actions workflow to build/sign/upload on tags
- A “Copy Launch Command” in Agent Sessions to reproduce the exact Codex resume command (documented idea, not implemented)
