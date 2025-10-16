# Developer Hints for Sparkle Testing

## Quick Commands

### Force Immediate Update Check
```bash
# Reset last check time
defaults delete com.triada.AgentSessions SULastCheckTime

# Launch app
open "/Applications/Agent Sessions.app"
# or
open ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Agent\ Sessions.app
```

### View Sparkle Logs in Real-Time
```bash
# Open Console.app or use command line:
log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"' --level debug

# Include app logs too:
log stream --predicate 'subsystem CONTAINS "sparkle" OR subsystem CONTAINS "AgentSessions"' --level debug
```

### Check Sparkle State
```bash
# View all Sparkle preferences
defaults read com.triada.AgentSessions | grep -i "^SU"

# Specific keys:
defaults read com.triada.AgentSessions SULastCheckTime
defaults read com.triada.AgentSessions SUHasLaunchedBefore
defaults read com.triada.AgentSessions SUSkippedVersion
```

### Reset Sparkle Completely
```bash
# Nuclear option: clear all Sparkle state
defaults delete com.triada.AgentSessions SULastCheckTime
defaults delete com.triada.AgentSessions SUHasLaunchedBefore
defaults delete com.triada.AgentSessions SUSkippedVersion
defaults delete com.triada.AgentSessions SUEnableAutomaticChecks
defaults delete com.triada.AgentSessions SUAutomaticallyUpdate

# Now app thinks it's first launch
```

## Local Testing with Staging Appcast

### Create Test Appcast
```bash
# Build a test version
xcodebuild -scheme AgentSessions -configuration Debug

# Create DMG manually
mkdir -p /tmp/test-updates
cp -R ~/Library/Developer/Xcode/DerivedData/.../Debug/Agent\ Sessions.app /tmp/test-updates/

# Generate appcast
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" | head -n1)
"$SPARKLE_BIN" --link "file:///tmp/test-updates" /tmp/test-updates/
```

### Point to Local Appcast
Edit `Info.plist` temporarily:
```xml
<key>SUFeedURL</key>
<string>file:///tmp/test-updates/appcast.xml</string>
```

**Note**: Remember to revert before committing!

## Debugging Common Issues

### Issue: "Update not offered"
**Check**:
1. Is appcast version > current version?
   ```bash
   # Current version
   /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
     "/Applications/Agent Sessions.app/Contents/Info.plist"

   # Appcast version
   curl https://jazzyalex.github.io/agent-sessions/appcast.xml | grep sparkle:version
   ```

2. Is `SULastCheckTime` blocking?
   ```bash
   defaults delete com.triada.AgentSessions SULastCheckTime
   ```

3. Did user skip this version?
   ```bash
   defaults read com.triada.AgentSessions SUSkippedVersion
   # If matches current appcast version, user clicked "Skip"
   defaults delete com.triada.AgentSessions SUSkippedVersion
   ```

### Issue: "Signature verification failed"
**Check**:
```bash
# 1. Verify appcast was generated with correct private key
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" | head -n1)
"$SPARKLE_BIN" --verify dist/updates/

# 2. Check Keychain has private key
security find-generic-password -l "Sparkle"

# 3. Verify public key in Info.plist matches
/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" \
  "/Applications/Agent Sessions.app/Contents/Info.plist"
```

### Issue: "App doesn't see Sparkle framework"
**Check**:
1. Sparkle added via SPM?
   - Xcode → Project → Package Dependencies

2. Sparkle linked to target?
   - Xcode → AgentSessions target → Frameworks and Libraries

3. Clean build:
   ```bash
   xcodebuild -scheme AgentSessions clean
   rm -rf ~/Library/Developer/Xcode/DerivedData
   xcodebuild -scheme AgentSessions -configuration Debug
   ```

## Testing Gentle Reminders

### Simulate Background Check
```bash
# 1. Launch app and minimize (don't focus it)
open "/Applications/Agent Sessions.app"

# 2. Wait a moment for app to start
sleep 5

# 3. Force check while app is in background
defaults delete com.triada.AgentSessions SULastCheckTime

# 4. Watch logs
log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"' --level debug

# Expected: Logs show check, but NO alert dialog appears
# App should set hasGentleReminder = true
```

### Verify Gentle Reminder State
In `UpdaterController.swift`, add temporary logging:
```swift
func standardUserDriverWillHandleShowingUpdate(...) {
    if !handleShowingUpdate {
        print("⚠️ Gentle reminder activated")
        hasGentleReminder = true
    }
}
```

## Appcast Verification

### Validate Appcast Structure
```bash
# Fetch and pretty-print
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | xmllint --format -

# Check required elements
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | \
  grep -E "(sparkle:version|sparkle:edSignature|enclosure url)"
```

### Test Appcast Accessibility
```bash
# Check HTTPS
curl -I https://jazzyalex.github.io/agent-sessions/appcast.xml
# Should return: HTTP/2 200

# Check CORS (if serving from different domain)
curl -H "Origin: https://example.com" -I \
  https://jazzyalex.github.io/agent-sessions/appcast.xml
```

