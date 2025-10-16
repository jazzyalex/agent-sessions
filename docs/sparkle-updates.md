# Sparkle 2 Automatic Updates Architecture

Agent Sessions uses Sparkle 2 framework for automatic updates with EdDSA signature verification.

## Update Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                     SPARKLE 2 UPDATE FLOW                           │
└─────────────────────────────────────────────────────────────────────┘

APP LAUNCH & CHECK
══════════════════
┌──────────────────┐
│ App starts (v1)  │
│ CFBundleVersion=1│
└────────┬─────────┘
         │
         ▼
┌────────────────────────────────────┐
│ UpdaterController.init()           │
│ - Read SUFeedURL from Info.plist  │
│ - Read SUPublicEDKey (if present) │
│ - Delay 1s, then start updater    │
│ - Schedule background check (5s)  │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Sparkle fetches appcast.xml        │
│ GET https://jazzyalex.github.io/   │
│     agent-sessions/appcast.xml     │
└────────┬───────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────┐
│ Parse appcast.xml                              │
│ - <sparkle:version>2.3.2</sparkle:version>     │
│ - <enclosure url="..." edSignature="..."      │
│             length="4206111" />                │
└────────┬───────────────────────────────────────┘
         │
         ▼
     ┌───────────────────────────┐
     │ Version comparison:        │
     │ Current: 1                 │
     │ Available: 2.3.2           │
     │ Result: Update available!  │
     └────────┬──────────────────┘
              │
              ▼
