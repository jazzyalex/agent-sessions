# Sparkle Release Cookbook

## Document Purpose
Step-by-step guide for releasing Agent Sessions with Sparkle updates. Integrates with existing `tools/release/deploy-agent-sessions.sh` workflow.

## Prerequisites
- [ ] Xcode with Agent Sessions project
- [ ] Developer ID Application certificate installed
- [ ] Notarization profile configured (`xcrun notarytool store-credentials`)
- [ ] GitHub CLI (`gh`) authenticated
- [ ] Sparkle tools available (auto-detected after SPM build)

## One-Time Setup

### 1. Add Sparkle via Swift Package Manager
```bash
# In Xcode:
# File → Add Package Dependencies → https://github.com/sparkle-project/Sparkle
# Version: 2.x (use "Up to Next Major Version")
# Target: AgentSessions
```

### 2. Generate EdDSA Keys
After adding Sparkle, build the project once to download SPM artifacts:
```bash
# Build to fetch Sparkle
xcodebuild -scheme AgentSessions -configuration Release

# Find Sparkle tools
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

# Generate keys (creates Keychain entry + prints public key)
"$SPARKLE_DIR/generate_keys"
```

**Output**:
```
A key has been generated and saved in your Keychain.
Add the following to your Info.plist:
<key>SUPublicEDKey</key>
<string>YOUR_BASE64_PUBLIC_KEY_HERE</string>
```

**⚠️ IMPORTANT**:
- Private key is stored in Keychain under name "Sparkle"
- **Back up the private key** to 1Password or secure location:
  ```bash
  security find-generic-password -l "Sparkle" -w > ~/Desktop/sparkle-private-key-BACKUP.txt
  # Store this file securely and DELETE from Desktop after backup
  ```

### 3. Update Info.plist
Edit `AgentSessions/Info.plist` and add (see `InfoPlist-snippet.xml` for template):

```xml
<key>SUFeedURL</key>
<string>https://jazzyalex.github.io/agent-sessions/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>PASTE_YOUR_PUBLIC_KEY_FROM_generate_keys_HERE</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>

<key>SUAutomaticallyUpdate</key>
<false/>
```

### 4. Verify Sparkle Integration
Build and run locally:
```bash
# Force immediate update check
defaults delete com.triada.AgentSessions SULastCheckTime
open /Users/alexm/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Agent Sessions.app
```

Expected: App launches without errors. Check Console.app for Sparkle logs.

## Per-Release Workflow

### Step 1: Pre-Release Checklist
- [ ] Version bumped in Xcode (MARKETING_VERSION)
- [ ] CHANGELOG.md updated with release notes
- [ ] Code committed and pushed
- [ ] CI passing (if applicable)

### Step 2: Build & Notarize
Use existing release script with new appcast generation:

```bash
export VERSION=2.4.0
export TEAM_ID=24NDRU35WD
export NOTARY_PROFILE=AgentSessionsNotary
export DEV_ID_APP="Developer ID Application: Alex M (24NDRU35WD)"
export UPDATE_CASK=1
export SKIP_CONFIRM=1

# Run modified release script (includes appcast generation)
tools/release/deploy-agent-sessions.sh
```

**What the script does**:
1. Clean build Release configuration
2. Code sign with Developer ID
3. Create read-only DMG
4. Notarize with Apple (`xcrun notarytool submit --wait`)
5. Staple notarization ticket to DMG
6. **NEW**: Generate Sparkle appcast
7. Create GitHub release
8. Update Homebrew cask

### Step 3: Appcast Generation (Automated)
The release script will automatically:

```bash
# Inside deploy-agent-sessions.sh (new steps):

# 1. Create/update dist/updates directory
mkdir -p dist/updates

# 2. Copy DMG to updates directory
cp "dist/AgentSessions-${VERSION}.dmg" "dist/updates/"

# 3. Find Sparkle tools
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)

# 4. Generate appcast (reads Keychain for private key)
"$SPARKLE_BIN/generate_appcast" \
  --link "https://jazzyalex.github.io/agent-sessions/updates" \
  dist/updates/

# Output: dist/updates/appcast.xml
```

**Appcast contains**:
```xml
<item>
  <title>Version 2.4.0</title>
  <pubDate>Wed, 15 Oct 2025 12:00:00 +0000</pubDate>
  <sparkle:version>2.4.0</sparkle:version>
  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
  <enclosure url="https://jazzyalex.github.io/agent-sessions/updates/AgentSessions-2.4.0.dmg"
             sparkle:edSignature="BASE64_SIGNATURE"
             length="FILE_SIZE_BYTES"
             type="application/octet-stream" />
</item>
```

### Step 4: Publish to GitHub Pages
The release script will:

