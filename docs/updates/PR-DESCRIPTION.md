# Pull Request: Implement Sparkle 2 Automatic Updates

## Summary

This PR implements **Sparkle 2** automatic update framework for Agent Sessions, replacing the manual GitHub release checker with a fully automated, secure update system.

**Key benefits**:
- ✅ **Automatic background checks** every 24 hours
- ✅ **Non-intrusive "gentle reminders"** (no focus stealing for menu bar apps)
- ✅ **Triple-layer security**: EdDSA signatures + Developer ID codesign + Apple notarization
- ✅ **One-click updates** with progress UI and release notes
- ✅ **Integrated into existing release workflow** (DMG + Homebrew still supported)

## Changes

### 📄 Documentation (Spec-First Workflow)

#### Architecture Decision Record
- **`docs/adr/0002-adopt-sparkle-2.md`**
  - Documents decision to adopt Sparkle 2
  - Explains security model, UX requirements, rollback plan
  - Success metrics and monitoring strategy

#### Technical Specifications
- **`docs/updates/sparkle-spec.md`**
  - Complete technical specification
  - Architecture diagrams and flow charts
  - Info.plist configuration reference
  - Security verification chain
  - Failure modes and edge cases

#### Release Procedures
- **`docs/updates/release-cookbook.md`**
  - Step-by-step release guide
  - One-time setup instructions (EdDSA keys, SPM)
  - Per-release workflow with appcast generation
  - Integration with `deploy-agent-sessions.sh`
  - Troubleshooting common issues

#### Testing & Quality Assurance
- **`docs/updates/test-plan.md`**
  - 8 comprehensive test suites:
    - Installation & first launch
    - Scheduled background checks
    - Manual update checks
    - Update installation flow
    - Security verification (EdDSA, Developer ID, notarization)
    - Edge cases (404, malformed XML, permissions)
    - Gentle reminder UX
    - Rollback procedures

#### Developer Productivity
- **`docs/updates/dev-hints.md`**
  - Quick command reference
  - Force update check commands
  - View Sparkle logs in real-time
  - Reset Sparkle state for testing
  - Local appcast testing setup
  - Debugging cheat sheet

#### Setup Guides
- **`docs/updates/spm-setup.md`**
  - Swift Package Manager integration guide
  - Step-by-step Xcode configuration
  - EdDSA key generation and management
  - Sparkle CLI tools location
  - Troubleshooting SPM issues

- **`docs/updates/InfoPlist-snippet.xml`**
  - Copy-paste template for Info.plist configuration

### 🔧 Code Implementation

#### Core Update Controller
- **`AgentSessions/Update/UpdaterController.swift`** (NEW)
  - Wraps `SPUStandardUpdaterController` with SwiftUI integration
  - Implements `SPUUpdaterDelegate` for lifecycle hooks
  - Implements `SPUStandardUserDriverDelegate` for gentle reminders
  - Published `@Published var hasGentleReminder: Bool` state
  - Gentle reminder logic: only show UI when app in focus
  - Comprehensive inline documentation

**Key implementation**:
```swift
@MainActor
final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published var hasGentleReminder: Bool = false
    private let controller: SPUStandardUpdaterController

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        return immediateFocus  // Only show Sparkle UI if app in focus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            hasGentleReminder = true  // Show subtle indicator
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
```

#### App Integration
- **`AgentSessions/AgentSessionsApp.swift`** (MODIFIED)
  - **Removed**:
    - `@StateObject private var updateModel = UpdateCheckModel.shared`
    - `@State private var showUpdateAlert: Bool`
    - `@State private var updateAlertData`
    - Manual update check on app launch
    - Custom "Update Available" alert dialog
  - **Added**:
    - `@StateObject private var updaterController = UpdaterController()`
  - **Changed menu command**:
    - Before: `Button("Check for Updates…") { updateModel.checkManually() }`
    - After: `Button("Check for Updates…", action: updaterController.checkForUpdates)`

#### Configuration
- **`AgentSessions/Info.plist`** (MODIFIED)
  - Added Sparkle 2 configuration keys:
    ```xml
    <!-- Sparkle 2 Update Configuration -->
    <key>SUFeedURL</key>
    <string>https://jazzyalex.github.io/agent-sessions/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY_FROM_generate_keys</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUShowReleaseNotes</key>
    <true/>
    ```

### 🚀 Release Automation

#### Updated Deployment Script
- **`tools/release/deploy-agent-sessions.sh`** (MODIFIED)
  - **Added appcast generation step** (after DMG build, before GitHub release):
    1. Create `dist/updates/` directory
    2. Copy DMG to updates directory
    3. Auto-detect Sparkle CLI tools from SPM artifacts
    4. Run `generate_appcast` with EdDSA signing
    5. Copy `appcast.xml` to `docs/` for GitHub Pages
    6. Commit and push appcast to publish
  - **Graceful fallback**: Warns if Sparkle tools not found (no failure)
  - **Added post-deployment reminders**:
    - Verify appcast accessibility
    - Check sparkle:version and edSignature
    - Test Sparkle auto-update flow

