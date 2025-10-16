# Sparkle Integration Test Plan

## Document Purpose
Comprehensive testing procedures for verifying Sparkle 2 update functionality in Agent Sessions.

## Test Environment Setup
- **macOS Version**: Test on macOS 13 (Ventura) and 14 (Sonoma) minimum
- **Architecture**: Test on both Intel and Apple Silicon
- **Clean State**: Use fresh user account or reset Sparkle defaults before each test suite

## Pre-Test Setup

### Reset Sparkle State
```bash
# Clear all Sparkle preferences
defaults delete com.triada.AgentSessions SULastCheckTime
defaults delete com.triada.AgentSessions SUHasLaunchedBefore
defaults delete com.triada.AgentSessions SUSkippedVersion

# Verify reset
defaults read com.triada.AgentSessions | grep -i "^SU"
# Should return empty
```

### Enable Sparkle Logging
```bash
# View Sparkle logs in real-time
log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"' --level debug
```

## Test Suite 1: Installation & First Launch

### Test 1.1: Fresh Install
**Precondition**: App never launched before

**Steps**:
1. Install Agent Sessions.app (manually, not via Sparkle)
2. Launch app
3. Observe first launch behavior

**Expected**:
- ✅ App launches without errors
- ✅ No Sparkle opt-in dialog (due to `SUEnableAutomaticChecks=true`)
- ✅ Sparkle schedules first check (verify in logs)
- ✅ No immediate update check (respects `SUScheduledCheckInterval`)

### Test 1.2: Info.plist Verification
**Steps**:
```bash
# Check Info.plist contains Sparkle keys
/usr/libexec/PlistBuddy -c "Print SUFeedURL" \
  "/Applications/Agent Sessions.app/Contents/Info.plist"
# Should print: https://jazzyalex.github.io/agent-sessions/appcast.xml

/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" \
  "/Applications/Agent Sessions.app/Contents/Info.plist"
# Should print: base64 public key
```

**Expected**:
- ✅ All Sparkle keys present and correct
- ✅ Feed URL is HTTPS
- ✅ Public key is valid base64

## Test Suite 2: Scheduled Background Checks

### Test 2.1: Force Scheduled Check (Update Available)
**Precondition**: Update available on appcast

**Steps**:
1. Launch app (normal state)
2. Let app run in background
3. Force scheduled check:
   ```bash
   defaults delete com.triada.AgentSessions SULastCheckTime
   ```
4. Wait 10 seconds (Sparkle checks immediately after reset)

**Expected (App in Background)**:
- ✅ Sparkle checks appcast (verify in logs)
- ✅ Update detected (verify in logs)
- ✅ `UpdaterController.hasGentleReminder = true`
- ✅ **No alert dialog** (gentle reminder)
- ✅ Optional: Badge/indicator on menu bar

**Expected (App Brought to Focus)**:
- ✅ Sparkle shows standard update alert
- ✅ Alert contains: "Install Update", "Remind Me Later", "Skip This Version"
- ✅ `UpdaterController.hasGentleReminder = false`

### Test 2.2: Force Scheduled Check (Up to Date)
**Precondition**: No update available (appcast version ≤ current version)

**Steps**:
1. Force check (as above)
2. Observe behavior

**Expected**:
- ✅ Sparkle checks appcast
- ✅ No update detected (logs: "Already up to date")
- ✅ No UI shown (silent)
- ✅ `hasGentleReminder` remains false

### Test 2.3: 24-Hour Cadence
**Precondition**: Fresh install

**Steps**:
1. Launch app
2. Check `SULastCheckTime`:
   ```bash
   defaults read com.triada.AgentSessions SULastCheckTime
   ```
3. Wait 24 hours (or mock time by deleting key)
4. Verify next scheduled check

**Expected**:
- ✅ First check scheduled at launch + `SUScheduledCheckInterval` (86400 sec)
- ✅ Subsequent checks every 24 hours
- ✅ Check does not block app launch or UI

## Test Suite 3: Manual Checks

### Test 3.1: Manual Check (Update Available)
**Steps**:
1. Launch app
2. Click "Check for Updates…" in app menu
3. Observe dialog

**Expected**:
- ✅ Sparkle immediately checks appcast (ignores 24h cadence)
- ✅ Update alert appears **regardless of app focus** (not gentle)
- ✅ Alert shows version number, release notes link, install button

### Test 3.2: Manual Check (Up to Date)
**Steps**:
1. Launch app (already on latest version)
2. Click "Check for Updates…"

**Expected**:
- ✅ NSAlert appears: "You're up to date"
- ✅ Informative text: "You have the latest version installed."
- ✅ OK button dismisses alert

### Test 3.3: Manual Check (Network Error)
**Precondition**: Disconnect network or use invalid appcast URL

**Steps**:
1. Disconnect WiFi
2. Click "Check for Updates…"

**Expected**:
- ✅ NSAlert appears with network error message
- ✅ App remains functional (no crash)
- ✅ Logs show connection failure

## Test Suite 4: Update Installation

### Test 4.1: Full Update (No Delta)
**Precondition**: First Sparkle update (no delta available)

