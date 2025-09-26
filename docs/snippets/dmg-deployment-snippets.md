# DMG Deployment & Notarization — Snippet Toolbox

Curated shell snippets for common macOS app packaging steps. Adapt names/certificates/paths for your app.

## Sign the .app bundle

```bash
APP="MyApp.app"
ID="Developer ID Application: Your Name (TEAMID)"

codesign \
  --deep --force --options runtime \
  --entitlements "entitlements.plist" \
  --timestamp --sign "$ID" "$APP"

# Verify
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --verbose=4 "$APP"
```

## Create a DMG (hdiutil)

```bash
VOL="MyApp Installer"
DMG="MyApp-1.2.3.dmg"

hdiutil create -volname "$VOL" -srcfolder "$APP" -ov -format UDZO "$DMG"
```

Or use create-dmg (if you want a layout):

```bash
npm i -g create-dmg  # or brew install create-dmg
create-dmg "$APP" --overwrite --dmg-title "MyApp 1.2.3" --out .
```

## Notarize & Staple (Xcode 14+/Command Line Tools)

```bash
DMG="MyApp-1.2.3.dmg"
PROFILE="AC_PROFILE_NAME"   # set up with `xcrun notarytool store-credentials`

xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait

# Staple the ticket
xcrun stapler staple "$DMG"

# Verify
spctl --assess --type open --context context:primary-signature -vv "$DMG"
```

## Build & Export with xcodebuild (optional)

```bash
SCHEME="MyApp"
CONF="Release"
ARCHIVE="build/MyApp.xcarchive"
EXPORT="build/export"

xcodebuild -scheme "$SCHEME" -configuration "$CONF" \
  -archivePath "$ARCHIVE" archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT"
```

## Build a signed PKG (alternative distribution)

```bash
PKG="MyApp-1.2.3.pkg"
ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)"

pkgbuild --install-location "/Applications" \
  --component "$APP" "$PKG"

productsign --sign "$ID_INSTALLER" "$PKG" "$PKG"
```

## GitHub Release (gh CLI)

```bash
TAG="v1.2.3"
gh release create "$TAG" MyApp-1.2.3.dmg \
  --title "MyApp $TAG" \
  --notes "Highlights, fixes, and checksums"
```

## Checksums

```bash
shasum -a 256 MyApp-1.2.3.dmg > MyApp-1.2.3.dmg.sha256
```

## Sparkle AppCast (if used)

```xml
<item>
  <title>Version 1.2.3</title>
  <enclosure url="https://example.com/MyApp-1.2.3.dmg" 
             sparkle:version="1.2.3" 
             sparkle:shortVersionString="1.2.3" 
             length="12345678" 
             type="application/octet-stream" 
             sparkle:dsaSignature="…"/>
  <sparkle:releaseNotesLink>https://example.com/release-notes/1.2.3.html</sparkle:releaseNotesLink>
</item>
```

---

Tip: Use Agent Sessions to search transcripts for “DMG”, “notarize”, “staple”, “codesign”, or “hdiutil” and resume the exact packaging session in your app’s repo.

