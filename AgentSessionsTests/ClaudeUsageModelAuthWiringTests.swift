import XCTest
@testable import AgentSessions

/// Task 9b (Claude half): `ClaudeUsageModel` publishes an auth verdict fed by
/// `ClaudeAuthClassifier` through the source manager's availability handler. The
/// full wiring (OAuth poll → off-actor probe/keychain read → classify) isn't
/// unit-testable without a real subprocess/network, so these tests pin the pure,
/// deterministic surface: the `ClaudeServiceAvailability.authState -> (authStatus,
/// showAuthBanner)` mapping in `applyAvailability(_:)`, which is exactly what the
/// availability handler closure invokes on the main actor.
@MainActor
final class ClaudeUsageModelAuthWiringTests: XCTestCase {

    private func availability(_ state: UsageAuthState?) -> ClaudeServiceAvailability {
        ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false, authState: state)
    }

    func testSignedOutRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.signedOut))
        XCTAssertTrue(model.showAuthBanner)
        XCTAssertEqual(model.authStatus?.state, .signedOut)
        XCTAssertEqual(model.authStatus?.remediation, .showCommand("claude auth login"))
    }

    func testExpiredRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.expired))
        XCTAssertTrue(model.showAuthBanner)
        XCTAssertEqual(model.authStatus?.state, .expired)
    }

    func testCliNotInstalledRaisesBanner() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.cliNotInstalled))
        XCTAssertTrue(model.showAuthBanner)
        XCTAssertEqual(model.authStatus?.state, .cliNotInstalled)
    }

    func testOkIsSilent() {
        let model = ClaudeUsageModel()
        // Seed an alarming state first, then confirm `.ok` clears the banner.
        model.applyAvailability(availability(.signedOut))
        model.applyAvailability(availability(.ok))
        XCTAssertFalse(model.showAuthBanner)
        XCTAssertEqual(model.authStatus?.state, .ok)
    }

    func testUnknownIsSilent() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.unknown))
        XCTAssertFalse(model.showAuthBanner)
        XCTAssertEqual(model.authStatus?.state, .unknown)
    }

    /// A legacy tmux/probe emit carries no `authState`; it must NOT disturb the
    /// banner surfaces (the `if let state` guard), only the legacy bools.
    func testNilAuthStateLeavesBannerUntouched() {
        let model = ClaudeUsageModel()
        model.applyAvailability(availability(.signedOut))   // banner up
        model.applyAvailability(ClaudeServiceAvailability(cliUnavailable: true, tmuxUnavailable: true, authState: nil))
        XCTAssertTrue(model.showAuthBanner)                 // unchanged
        XCTAssertEqual(model.authStatus?.state, .signedOut) // unchanged
        XCTAssertTrue(model.cliUnavailable)                 // legacy bool still applied
        XCTAssertTrue(model.tmuxUnavailable)
    }
}