**Steps**:
1. Trigger update (manual or scheduled)
2. Click "Install Update" in Sparkle alert
3. Observe download progress
4. Wait for installation

**Expected**:
- ✅ Progress bar shows download (full DMG size)
- ✅ "Extracting update…" message appears
- ✅ App quits and relaunches automatically
- ✅ New version launches successfully
- ✅ All user data intact (Preferences, sessions)
- ✅ No Gatekeeper warnings (DMG is notarized)

### Test 4.2: Delta Update
**Precondition**: Appcast contains delta patch for current → new version

**Steps**:
1. Trigger update
2. Install update

**Expected**:
- ✅ Progress bar shows smaller download size (delta, not full DMG)
- ✅ Logs show: "Downloading delta update"
- ✅ Installation completes successfully
- ✅ New version launches

### Test 4.3: Install Interruption (Network Loss)
**Steps**:
1. Start update installation
2. During download, disconnect network
3. Wait 30 seconds
4. Reconnect network

**Expected**:
- ✅ Sparkle pauses download (shows "Retrying…")
- ✅ After reconnect, download resumes
- ✅ Installation completes successfully

### Test 4.4: Skip This Version
**Steps**:
1. Trigger update
2. Click "Skip This Version" in alert
3. Force another check

**Expected**:
- ✅ Update dialog does not reappear for this version
- ✅ Sparkle logs: "Skipping version X.Y.Z"
- ✅ Next version will trigger alert

### Test 4.5: Remind Me Later
**Steps**:
1. Trigger update
2. Click "Remind Me Later"
3. Launch app tomorrow (or force check after 24h)

**Expected**:
- ✅ Update alert reappears
- ✅ User can install or skip

## Test Suite 5: Security Verification

### Test 5.1: Valid EdDSA Signature
**Precondition**: Appcast generated with correct private key

**Steps**:
1. Check for updates
2. Observe installation

**Expected**:
- ✅ Update installs successfully
- ✅ No signature warnings in logs

### Test 5.2: Invalid EdDSA Signature
**Precondition**: Manually edit appcast.xml and corrupt `edSignature` attribute

**Steps**:
1. Publish corrupted appcast
2. Check for updates

**Expected**:
- ✅ Sparkle detects signature mismatch
- ✅ Logs: "Update signature verification failed"
- ✅ Update is **rejected** (not installed)
- ✅ User sees error: "An error occurred while downloading the update"
- ✅ App stays on current version

### Test 5.3: Developer ID Verification
**Precondition**: Sign DMG with different Developer ID certificate

**Steps**:
1. Create DMG signed with wrong cert
2. Generate appcast (will have valid EdDSA but wrong codesign)
3. Check for updates

**Expected**:
- ✅ Sparkle detects codesign mismatch
- ✅ Logs: "Update certificate does not match"
- ✅ Update is rejected
- ✅ User sees error alert

### Test 5.4: Notarization Check
**Precondition**: DMG is not notarized

**Steps**:
1. Create DMG, sign but don't notarize
2. Check for updates and install

**Expected**:
- ✅ Sparkle may allow download (EdDSA valid)
- ✅ macOS Gatekeeper blocks installation
- ✅ User sees: "Cannot open because developer cannot be verified"

**Note**: This is a macOS-level check, not Sparkle-specific.

## Test Suite 6: Edge Cases

### Test 6.1: Appcast 404
**Steps**:
1. Change `SUFeedURL` to non-existent URL
2. Check for updates

**Expected**:
- ✅ Logs: "HTTP 404 Not Found"
- ✅ No crash
- ✅ Manual check shows error: "Failed to check for updates"

### Test 6.2: Malformed Appcast XML
**Steps**:
1. Publish invalid XML to appcast URL
2. Check for updates

**Expected**:
- ✅ Logs: "Failed to parse appcast"
- ✅ No crash
- ✅ Error message shown

### Test 6.3: Downgrade Prevention
**Precondition**: Current version is 2.4.0, appcast offers 2.3.0

**Steps**:
1. Check for updates

**Expected**:
- ✅ Sparkle ignores older version
- ✅ Logs: "Ignoring downgrade"
- ✅ No update offered

### Test 6.4: Multiple Simultaneous Checks
**Steps**:
1. Click "Check for Updates…" rapidly 5 times
2. Observe behavior

**Expected**:
- ✅ Only one check runs (subsequent clicks ignored)
- ✅ No race conditions or crashes

### Test 6.5: Permissions Error
**Precondition**: Remove write permissions from `/Applications/Agent Sessions.app`

**Steps**:
```bash
sudo chmod -w "/Applications/Agent Sessions.app"
```
1. Attempt to install update

**Expected**:
- ✅ Sparkle detects permission error
- ✅ User sees: "Failed to install update. Check permissions."
- ✅ Logs show detailed error
- ✅ App rolls back to current version

**Cleanup**:
```bash
sudo chmod +w "/Applications/Agent Sessions.app"
```

## Test Suite 7: Upgrade Paths

### Test 7.1: Non-Sparkle to Sparkle
**Precondition**: User has version without Sparkle (e.g., 2.3.x)