┌──────────────────────────────────────────────────┐
│ SIGNATURE VERIFICATION                           │
│ ┌──────────────────────────────────────────────┐ │
│ │ 1. Read SUPublicEDKey from Info.plist        │ │
│ │    Key: IxXWh+jLs25J3FiI4BDhurpau1yHNIK...  │ │
│ │                                              │ │
│ │ 2. Download DMG from enclosure URL           │ │
│ │    https://github.com/jazzyalex/...dmg      │ │
│ │                                              │ │
│ │ 3. Verify EdDSA signature:                   │ │
│ │    - DMG bytes → hash                        │ │
│ │    - Verify with public key + edSignature    │ │
│ │    - Expected: FfxeiAD96gO90IxoJyk7...       │ │
│ │                                              │ │
│ │ 4. Result: ✅ SIGNATURE VALID               │ │
│ │    (or ❌ MISMATCH if keys don't match)     │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────┬───────────────────────────────┘
                   │
                   ▼ (if valid)
          ┌────────────────────────┐
          │ Show update UI         │
          │ "Install Update"       │
          └────────┬───────────────┘
                   │
                   ▼
          ┌────────────────────────┐
          │ Download & Install     │
          │ Relaunch app           │
          └────────────────────────┘
```

## EdDSA Key Pair Management

**Public Key** (in `AgentSessions/Info.plist`):
```xml
<key>SUPublicEDKey</key>
<string>IxXWh+jLs25J3FiI4BDhurpau1yHNIK2z33NxJqR4Bc=</string>
```

**Private Key** (in macOS Keychain):
- Service name: `Sparkle`
- Account: (your Apple ID or user)
- Access: Developer tools only

## Release Signing Flow

```
RELEASE CREATION
════════════════
┌──────────────────────────────┐
│ Developer runs deploy script │
│ VERSION=2.3.2                │
└────────┬─────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ build_sign_notarize_release.sh     │
│ 1. xcodebuild Release              │
│ 2. codesign with Developer ID      │
│ 3. notarize with Apple             │
│ 4. staple ticket                   │
│ 5. create DMG                      │
└────────┬───────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────┐
│ deploy-agent-sessions.sh (line 131-133)      │
│ ┌──────────────────────────────────────────┐ │
│ │ SPARKLE_BIN/generate_appcast             │ │
│ │ "$UPDATES_DIR"                           │ │
│ │                                          │ │
│ │ What it does:                            │ │
│ │ 1. Find EdDSA private key in Keychain:   │ │
│ │    service: "Sparkle"                    │ │
│ │    ✅ FOUND                              │ │
│ │                                          │ │
│ │ 2. For each DMG in UPDATES_DIR:          │ │
│ │    - Calculate hash                      │ │
│ │    - Sign with private key → edSignature │ │
│ │    - Add to appcast.xml                  │ │
│ │                                          │ │
│ │ 3. Generate appcast.xml                  │ │
│ └──────────────────────────────────────────┘ │
└────────┬─────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────┐
│ Publish to GitHub Pages            │
│ docs/appcast.xml → gh-pages        │
│ https://jazzyalex.github.io/       │
│   agent-sessions/appcast.xml       │
└────────────────────────────────────┘
```

## Setting Up EdDSA Keys (First Time)

1. **Generate key pair**:
```bash
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

Output:
```
A private key has been stored in your Keychain called "Sparkle"
Public EdDSA key: IxXWh+jLs25J3FiI4BDhurpau1yHNIK2z33NxJqR4Bc=
```

2. **Add public key to Info.plist**:
```xml
<key>SUPublicEDKey</key>
<string>YOUR-PUBLIC-KEY-FROM-ABOVE</string>
```

3. **Backup private key** (CRITICAL!):
```bash
# Export from Keychain
security find-generic-password -s "Sparkle" -w > ~/sparkle-private-key.backup

# Store in secure vault (1Password, etc.)
# DO NOT commit to git!
```

## Signing Existing Releases

If you need to re-sign old releases with a new key:

```bash
# Download existing DMG
gh release download v2.3.2 --repo jazzyalex/agent-sessions -p "*.dmg"

# Sign with current private key (reads from Keychain)
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  AgentSessions-2.3.2.dmg

# Output: edSignature for appcast.xml
```

## Regenerating appcast.xml

```bash
# Put all DMGs in one directory
mkdir -p dist/updates
cp AgentSessions-*.dmg dist/updates/

# Generate appcast (signs all DMGs with private key from Keychain)
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  dist/updates/

# Copy to docs/ for GitHub Pages
cp dist/updates/appcast.xml docs/appcast.xml

# Commit and push
git add docs/appcast.xml
git commit -m "chore(updates): regenerate appcast with new signatures"
git push
```

## Troubleshooting Updates

### "The update is improperly signed and could not be validated"

**Root causes:**
1. **Key mismatch**: The `SUPublicEDKey` in Info.plist doesn't match the private key used to sign the DMG
2. **Missing private key**: No "Sparkle" entry in Keychain
3. **Corrupted DMG**: File was modified after signing

**Solution:**
```bash
# 1. Check if private key exists
security find-generic-password -s "Sparkle"

# 2. If not found, generate new key pair (see "Setting Up EdDSA Keys")

# 3. Re-sign ALL releases with new key

# 4. Regenerate appcast.xml

# 5. Update Info.plist with new public key
```

### Testing signature verification

```bash
# Verify a DMG signature manually
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  --verify \
  --ed-public-key "IxXWh+jLs25J3FiI4BDhurpau1yHNIK2z33NxJqR4Bc=" \
  --ed-signature "FfxeiAD96gO90IxoJyk7sgycmYTxYvV8b3xXrAUlLh3mfGtr4tcN+8YgB/l2iN0OBmCD8XTUy1VlkGmdXiJ7Bw==" \
  AgentSessions-2.3.2.dmg
```

## Info.plist Configuration

```xml
<!-- Sparkle 2 Update Configuration -->
<key>SUFeedURL</key>
<string>https://jazzyalex.github.io/agent-sessions/appcast.xml</string>

<!-- Public key for signature verification -->
<key>SUPublicEDKey</key>
<string>IxXWh+jLs25J3FiI4BDhurpau1yHNIK2z33NxJqR4Bc=</string>

<!-- Check daily -->
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>

<!-- Don't install automatically (show UI) -->
<key>SUAutomaticallyUpdate</key>
<false/>

<!-- Show release notes -->
<key>SUShowReleaseNotes</key>
<true/>
```

## Security Notes

1. **Never commit private key to git** - Store only in Keychain and secure backup
2. **Public key is safe to commit** - It's in Info.plist and distributed with app
3. **EdDSA > DSA** - Sparkle 2 uses modern EdDSA (Ed25519), not legacy DSA
4. **Key rotation**: If private key is compromised, generate new pair and re-sign ALL releases
5. **Signature verification is mandatory** - Never disable `SUPublicEDKey` in production

## Testing Update Flow

1. Build Debug version (version 1):
```bash
xcodebuild -scheme AgentSessions -configuration Debug
```

2. Launch and check for updates:
- App should detect version 2.3.2 is available
- Click "Check for Updates..." in menu or Preferences
- Should show native update UI (no "Sparkle" branding)

3. Verify signature validation works:
- If keys match: Update proceeds
- If keys mismatch: Error dialog appears

## Implementation Files

- `AgentSessions/Update/UpdaterController.swift` - Sparkle 2 wrapper with gentle reminders
- `AgentSessions/Info.plist` - Sparkle configuration
- `docs/appcast.xml` - Update feed (published to GitHub Pages)
- `tools/release/deploy-agent-sessions.sh` - Automated release + appcast generation

## Current Issue (To Be Fixed)

**Problem**: Signature verification fails with "improperly signed" error

**Root Cause**: The EdDSA public key in Info.plist (`IxXWh+jLs25J3FiI4BDhurpau1yHNIK2z33NxJqR4Bc=`) doesn't match the private key that was used to sign the releases in appcast.xml. The matching private key is not in Keychain.

**Solution**:
1. Generate new EdDSA key pair
2. Update Info.plist with new public key
3. Re-sign all releases with new private key
4. Regenerate appcast.xml with new signatures
5. Backup private key securely
