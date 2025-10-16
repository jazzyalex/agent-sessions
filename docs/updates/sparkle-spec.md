# Sparkle 2 Integration Specification

## Document Purpose
This specification defines the technical requirements, configuration, and behavior of Sparkle 2 integration in Agent Sessions.

## Goals
1. **Automatic Updates**: Check for updates every 24 hours in the background
2. **One-Click Install**: Users click "Install Update" → app relaunches with new version
3. **Gentle Reminders**: No focus stealing; show subtle indicators when updates are available during background checks
4. **Security**: EdDSA signatures + Developer ID + notarization verification
5. **Manual Check**: "Check for Updates…" menu item for immediate checks

## Non-Goals
- Silent automatic updates without user consent (users must click "Install")
- Custom update UI (use Sparkle's standard UI)
- Support for non-DMG distributions (ZIP, pkg) in initial release

## Architecture

### Components
```
AgentSessionsApp.swift
  ↓ owns
UpdaterController (@StateObject, retained for app lifetime)
  ↓ wraps
SPUStandardUpdaterController (Sparkle)
  ↓ manages
SPUUpdater (background checks, download, install)
```

### Data Flow
```
Launch → UpdaterController init
  ↓
Sparkle auto-checks appcast (if 24h elapsed)
  ↓
Update found → delegate callback
  ↓
If app in focus: Show standard Sparkle alert
If app in background: Set hasGentleReminder = true
  ↓
User focuses app or clicks menu → Show Sparkle UI
  ↓
User clicks "Install" → Download → Verify → Replace → Relaunch
```

## Configuration

### Info.plist Keys
Add to `AgentSessions/Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://jazzyalex.github.io/agent-sessions/appcast.xml</string>

<key>SUPublicEDKey</key>
<string>REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY_FROM_generate_keys</string>

<key>SUEnableAutomaticChecks</key>
<true/>

<key>SUScheduledCheckInterval</key>
<integer>86400</integer>

<!-- Optional: Prevent silent installs -->
<key>SUAutomaticallyUpdate</key>
<false/>
```

**Note**: `SUEnableAutomaticChecks=true` skips Sparkle's first-launch opt-in dialog.

### Appcast URL
- **Production**: `https://jazzyalex.github.io/agent-sessions/appcast.xml`
- **Staging** (for testing): TBD - could use a separate branch or subdirectory

### EdDSA Keys
- **Generation**: Run Sparkle's `generate_keys` tool (found in SPM artifacts after build)
- **Private Key Storage**: Keychain (handled by `generate_keys`)
- **Public Key**: Copy base64 string to `SUPublicEDKey` in Info.plist

## UX Requirements

### Gentle Update Reminders
**Problem**: Menu bar apps don't want to steal focus during background checks.

**Solution**: Implement `SPUStandardUserDriverDelegate` methods:

```swift
var supportsGentleScheduledUpdateReminders: Bool { true }

func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
) -> Bool {
    // Only show Sparkle UI immediately if app is in focus
    return immediateFocus
}

func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
) {
    if !handleShowingUpdate {
        // Show gentle reminder (e.g., badge on menu bar icon)
        hasGentleReminder = true
    }
}

func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    // User focused the updater, clear gentle reminder
    hasGentleReminder = false
}
```

### Menu Integration
- **Existing Item**: "Check for Updates…" (already in app menu)
- **Action**: Wire to `updater.checkForUpdates(_:)` via `UpdaterController`
- **Optional**: Show badge/indicator on menu bar status item when `hasGentleReminder == true`

### First Launch
- Sparkle will immediately check for updates (respects `SUScheduledCheckInterval`)
- No opt-in dialog (due to `SUEnableAutomaticChecks=true`)

### Update Available
- **If app in focus**: Standard Sparkle alert with "Install Update", "Release Notes", "Remind Me Later", "Skip This Version"
- **If app in background**: Badge on menu bar, user focuses to see alert

### Up to Date
- **Manual check**: Show NSAlert "You're up to date"
- **Background check**: No UI (silent)

## Security Model

### Verification Chain
1. **HTTPS**: Appcast downloaded over TLS
2. **EdDSA Signature**: Each DMG entry in appcast has `edSignature` attribute
   - Sparkle verifies with `SUPublicEDKey` from Info.plist
   - Prevents MITM, ensures we published the update
3. **Developer ID**: DMG is code-signed with Developer ID Application cert
   - Sparkle verifies codesign author matches existing app
   - Prevents impostor apps from updating
4. **Notarization**: DMG is notarized by Apple
   - Gatekeeper checks on first launch
   - macOS verifies no known malware

### Failure Modes
| Scenario | Sparkle Behavior | User Impact |
|----------|------------------|-------------|
| No network | Log warning, retry on next scheduled check | None (silent) |
| 404 appcast | Log error, retry later | None (manual check shows error) |
| Invalid EdDSA signature | Reject update, log critical error | User stays on current version |
| Developer ID mismatch | Reject update, show error dialog | User stays on current version |
| Download interrupted | Resume on retry or re-download | User sees "Downloading..." progress |
| Install failure | Rollback to current version | User stays on current version |

### Key Management
- **Private Key**: Stored in macOS Keychain (by `generate_keys`)
- **Backup**: Export private key to secure location (e.g., 1Password, encrypted volume)
  - Command: `security find-generic-password -l "Sparkle" -w`
- **Loss Recovery**: If private key is lost, users must manually download new version
  - Generate new key pair, publish new appcast with new public key

## Implementation Details

### UpdaterController.swift
Location: `AgentSessions/Update/UpdaterController.swift`

Responsibilities:
- Retain `SPUStandardUpdaterController` for app lifetime
- Implement gentle reminder delegates
- Expose `@Published var hasGentleReminder: Bool` for UI
- Provide `@objc func checkForUpdates(_ sender: Any?)` for menu action

### App Integration
In `AgentSessionsApp.swift`:
```swift
@StateObject private var updaterController = UpdaterController()
```

Remove:
```swift
@StateObject private var updateModel = UpdateCheckModel.shared
```

### Menu Wiring
Replace in `.commands`:
```swift
// Before:
Button("Check for Updates…") { updateModel.checkManually() }

// After:
Button("Check for Updates…", action: updaterController.checkForUpdates)
```

### Optional: Menu Bar Badge
In `StatusItemController.swift`, observe `updaterController.hasGentleReminder`:
```swift
// Show blue dot or badge when true
// Clear when false
```

## Testing Requirements
See `docs/updates/test-plan.md` for detailed test cases.

### Smoke Test
1. Force update check: `defaults delete com.triada.AgentSessions SULastCheckTime`
2. Launch app
3. Verify Sparkle checks appcast
4. If update available: Verify gentle reminder or alert (depending on focus)

### Manual Check
1. Click "Check for Updates…"
2. If up to date: See "You're up to date" alert
3. If update available: See Sparkle update dialog

### Bad Signature Test
1. Publish appcast with incorrect `edSignature`
2. Check for updates
3. Verify Sparkle rejects update and logs error

## Performance Considerations
- **Background Checks**: Low priority, non-blocking
- **Download Size**: Sparkle generates binary diffs (deltas) between versions
  - First update: Full DMG download
  - Subsequent updates: Delta patches (much smaller)
- **Install Time**: ~2-5 seconds for typical update (app replaced, relaunched)

## Compatibility
- **macOS Version**: Same as app minimum (macOS 13 Ventura+)
- **Architecture**: Universal binary (x86_64 + arm64)
- **Sparkle Version**: 2.x (latest stable via SPM)

## Rollout Strategy
1. **v1**: Ship first Sparkle-enabled release
   - Users must manually download (Sparkle can't update from non-Sparkle version)
2. **v2+**: All updates via Sparkle
   - Post release notes reminding Homebrew users to `brew upgrade`

## Monitoring & Diagnostics
- **Console Logs**: Sparkle logs to `com.triada.AgentSessions` subsystem
  - Check with: `log show --predicate 'subsystem == "org.sparkle-project.Sparkle"' --last 1h`
- **User Reports**: Request Console logs if update fails
- **Metrics**: Track update adoption via GitHub release download counts

## References
- [Sparkle 2 Documentation](https://sparkle-project.org/documentation/)
- [Gentle Reminders Guide](https://sparkle-project.org/documentation/gentle-reminders/)
- [Publishing Guide](https://sparkle-project.org/documentation/publishing/)

## Appendix: Info.plist Snippet
See `docs/updates/InfoPlist-snippet.xml` for copy-paste template.