```bash
# 1. Copy appcast and DMG to docs/ (GitHub Pages source)
cp dist/updates/appcast.xml docs/appcast.xml
mkdir -p docs/updates
cp dist/updates/*.dmg docs/updates/

# 2. Commit and push
git add docs/appcast.xml docs/updates/
git commit -m "chore(release): publish ${VERSION} appcast"
git push origin main

# GitHub Pages serves from /docs, so appcast is live at:
# https://jazzyalex.github.io/agent-sessions/appcast.xml
```

**Verify publication**:
```bash
curl -I https://jazzyalex.github.io/agent-sessions/appcast.xml
# Should return: 200 OK
```

### Step 5: Test Update Flow
On a machine with previous version installed:

```bash
# Force update check
defaults delete com.triada.AgentSessions SULastCheckTime

# Launch app
open "/Applications/Agent Sessions.app"

# Expected: Sparkle detects update and shows alert (or gentle reminder if background)
```

### Step 6: Announce Release
- GitHub release is auto-created by script
- Optional: Post to Twitter/blog
- Monitor for user reports

## Troubleshooting

### Appcast Generation Fails
**Error**: `generate_appcast: command not found`

**Fix**:
```bash
# Build project once to fetch Sparkle SPM artifacts
xcodebuild -scheme AgentSessions -configuration Release

# Manually find and use tool
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
echo "Sparkle tools at: $(dirname "$SPARKLE_BIN")"
```

### Invalid EdDSA Signature
**Error**: "Update signature verification failed"

**Cause**: Appcast was generated with wrong private key or key not in Keychain.

**Fix**:
```bash
# Check Keychain for Sparkle key
security find-generic-password -l "Sparkle"

# If missing, restore from backup or regenerate (breaks existing users!)
```

### Users Not Seeing Updates
**Checklist**:
1. Appcast accessible via HTTPS:
   ```bash
   curl https://jazzyalex.github.io/agent-sessions/appcast.xml
   ```
2. DMG URL in appcast is correct and accessible
3. `SUFeedURL` in Info.plist matches appcast URL
4. EdDSA signature matches (verify with `generate_appcast --verify`)

### Delta Updates Not Generated
**Cause**: Need multiple versions in `dist/updates/` directory.

**Solution**: Keep old DMGs in `dist/updates/` and re-run `generate_appcast`:
```bash
# dist/updates/ should contain:
# - AgentSessions-2.3.0.dmg
# - AgentSessions-2.4.0.dmg
# - appcast.xml

"$SPARKLE_BIN/generate_appcast" dist/updates/
# Now appcast includes delta patches between versions
```

## Security Best Practices
1. **Never commit private key** to git
2. **Back up private key** to secure location (1Password, encrypted disk)
3. **Rotate keys** only if compromised (requires all users to manually update once)
4. **Verify DMG signature** before generating appcast:
   ```bash
   codesign -dv --verbose=4 dist/AgentSessions-2.4.0.dmg
   # Should show: Developer ID Application: Alex M (24NDRU35WD)
   ```

## Rollback Procedure
If a release has critical bugs:

1. **Immediate**: Publish previous version to appcast:
   ```bash
   # Re-run generate_appcast with only good versions
   cd dist/updates
   rm AgentSessions-2.4.0-BAD.dmg  # Remove bad version
   "$SPARKLE_BIN/generate_appcast" .
   git add appcast.xml
   git commit -m "chore: rollback to 2.3.9"
   git push
   ```

2. **Long-term**: Fix bug and release 2.4.1

## Appendix: Manual Appcast Generation
If the release script fails, generate appcast manually:

```bash
# 1. Ensure DMG is in dist/updates/
mkdir -p dist/updates
cp dist/AgentSessions-2.4.0.dmg dist/updates/

# 2. Find Sparkle tools
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)

# 3. Generate appcast
"$SPARKLE_BIN/generate_appcast" \
  --link "https://jazzyalex.github.io/agent-sessions/updates" \
  dist/updates/

# 4. Copy to docs/ (GitHub Pages)
cp dist/updates/appcast.xml docs/
cp dist/updates/*.dmg docs/updates/

# 5. Commit and push
git add docs/appcast.xml docs/updates/
git commit -m "chore(release): publish 2.4.0 appcast"
git push
```

## Quick Reference
| Command | Purpose |
|---------|---------|
| `generate_keys` | Create EdDSA key pair (one-time) |
| `generate_appcast` | Create/update appcast.xml |
| `security find-generic-password -l "Sparkle" -w` | Export private key (backup) |
| `defaults delete com.triada.AgentSessions SULastCheckTime` | Force update check |
| `curl -I https://jazzyalex.github.io/agent-sessions/appcast.xml` | Verify appcast published |

## Next Steps
- See `test-plan.md` for comprehensive testing procedures
- See `dev-hints.md` for local development tips
