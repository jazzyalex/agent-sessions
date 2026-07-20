import XCTest
@testable import AgentSessions

final class QuotaDataPresentationTests: XCTestCase {

    private func claudeQuota(transientReason: String?, stale: Bool = false) -> QuotaData {
        // provider/percent/reset fields have no memberwise defaults.
        var q = QuotaData(provider: .claude,
                          fiveHourRemainingPercent: 73,
                          fiveHourResetText: "",
                          weekRemainingPercent: 91,
                          weekResetText: "")
        q.transientReason = transientReason
        q.dataIsStale = stale
        return q
    }

    func testCaption_rateLimited_saysRateLimited() {
        let q = claudeQuota(transientReason: "Rate limited — retrying shortly")
        XCTAssertEqual(q.reconnectingCaption, "rate limited — retrying…")
    }

    func testCaption_transientUnavailable_saysRetrying() {
        let q = claudeQuota(transientReason: "Temporarily unavailable — retrying")
        XCTAssertEqual(q.reconnectingCaption, "retrying…")
    }

    func testCaption_noReason_fallsBackToReconnecting() {
        XCTAssertEqual(claudeQuota(transientReason: nil).reconnectingCaption, "reconnecting…")
        XCTAssertEqual(claudeQuota(transientReason: "").reconnectingCaption, "reconnecting…")
    }

    func testCaption_unrecognizedReason_fallsBackToReconnecting() {
        // Unknown manager captions must never leak raw sentence-case prose
        // into the compact QM cell.
        let q = claudeQuota(transientReason: "Some future caption we have not mapped")
        XCTAssertEqual(q.reconnectingCaption, "reconnecting…")
    }
}
