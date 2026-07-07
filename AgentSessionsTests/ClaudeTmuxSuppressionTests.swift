import XCTest
@testable import AgentSessions

final class ClaudeTmuxSuppressionTests: XCTestCase {
    func testSuppressesWhenSignedOutOrCliMissing() {
        XCTAssertTrue(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(.signedOut))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(.cliNotInstalled))
    }
    func testDoesNotSuppressOtherStates() {
        for s in [UsageAuthState.ok, .unknown, .expired, .needsSetup] {
            XCTAssertFalse(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(s))
        }
    }
}
