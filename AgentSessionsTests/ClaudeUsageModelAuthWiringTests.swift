import XCTest
@testable import AgentSessions

/// Task 9b (Claude half): `ClaudeUsageModel` publishes an auth verdict fed by
/// `ClaudeAuthClassifier` through the source manager's availability handler. The
/// full wiring (OAuth poll → off-actor probe/keychain read → classify) isn't
/// unit-testable without a real subprocess/network, so these tests pin the pure,
/// deterministic surface: the `ClaudeServiceAvailability.authState -> authStatus`
/// mapping in `applyAvailability(_:)` (views read `authStatus?.state.isAlarming`
/// to decide the banner), which is exactly what the availability handler closure
/// invokes on the main actor.
@MainActor
final class ClaudeUsageModelAuthWiringTests: XCTestCase {

    private func availability(_ state: UsageAuthState?) -> ClaudeServiceAvailability {
        ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false, authState: state)
    }

    func testSignedOutRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.signedOut))
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .signedOut)
        // Remediation now depends on CLI presence (a disk check), so the exact
        // rung is pinned by the pure-path tests in RunwayAuthDegradationTests
        // rather than here, where it would couple to the test machine's env.
    }

    /// Task 9 wiring contract (pure path): the model publishes the ladder rung
    /// chosen by CLI presence — this is what `applyAvailability` feeds `make`.
    func testRemediationRungSelectedByCliPresence() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .expired, cliPresent: true).remediation,
                       .showCommand("claude auth login"))
        if case .noCLILadder = UsageAuthStatus.make(provider: .claude, state: .expired, cliPresent: false).remediation {
            // ok
        } else {
            XCTFail("no-CLI user must get the ladder, not a copy command")
        }
    }

    func testExpiredRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.expired))
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .expired)
    }

    func testCliNotInstalledRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.cliNotInstalled))
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .cliNotInstalled)
    }

    func testOkIsSilent() {
        let model = ClaudeUsageModel()
        // Seed an alarming state first, then confirm `.ok` clears the banner.
        model.applyAvailability(availability(.signedOut))
        model.applyAvailability(availability(.ok))
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .ok)
    }

    func testUnknownIsSilent() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.unknown))
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .unknown)
    }

    /// A legacy tmux/probe emit carries no `authState`; it must NOT disturb the
    /// banner surface (the `if let state` guard), only the legacy bools.
    func testNilAuthStateLeavesBannerUntouched() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.signedOut))   // banner up
        model.applyAvailability(ClaudeServiceAvailability(cliUnavailable: true, tmuxUnavailable: true, authState: nil))
        XCTAssertEqual(model.authStatus?.state.isAlarming, true) // unchanged
        XCTAssertEqual(model.authStatus?.state, .signedOut)      // unchanged
        XCTAssertTrue(model.cliUnavailable)                      // legacy bool still applied
        XCTAssertTrue(model.tmuxUnavailable)
    }

    // MARK: - P2: transientReason (calm caption, distinct from the banner)

    /// A transient emit publishes the calm caption but never raises the banner.
    func testTransientReasonPublishedWithoutTouchingBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false, transientReason: "temp"))
        XCTAssertEqual(model.transientReason, "temp")
        XCTAssertNil(model.authStatus)   // no auth update → banner untouched
    }

    /// A later emit with a nil reason (e.g. a successful fetch) clears the caption.
    func testTransientReasonClearsOnRecovery() {
        let model = ClaudeUsageModel()
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false, transientReason: "temp"))
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false, transientReason: nil))
        XCTAssertNil(model.transientReason)
    }

    /// An alarming (banner) emit never also carries the calm caption — never both.
    func testAlarmingEmitCarriesNoTransientReason() {
        let model = ClaudeUsageModel()
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false, authState: .expired, transientReason: nil))
        XCTAssertEqual(model.authStatus?.state, .expired)
        XCTAssertNil(model.transientReason)
    }

    // MARK: - P4 Task 13: CLI-fallback source labeling

    /// `currentSource` mirrors the applied snapshot so the UI can label CLI-probe
    /// (tmux) data distinctly from the OAuth endpoint.
    func testCurrentSourceReflectsSnapshotSource() {
        let model = ClaudeUsageModel()
        model.applyLimitSnapshotForTesting(Self.sampleSnapshot(source: .tmuxUsage))
        XCTAssertEqual(model.currentSource, .tmuxUsage)
        model.applyLimitSnapshotForTesting(Self.sampleSnapshot(source: .oauthEndpoint))
        XCTAssertEqual(model.currentSource, .oauthEndpoint)
    }

    private static func sampleSnapshot(source: ClaudeUsageSource) -> ClaudeLimitSnapshot {
        ClaudeLimitSnapshot(fetchedAt: Date(), source: source, health: .live,
            fiveHourUsedRatio: 0.3, fiveHourResetText: "", weeklyUsedRatio: 0.1, weeklyResetText: "",
            weekOpusUsedRatio: nil, weekOpusResetText: nil, rawPayloadHash: nil)
    }

    // MARK: - No-CLI ladder, end-to-end through applyAvailability (self-test)

    /// With the CLI absent, an alarming auth state publishes the no-CLI ladder —
    /// this drives the exact path the banner renders, not just the pure factory.
    func testNoCLILadderRenderedWhenCLIAbsent() {
        ClaudeUsageModel.cliPresenceOverrideForTesting = false
        defer { ClaudeUsageModel.cliPresenceOverrideForTesting = nil }
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.expired))
        XCTAssertEqual(model.authStatus?.state, .expired)
        guard case .noCLILadder = model.authStatus?.remediation else {
            return XCTFail("no-CLI user must get the ladder, got \(String(describing: model.authStatus?.remediation))")
        }
    }

    /// With the CLI present, the same alarming state keeps the copy-command chip.
    func testCopyCommandRenderedWhenCLIPresent() {
        ClaudeUsageModel.cliPresenceOverrideForTesting = true
        defer { ClaudeUsageModel.cliPresenceOverrideForTesting = nil }
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.signedOut))
        XCTAssertEqual(model.authStatus?.remediation, .showCommand("claude auth login"))
    }

    // MARK: - Finding-2 fix: caption-only emit doesn't clobber orthogonal state

    func testCaptionOnlyEmitDoesNotClobberLegacyState() {
        let model = ClaudeUsageModel()
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false, setupRequired: true, authState: nil))
        XCTAssertTrue(model.setupRequired)
        // A caption-only transient emit (e.g. 429) must update the caption but leave
        // setupRequired untouched.
        model.applyAvailability(ClaudeServiceAvailability(
            cliUnavailable: false, tmuxUnavailable: false,
            transientReason: "temp", captionOnly: true))
        XCTAssertEqual(model.transientReason, "temp")
        XCTAssertTrue(model.setupRequired)   // NOT clobbered
    }
}
