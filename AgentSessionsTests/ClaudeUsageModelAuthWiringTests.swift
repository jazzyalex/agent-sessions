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
        XCTAssertEqual(model.authStatus?.remediation, .showCommand("claude auth login"))
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
}
