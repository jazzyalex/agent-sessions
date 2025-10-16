# Swift Package Manager Setup for Sparkle 2

This guide walks through adding Sparkle 2 to the Agent Sessions project via Swift Package Manager (SPM) in Xcode.

## Prerequisites

- Xcode 14.0 or later
- macOS 12.0+ deployment target
- Agent Sessions project open in Xcode

## Step-by-Step Installation

### 1. Open Package Dependencies

1. In Xcode, open `AgentSessions.xcodeproj`
2. Select the project in the navigator (top-level "AgentSessions" item)
3. In the project editor, select the "Package Dependencies" tab
4. Click the **"+"** button at the bottom of the package list

### 2. Add Sparkle Repository

In the package search dialog:

1. **Search or Enter Package URL**:
   ```
   https://github.com/sparkle-project/Sparkle
   ```

2. **Dependency Rule**: Choose "Up to Next Major Version"
   - **Minimum**: `2.0.0`
   - This ensures you get bug fixes and minor updates but avoid breaking changes

3. Click **"Add Package"**

### 3. Select Products

Xcode will fetch the package and show available products:

1. **Select**: `Sparkle` (the main framework)
2. **Add to Target**: `AgentSessions`
3. Click **"Add Package"**

**Do NOT** add:
- `SparkleTestSupport` (only for unit tests)
- Platform-specific variants (Sparkle handles cross-platform automatically)

### 4. Verify Installation

After adding the package:

1. **Check Package Dependencies tab**:
   - You should see `Sparkle` listed with version `2.x.x`

2. **Check Target → Frameworks and Libraries**:
   - Select `AgentSessions` target → "Frameworks, Libraries, and Embedded Content"
   - `Sparkle` should appear as "Do Not Embed" (it's embedded automatically by SPM)

3. **Build the project**:
   ```bash
   xcodebuild -scheme AgentSessions -configuration Debug
   ```
   - This downloads Sparkle and makes CLI tools available

### 5. Locate Sparkle CLI Tools

After a successful build, find the `generate_appcast` and `generate_keys` tools:

```bash
find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" \
  2>/dev/null | head -n1
```

**Expected output**:
```
/Users/yourname/Library/Developer/Xcode/DerivedData/AgentSessions-.../SourcePackages/artifacts/sparkle-project/Sparkle/Sparkle/bin/generate_appcast
```

**Store path for convenience**:
```bash
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

echo "Sparkle tools: $SPARKLE_DIR"
ls "$SPARKLE_DIR"
```

**Available tools**:
- `generate_appcast` – Creates `appcast.xml` with EdDSA signatures
- `generate_keys` – Generates EdDSA key pair (one-time setup)
- `sign_update` – Manually signs DMGs (usually not needed; `generate_appcast` does this)
- `Sparkle.framework` – The framework itself

## Next Steps

### Generate EdDSA Keys (One-Time)

```bash
SPARKLE_DIR=$(dirname "$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)")

"$SPARKLE_DIR/generate_keys"
```

**Output**:
```
A key has been generated and saved in your Keychain (~/Library/Keychains/login.keychain-db).
Add the following public key to your Info.plist:

SUPublicEDKey: AbCdEf1234567890...XyZ==
```

**Copy this public key to `AgentSessions/Info.plist`**:
```xml
<key>SUPublicEDKey</key>
<string>AbCdEf1234567890...XyZ==</string>
```

### Verify Keychain Entry

```bash
security find-generic-password -l "Sparkle"
```

**Expected output**:
```
keychain: "/Users/yourname/Library/Keychains/login.keychain-db"
version: 512
class: "genp"
...
"svce"<blob>="Sparkle"
```

If this fails, re-run `generate_keys`.

### Configure Info.plist

See [`docs/updates/InfoPlist-snippet.xml`](InfoPlist-snippet.xml) for complete configuration.

### Implement UpdaterController

See [`AgentSessions/Update/UpdaterController.swift`](../../AgentSessions/Update/UpdaterController.swift) for the wrapper implementation.

## Troubleshooting

### Issue: Package not resolving

**Symptom**: Xcode shows "Package Resolution Failed" or spinner hangs

**Fix**:
1. Xcode → File → Packages → Reset Package Caches
2. Clean build folder: Cmd+Shift+K
3. Try adding package again

### Issue: Sparkle import fails in code

**Symptom**: `import Sparkle` shows "No such module 'Sparkle'"

**Fix**:
1. Verify Sparkle is added to the **AgentSessions target**, not just the project
2. Build the project once to download the package
3. Clean build folder and rebuild

### Issue: CLI tools not found after build

**Symptom**: `find` command returns nothing

**Fix**:
1. Ensure you've built the project at least once:
   ```bash
   xcodebuild -scheme AgentSessions -configuration Debug
   ```
2. Check DerivedData exists:
   ```bash
   ls ~/Library/Developer/Xcode/DerivedData
   ```
3. Search more broadly:
   ```bash
   find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" 2>/dev/null
   ```

### Issue: Xcode shows "Sparkle 1.x" instead of 2.x

**Symptom**: Package Dependencies shows version `1.27.x`

**Fix**:
1. Remove Sparkle from Package Dependencies
2. Re-add with URL: `https://github.com/sparkle-project/Sparkle`
3. Ensure "Up to Next Major Version" starts at `2.0.0`

### Issue: Multiple Sparkle packages appear

**Symptom**: Package search shows several results

**Fix**:
Use the **official repository**:
```
https://github.com/sparkle-project/Sparkle
```
(Watch for the verified GitHub organization: `sparkle-project`)

## Updating Sparkle

To update to a newer Sparkle 2.x version:

1. **Xcode → File → Packages → Update to Latest Package Versions**
2. Or update a specific package:
   - Right-click `Sparkle` in Package Dependencies
   - Select "Update Package"

**Safe to update**: Any 2.x.x version (semantic versioning guarantees)

**Breaking change**: 3.0.0+ (requires manual migration)

## Clean Removal (If Needed)

To remove Sparkle from the project:

1. **Remove from target**:
   - AgentSessions target → Frameworks and Libraries
   - Click "-" to remove Sparkle

2. **Remove from project**:
   - Package Dependencies tab
   - Select Sparkle
   - Click "-"

3. **Clean build**:
   ```bash
   xcodebuild clean
   rm -rf ~/Library/Developer/Xcode/DerivedData/AgentSessions-*
   ```

## References

- [Sparkle 2 Documentation](https://sparkle-project.org/documentation/)
- [Sparkle GitHub Repository](https://github.com/sparkle-project/Sparkle)
- [SPM Integration Guide](https://sparkle-project.org/documentation/package-manager-frameworks/)
- [EdDSA Signing Guide](https://sparkle-project.org/documentation/signing/)

## Quick Command Reference

```bash
# Find Sparkle tools
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

# Generate keys (one-time)
"$SPARKLE_DIR/generate_keys"

# Generate appcast
"$SPARKLE_DIR/generate_appcast" dist/updates/

# Verify appcast signatures
"$SPARKLE_DIR/generate_appcast" --verify dist/updates/

# Check Keychain for private key
security find-generic-password -l "Sparkle"
```