**Script integration**:
```bash
green "==> Generating Sparkle appcast"
UPDATES_DIR="$REPO_ROOT/dist/updates"
mkdir -p "$UPDATES_DIR"
cp "$DMG" "$UPDATES_DIR/"

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)

if [[ -n "$SPARKLE_BIN" ]]; then
    "$SPARKLE_BIN" "$UPDATES_DIR"
    cp "$UPDATES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"
    git add "$REPO_ROOT/docs/appcast.xml"
    git commit -m "chore(release): update appcast for ${VERSION}"
    git push origin HEAD:main
fi
```

### 📖 Documentation Updates

#### README
- **`README.md`** (MODIFIED)
  - Added **"Automatic Updates"** subsection under Install
  - Explains Sparkle 2 features:
    - 24-hour background checks
    - Non-intrusive notifications
    - EdDSA + notarization security
    - Manual check commands
  - Notes first Sparkle-enabled release requires manual download

## Security Model

### Three-Layer Verification

1. **EdDSA (ed25519) Signatures**
   - Each DMG signed cryptographically during appcast generation
   - Public key in `Info.plist` (`SUPublicEDKey`)
   - Private key stored securely in macOS Keychain (item: "Sparkle")
   - Sparkle verifies signature before download

2. **Developer ID Code Signing**
   - DMG signed with Apple Developer ID certificate
   - Verified by macOS Gatekeeper

3. **Apple Notarization**
   - DMG scanned by Apple for malware
   - Stapled notarization ticket attached
   - Verified by macOS on first launch

**Attack resistance**:
- ❌ Man-in-the-middle: Blocked by EdDSA signature (even if HTTPS compromised)
- ❌ Appcast tampering: Blocked by EdDSA signature
- ❌ Malicious DMG: Blocked by Developer ID codesign + notarization
- ❌ Downgrade attacks: Blocked by semantic version comparison

## UX & Behavior

### Gentle Reminders (Menu Bar App Pattern)

**Problem**: Traditional update dialogs steal focus and interrupt workflow

**Solution**: Sparkle 2 "Gentle Update Reminders"
- When app is **in focus**: Shows standard Sparkle alert immediately
- When app is **in background**: Sets `hasGentleReminder = true`, no UI interruption
- User can implement subtle indicator (badge, menu bar dot) based on `hasGentleReminder`

**Implementation**:
```swift
var supportsGentleScheduledUpdateReminders: Bool { true }

func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
) -> Bool {
    return immediateFocus  // Only show UI if app in focus
}
```

### Update Flow

1. **Scheduled check** (every 24 hours):
   - Fetches `https://jazzyalex.github.io/agent-sessions/appcast.xml`
   - Compares version: `<sparkle:version>2.4.0</sparkle:version>` vs current
   - Verifies EdDSA signature in `<sparkle:edSignature>`

2. **If update available**:
   - **App in focus**: Shows alert: "Agent Sessions 2.4.0 is available"
   - **App in background**: Sets `hasGentleReminder = true` (no alert)

3. **User clicks "Install"**:
   - Downloads DMG from `<enclosure url>`
   - Verifies EdDSA signature
   - Verifies Developer ID codesign
   - Verifies notarization
   - Quits app, installs update, relaunches

4. **User clicks "Skip This Version"**:
   - Writes `SUSkippedVersion` to UserDefaults
   - Won't prompt again for this version

## Testing Strategy

### Pre-Merge Testing

- [ ] **Unit Tests** (if applicable):
  - UpdaterController initialization
  - Delegate method behavior

