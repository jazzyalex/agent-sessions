# ADR-0002: Adopt Sparkle 2 for Agent Sessions Updates

## Status
Accepted

## Context
Agent Sessions currently uses a manual update checker (`UpdateCheckModel`) that:
- Polls GitHub releases API every 24 hours
- Shows manual download alerts with "Release Notes" and "Download" buttons
- Requires users to manually download DMG, mount, and replace app
- No cryptographic verification of downloads
- No delta updates or bandwidth optimization

We need secure, friction-free automatic updates that respect the menu-bar/background app nature of Agent Sessions.

### Requirements
- **Security**: Cryptographically signed updates with Developer ID verification
- **UX**: One-click updates with gentle, non-intrusive notifications
- **Menu Bar Focus**: No focus stealing; users work primarily in other apps
- **Notarization**: Maintain existing notarization and Gatekeeper compliance
- **Parallel Distribution**: Keep DMG and Homebrew cask as alternative install methods

## Decision
Adopt **Sparkle 2** framework for automatic updates with:

1. **EdDSA (ed25519) signatures** for update verification
2. **HTTPS appcast** hosted on GitHub Pages (`jazzyalex.github.io/agent-sessions/appcast.xml`)
3. **Gentle Update Reminders**: Background checks that show subtle indicators without stealing focus
4. **DMG distribution**: Continue using notarized DMG archives
5. **24-hour check cadence**: Match existing UpdateCheckModel behavior

### Sparkle 2 Integration Approach
- Add via Swift Package Manager
- Use `SPUStandardUpdaterController` with custom delegate for gentle reminders
- Implement `supportsGentleScheduledUpdateReminders` to avoid focus stealing
- Wire to existing "Check for Updates…" menu item

## Consequences

### Positive
- **Security**: EdDSA signatures + Developer ID verification protect users from malicious updates
- **User Experience**: One-click install; users no longer need to manually download and replace
- **Delta Updates**: Sparkle generates binary diffs, reducing download size for incremental updates
- **Standard Behavior**: Industry-standard update UI that users recognize (vs custom alerts)
- **Maintenance**: Sparkle handles complex edge cases (permissions, Gatekeeper, replace-in-place, rollback)

### Negative
- **Dependency**: Add external framework vs custom code
- **Release Complexity**: Add appcast generation step to release workflow
- **Key Management**: EdDSA private key must be securely stored and backed up
- **Testing Overhead**: Need to test update flow end-to-end (can't just test GitHub API)

### Neutral
- **Alternative Considered**: Roll-your-own update system
  - Would require reimplementing:
    - Signature verification
    - Gatekeeper quarantine handling
    - Safe atomic app replacement
    - Rollback on failure
    - Delta updates
  - Decision: Not worth the engineering cost and security risk

## Implementation Strategy

### Phase 1: Foundation (Current Release)
1. Add Sparkle 2 via SPM
2. Generate EdDSA keys (store private key securely)
3. Add Info.plist keys (SUFeedURL, SUPublicEDKey, etc.)
4. Implement `UpdaterController` with gentle reminder delegates
5. Replace `UpdateCheckModel` usage in app

### Phase 2: Release Automation
1. Update `tools/release/deploy-agent-sessions.sh` to run `generate_appcast`
2. Publish appcast.xml to GitHub Pages
3. Test end-to-end update flow with staging appcast

### Phase 3: Rollout
1. Ship first Sparkle-enabled version (users must manually install)
2. Subsequent updates use Sparkle automatic flow
3. Monitor for issues (check Sparkle logs, user reports)

## Rollback Plan
If Sparkle causes critical issues:
1. Remove `SUFeedURL` from Info.plist (disables Sparkle)
2. Restore `UpdateCheckModel` from git history
3. Ship hotfix release via manual download
4. Investigate root cause before re-enabling

## Security Model
```
User launches app
  ↓
Sparkle checks appcast.xml (HTTPS, every 24h)
  ↓
Appcast contains: version, DMG URL, EdDSA signature, release notes URL
  ↓
Sparkle verifies:
  1. EdDSA signature (prevents MITM, ensures our private key signed it)
  2. Developer ID codesign (ensures Apple-verified author)
  3. Notarization (Gatekeeper checks)
  ↓
If all pass: Download → Replace app → Relaunch
If any fail: Reject update, log error, stay on current version
```

## Metrics for Success
- ✅ 95%+ of users on latest version within 7 days of release
- ✅ Zero reports of failed updates or app corruption
- ✅ No focus-stealing complaints (gentle reminders working)
- ✅ Release process adds <5 minutes to publish time

## References
- [Sparkle 2 Documentation](https://sparkle-project.org/documentation/)
- [EdDSA Signature Guide](https://sparkle-project.org/documentation/publishing/#eddsa-signatures)
- Existing deployment: `docs/deployment.md`
- Release script: `tools/release/deploy-agent-sessions.sh`

## Date
2025-10-15

## Authors
Agent Sessions Team
