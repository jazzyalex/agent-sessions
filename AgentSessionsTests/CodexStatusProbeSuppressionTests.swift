import XCTest
@testable import AgentSessions

final class CodexStatusProbeSuppressionTests: XCTestCase {
    func testSuppressesWhenSignedOutOrCliMissing() {
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.signedOut))
        XCTAssertTrue(CodexStatusService.shouldSuppressStatusProbe(.cliNotInstalled))
    }
    func testDoesNotSuppressOtherStates() {
        for s in [UsageAuthState.ok, .unknown, .expired, .needsSetup] {
            XCTAssertFalse(CodexStatusService.shouldSuppressStatusProbe(s))
        }
    }
}