## Sparkle Tools Location

### Find After Build
```bash
# Sparkle tools are in DerivedData SPM artifacts
find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" \
  2>/dev/null | head -n1

# Store in variable
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

# Available tools:
ls "$SPARKLE_DIR"
# generate_appcast
# generate_keys
# sign_update
# Sparkle.framework
```

### Quick Access
Add to `~/.zshrc`:
```bash
alias sparkle-tools='find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1 | xargs dirname'
```

Usage:
```bash
SPARKLE="$(sparkle-tools)"
"$SPARKLE/generate_appcast" dist/updates/
```

## Simulating Network Failures

### Block appcast domain
```bash
# Add to /etc/hosts (requires sudo)
sudo echo "127.0.0.1 jazzyalex.github.io" >> /etc/hosts

# Test update check (should fail)
# ...

# Remove block
sudo sed -i '' '/jazzyalex.github.io/d' /etc/hosts
```

### Use Charles Proxy
1. Install Charles Proxy
2. Map `jazzyalex.github.io` to localhost
3. Serve custom appcast for testing

## EdDSA Key Management

### Export Private Key (for backup)
```bash
# Export from Keychain
security find-generic-password -l "Sparkle" -w > ~/Desktop/sparkle-key-backup.txt

# Verify it's not empty
cat ~/Desktop/sparkle-key-backup.txt
# Should show: long base64 string

# IMPORTANT: Store securely (1Password) and delete from Desktop
```

### Import Private Key (restore from backup)
```bash
# If you lost the key and need to restore
security add-generic-password \
  -a "YourName" \
  -s "Sparkle" \
  -w "PASTE_PRIVATE_KEY_HERE"
```

### Generate New Keys (if lost)
```bash
# WARNING: This breaks updates for existing users!
SPARKLE_BIN=$(sparkle-tools)
"$SPARKLE_BIN/generate_keys"

# Copy new public key to Info.plist
# Ship new version (users must manually download)
```

## Performance Testing

### Measure Update Check Time
```bash
time defaults delete com.triada.AgentSessions SULastCheckTime && \
  open "/Applications/Agent Sessions.app" && \
  sleep 5 && \
  log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' --last 30s | \
  grep "check"
```

### Monitor Network Usage
```bash
# Use Activity Monitor → Network tab
# Or command line:
nettop -P -J bytes_in,bytes_out -l 3 | grep "Agent Sessions"
```

## Automated Testing Ideas

### Shell Script for Regression Tests
```bash
#!/bin/bash
# test-sparkle.sh

set -e

echo "1. Reset Sparkle state..."
defaults delete com.triada.AgentSessions SULastCheckTime 2>/dev/null || true

echo "2. Launch app..."
open "/Applications/Agent Sessions.app"
sleep 5

echo "3. Check logs for Sparkle activity..."
if log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' --last 10s | grep -q "Checking for updates"; then
  echo "✅ Sparkle is active"
else
  echo "❌ Sparkle not checking"
  exit 1
fi

echo "4. Verify appcast accessible..."
if curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml > /dev/null; then
  echo "✅ Appcast reachable"
else
  echo "❌ Appcast 404 or network error"
  exit 1
fi

echo "All checks passed!"
```

## Quick Reference

| Command | Purpose |
|---------|---------|
| `defaults delete com.triada.AgentSessions SULastCheckTime` | Force immediate check |
| `log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"'` | Watch Sparkle logs |
| `defaults read com.triada.AgentSessions \| grep SU` | View all Sparkle prefs |
| `sparkle-tools` (after alias) | Find Sparkle CLI tools |
| `generate_appcast dist/updates/` | Create appcast from DMGs |
| `generate_appcast --verify dist/updates/` | Verify EdDSA signatures |
| `curl -I https://jazzyalex.github.io/agent-sessions/appcast.xml` | Test appcast availability |

## Troubleshooting Cheat Sheet

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| No update check | `SULastCheckTime` not expired | `defaults delete com.triada.AgentSessions SULastCheckTime` |
| "Signature failed" | Wrong private key or corrupted appcast | Regenerate appcast with `generate_appcast` |
| "Update found" but no UI | App in background, gentle reminder active | Focus app or check `hasGentleReminder` state |
| App crashes on launch | Sparkle not linked | Check SPM dependencies, clean build |
| Appcast 404 | GitHub Pages not updated | Push `docs/appcast.xml` to repo |
| Version comparison wrong | Semantic versioning issue | Ensure version format: `X.Y.Z` (no `v` prefix) |

## Tips
- Always test with `defaults delete SULastCheckTime` before manually checking
- Keep Console.app open filtered to "Sparkle" during testing
- Use local file:// appcast for rapid iteration
- Test on clean macOS VM for fresh user experience
- Backup private key before any key operations!