- [ ] **Manual Testing** (before merge):
  - [ ] Add Sparkle via SPM (verify build succeeds)
  - [ ] Generate EdDSA keys (verify Keychain storage)
  - [ ] Update `Info.plist` with public key
  - [ ] Build app (verify no errors)
  - [ ] Test local appcast (file:// URL)
  - [ ] Verify gentle reminder logic (background check)

### Post-Merge Testing (First Release)

- [ ] **Test on Clean macOS VM**:
  - [ ] Install Agent Sessions 2.3.2 (pre-Sparkle)
  - [ ] Upgrade to 2.4.0 (first Sparkle release) manually
  - [ ] Verify subsequent auto-updates work (2.4.1+)

- [ ] **Security Verification**:
  - [ ] Verify EdDSA signature on appcast.xml
  - [ ] Verify Developer ID signature on DMG
  - [ ] Verify notarization ticket
  - [ ] Test update with invalid signature (should fail)

- [ ] **UX Testing**:
  - [ ] Launch app in foreground, trigger manual check
  - [ ] Launch app in background, wait 24h or force check
  - [ ] Verify `hasGentleReminder` state (no alert shown)

See **`docs/updates/test-plan.md`** for complete test procedures.

## Migration Path

### Existing Users (Pre-2.4.0)

**First Sparkle-enabled release (e.g., 2.4.0)**:
- Users must **manually download** 2.4.0 DMG (or use Homebrew)
- Old `UpdateCheckModel` will show "Update Available" alert (one last time)
- After installing 2.4.0, Sparkle takes over

**Subsequent releases (2.4.1+)**:
- Fully automatic via Sparkle
- In-app alerts with "Install" button
- One-click updates with progress UI

### Rollback Plan (If Needed)

If Sparkle causes critical issues:

1. **Revert commits** (this PR)
2. **Remove Sparkle from SPM** dependencies
3. **Restore `UpdateCheckModel`** (git history)
4. **Rebuild and release** emergency version

**Data loss**: None (Sparkle only writes to UserDefaults, no schema changes)

## Dependencies

### Swift Package Manager

- **Package**: Sparkle 2
  - **URL**: https://github.com/sparkle-project/Sparkle
  - **Version**: 2.x.x (latest)
  - **Platform**: macOS 12.0+

**Installation** (see `docs/updates/spm-setup.md`):
1. Xcode → Project → Package Dependencies
2. Add package: `https://github.com/sparkle-project/Sparkle`
3. Select `Sparkle` product for `AgentSessions` target
4. Build to download Sparkle and CLI tools

### Keychain (EdDSA Private Key)

**Setup** (one-time):
```bash
# Find Sparkle tools
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

# Generate keys
"$SPARKLE_DIR/generate_keys"

# Copy public key to Info.plist
# Private key stored in Keychain (item: "Sparkle")
```

**Backup**:
```bash
security find-generic-password -l "Sparkle" -w > ~/Desktop/sparkle-key-backup.txt
# Store in 1Password or secure vault
```

## Deployment Checklist

### One-Time Setup (Before First Release)

- [ ] Add Sparkle 2 via SPM in Xcode
- [ ] Build project to download Sparkle CLI tools
- [ ] Generate EdDSA keys: `generate_keys`
- [ ] Copy public key to `AgentSessions/Info.plist` (`SUPublicEDKey`)
- [ ] Backup private key from Keychain to secure vault
- [ ] Verify Keychain entry: `security find-generic-password -l "Sparkle"`
- [ ] Test appcast generation locally with file:// URL

### Per-Release Workflow

The updated `deploy-agent-sessions.sh` script automates this:

1. **Build, sign, notarize DMG** (existing workflow)
2. **Generate appcast** (new step):
   - Copy DMG to `dist/updates/`
   - Run `generate_appcast dist/updates/`
   - Copy `appcast.xml` to `docs/`
   - Commit and push to GitHub Pages
3. **Create GitHub release** (existing workflow)
4. **Update Homebrew cask** (existing workflow)

**Verification** (post-deployment):
```bash
# Check appcast is live
curl https://jazzyalex.github.io/agent-sessions/appcast.xml

# Verify EdDSA signature
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" -path "*/artifacts/*/Sparkle/bin/*" 2>/dev/null | head -n1)
"$SPARKLE_BIN" --verify dist/updates/

# Test manual update check
defaults delete com.triada.AgentSessions SULastCheckTime
open "/Applications/Agent Sessions.app"
```

## Backward Compatibility

### No Breaking Changes

- ✅ Existing DMG download workflow unchanged
- ✅ Homebrew cask installation unchanged
- ✅ No schema changes (Sparkle uses UserDefaults)
- ✅ Graceful fallback if Sparkle not configured

### User Impact

**Before this PR**:
- Manual GitHub release checker (`UpdateCheckModel`)
- Alert with GitHub release URL
- User clicks "Download" → opens browser → downloads DMG → installs manually

**After this PR**:
- Automatic Sparkle 2 updates
- Alert with "Install" button
- User clicks "Install" → downloads, verifies, installs, relaunches automatically

## Future Enhancements

**Delta Updates** (Not in this PR):
- Sparkle supports binary diff updates
- Reduces download size (e.g., 20 MB → 5 MB)
- Requires keeping previous DMGs in `dist/updates/`

**Custom UI** (Not in this PR):
- Replace default Sparkle alert with custom SwiftUI sheet
- Use `hasGentleReminder` to show in-app banner
- Requires additional SPU delegate customization

**Staged Rollouts** (Not in this PR):
- Phased rollout via appcast channel filtering
- Beta channel for early adopters
- Requires multiple appcast URLs

## References

- [Sparkle 2 Documentation](https://sparkle-project.org/documentation/)
- [EdDSA Signing Guide](https://sparkle-project.org/documentation/signing/)
- [Gentle Update Reminders](https://sparkle-project.org/documentation/gentle-reminders/)
- [SPM Integration](https://sparkle-project.org/documentation/package-manager-frameworks/)

## Checklist Before Merge

- [ ] All documentation created (ADR, spec, cookbook, test plan, dev hints, SPM setup)
- [ ] `UpdaterController.swift` implemented with gentle reminders
- [ ] `AgentSessionsApp.swift` updated (removed UpdateCheckModel)
- [ ] `Info.plist` configured (SUFeedURL, SUPublicEDKey placeholder)
- [ ] `deploy-agent-sessions.sh` updated with appcast generation
- [ ] `README.md` updated with automatic updates section
- [ ] Code review passed
- [ ] Manual testing completed (see test plan)
- [ ] EdDSA keys generated and backed up (pre-deployment)

---

**This PR follows the SDSD (Specification-Driven Software Development) principle**: All documentation was written BEFORE code implementation, ensuring comprehensive planning and clear requirements.
