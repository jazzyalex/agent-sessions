import XCTest
@testable import AgentSessions

final class CodexStatusProbeSuppressionTests: XCTestCase {

    // MARK: - UsageAuthState-based suppression

    /// I3: `.expired` joins `.signedOut` / `.cliNotInstalled` as suppress-worthy
    /// because an expired-token re-auth prompt hangs the /status probe exactly
    /// like a signed-out login screen.
    func testSuppressesWhenSignedOutExpiredOrCliMissing() {
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.signedOut))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.expired))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.cliNotInstalled))
    }

    func testDoesNotSuppressOtherStates() {
        for s in [UsageAuthState.ok, .unknown, .needsSetup] {
            XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(s))
        }
    }

    // MARK: - Authoritative CLI-status suppression (I1)

    /// The authoritative `codex login status` probe never reports a false
    /// `.signedOut`, so a definitive signed-out / missing-CLI answer suppresses
    /// the /status tmux probe immediately, regardless of a stale auth state.
    func testSuppressesOnAuthoritativeSignedOutOrMissingCLI() {
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .signedOut))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .cliMissing))
    }

    /// Signed-in or ambiguous (`.unknown`) CLI status must never suppress — the
    /// probe is exactly what fetches usage in the ambiguous/no-data case.
    func testDoesNotSuppressOnSignedInOrAmbiguousCLIStatus() {
        XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .signedIn))
        XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(cliStatus: .unknown))
    }
}
