import XCTest
@testable import AgentSessions

final class ClaudeTmuxSuppressionTests: XCTestCase {
    func testSuppressesWhenSignedOutExpiredOrCliMissing() {
        // I3: `.expired` triggers a CLI re-auth prompt that hangs the probe exactly
        // like signed-out, so it must suppress too.
        XCTAssertTrue(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(.signedOut))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(.cliNotInstalled))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(.expired))
    }
    func testDoesNotSuppressOtherStates() {
        for s in [UsageAuthState.ok, .unknown, .needsSetup] {
            XCTAssertFalse(ClaudeUsageSourceManager.shouldSuppressTmuxFallback(s))
        }
    }
}