**Steps**:
1. User manually downloads 2.4.0 (first Sparkle version)
2. Replace old app
3. Launch 2.4.0

**Expected**:
- ✅ Sparkle initializes on first launch
- ✅ Subsequent updates via Sparkle
- ✅ No errors during transition

### Test 7.2: Homebrew to Direct Install
**Precondition**: User installed via Homebrew cask

**Steps**:
1. User downloads DMG and installs to /Applications
2. Homebrew version still in /Applications (conflict)

**Expected**:
- ✅ User sees "App already exists" prompt
- ✅ User replaces Homebrew version
- ✅ Sparkle takes over updates

### Test 7.3: Cross-Architecture Update (Intel → Apple Silicon)
**Precondition**: Universal binary DMG

**Steps**:
1. Install Intel version on Apple Silicon Mac (Rosetta)
2. Check for updates to universal build
3. Install update

**Expected**:
- ✅ Update downloads and installs
- ✅ App now runs natively (no Rosetta)
- ✅ Activity Monitor shows "Apple" arch

## Test Suite 8: Rollback & Recovery

### Test 8.1: Rollback Drill
**Scenario**: Version 2.4.0 shipped with critical bug, need to rollback to 2.3.9

**Steps**:
1. Remove 2.4.0 DMG from `dist/updates/`
2. Re-run `generate_appcast` (includes only 2.3.9)
3. Publish new appcast
4. Users on 2.4.0 check for updates

**Expected**:
- ✅ Sparkle offers 2.3.9 as "update" (even though it's older)
- ✅ Users can install 2.3.9
- ✅ No signature errors

**Note**: Sparkle normally prevents downgrades. To allow, set `sparkle:version` to a higher build number.

### Test 8.2: Private Key Loss Recovery
**Scenario**: Private key lost, need to generate new key

**Steps**:
1. Generate new key pair
2. Update `SUPublicEDKey` in Info.plist
3. Ship new version with new public key

**Expected**:
- ❌ Users on old version **cannot** auto-update (signature mismatch)
- ✅ Users must manually download new version
- ✅ After manual update, Sparkle works again with new key

**Mitigation**: Always back up private key!

## Automated Testing (Optional)

### Unit Tests
Location: `AgentSessionsTests/UpdaterControllerTests.swift`

Tests:
- `testUpdaterInitializes()`: Controller inits without crash
- `testGentleReminderState()`: `hasGentleReminder` toggles correctly
- `testCheckForUpdatesAction()`: Menu action doesn't crash

### CI Integration
**GitHub Actions** (future):
```yaml
- name: Verify Info.plist Sparkle keys
  run: |
    /usr/libexec/PlistBuddy -c "Print SUFeedURL" \
      AgentSessions/Info.plist | grep "https://"
```

## Manual QA Checklist (Before Release)
Use this checklist before shipping:

- [ ] Force scheduled check (background) → gentle reminder works
- [ ] Manual check → immediate alert works
- [ ] Manual check (up to date) → shows "You're up to date"
- [ ] Install update → downloads, installs, relaunches successfully
- [ ] Skip version → doesn't reappear
- [ ] Remind later → reappears next check
- [ ] Invalid signature → rejected with error
- [ ] No network → graceful error, no crash
- [ ] Appcast accessible via HTTPS (curl test)
- [ ] DMG is notarized (no Gatekeeper warnings)
- [ ] Console logs show no Sparkle errors

## Troubleshooting Common Issues

### Issue: Update not detected
**Debug**:
```bash
# Check appcast XML manually
curl https://jazzyalex.github.io/agent-sessions/appcast.xml

# Verify version in appcast > current version
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
  "/Applications/Agent Sessions.app/Contents/Info.plist"
```

### Issue: Signature verification failed
**Debug**:
```bash
# Verify EdDSA signature with Sparkle tool
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
"$SPARKLE_BIN/generate_appcast" --verify dist/updates/
```

### Issue: App doesn't relaunch after update
**Debug**:
- Check Console.app for Sparkle/app logs
- Verify app bundle is not corrupted: `codesign --verify -vvv "/Applications/Agent Sessions.app"`
- Check permissions: `ls -la "/Applications/Agent Sessions.app"`

## Reporting Issues
When users report update problems, request:
1. Console logs filtered by "Sparkle" (last 1 hour)
2. Current app version: "About Agent Sessions"
3. macOS version
4. Network conditions (WiFi, VPN, firewall)

## Success Criteria
- ✅ All test suites pass with zero failures
- ✅ No crashes during update flow
- ✅ No Gatekeeper warnings
- ✅ Gentle reminders work (no focus stealing)
- ✅ Manual check works reliably
- ✅ Invalid signatures rejected

## Next Steps After Testing
1. Document any issues found
2. Fix bugs
3. Re-test
4. Ship to production
5. Monitor user feedback for 1 week

## References
- `sparkle-spec.md` for behavior requirements
- `release-cookbook.md` for appcast generation
- [Sparkle Debugging Guide](https://sparkle-project.org/documentation/debugging/)
