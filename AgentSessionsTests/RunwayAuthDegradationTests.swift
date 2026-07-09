import XCTest
@testable import AgentSessions

/// P2/P3 pure-helper coverage for the cause-aware degradation work
/// (spec 2026-07-08-runway-auth-degradation-and-cli-fallback.md).
final class RunwayAuthDegradationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    // MARK: - Task 1: debounced .expired escalation

    func testNoFirst401NeverEscalates() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(first401At: nil, now: t0, threshold: 300))
    }

    func testUnderThresholdStaysCalm() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(299), threshold: 300))
    }

    func testAtThresholdEscalates() {
        XCTAssertTrue(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(300), threshold: 300))
    }

    func testExpiredPublicationPreEscalationHidesBannerShowsReason() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: false)
        XCTAssertNil(p.authState)                 // nil = "no auth update" — banner untouched
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }

    func testExpiredPublicationPostEscalationRaisesBanner() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: true)
        XCTAssertEqual(p.authState, .expired)
        XCTAssertNil(p.reason)
    }

    func testFailurePublicationAlarmingVerdictPassesThrough() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .signedOut)
        XCTAssertEqual(p.authState, .signedOut)
        XCTAssertNil(p.reason)
    }

    func testFailurePublicationUnknownCarriesCalmReason() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .unknown)
        XCTAssertEqual(p.authState, .unknown)
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }
}
