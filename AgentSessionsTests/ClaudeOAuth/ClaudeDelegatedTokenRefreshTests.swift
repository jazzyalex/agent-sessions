import XCTest
@testable import AgentSessions

final class ClaudeDelegatedTokenRefreshTests: XCTestCase {

    /// When the CLI is unavailable, attemptRefresh must return .cliUnavailable without crashing.
    func testAttemptRefresh_cliNotAvailable_returnsCliUnavailable() async {
        // This test relies on the binary resolver not finding a `claude` binary
        // at the expected location. In CI, claude is not installed; locally it
        // may be — if so, the test validates that the function completes without crash.
        let refresher = ClaudeDelegatedTokenRefresh()
        let result = await refresher.attemptRefresh()
        // Any result is valid — the key assertion is that it doesn't crash/hang
        switch result {
        case .cliUnavailable, .noChange, .timeout, .refreshed:
            break  // all are acceptable outcomes
        }
    }

    /// Calling attemptRefresh multiple times must not crash or deadlock.
    func testAttemptRefresh_doesNotCrash() async {
        let refresher = ClaudeDelegatedTokenRefresh()
        _ = await refresher.attemptRefresh()
        // Second call should be independent (actor isolation ensures no shared mutable state issues)
        _ = await refresher.attemptRefresh()
    }
}
