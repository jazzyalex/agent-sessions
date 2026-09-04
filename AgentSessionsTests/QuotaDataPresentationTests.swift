import XCTest
@testable import AgentSessions

final class QuotaDataPresentationTests: XCTestCase {

    private func localized(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

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
        XCTAssertEqual(localized(q.reconnectingCaption), "rate limited — retrying…")
        XCTAssertFalse(q.reconnectingCaptionUsesProviderName)
        XCTAssertTrue(q.isRateLimited)
    }

    func testCaption_transientUnavailable_saysRetrying() {
        let q = claudeQuota(transientReason: "Temporarily unavailable — retrying")
        XCTAssertEqual(localized(q.reconnectingCaption), "retrying…")
        XCTAssertFalse(q.reconnectingCaptionUsesProviderName)
        XCTAssertFalse(q.isRateLimited)
    }

    func testCaption_noReason_fallsBackToReconnecting() {
        XCTAssertEqual(localized(claudeQuota(transientReason: nil).reconnectingCaption), "reconnecting…")
        XCTAssertEqual(localized(claudeQuota(transientReason: "").reconnectingCaption), "reconnecting…")
        XCTAssertTrue(claudeQuota(transientReason: nil).reconnectingCaptionUsesProviderName)
    }

    func testCaption_unrecognizedReason_fallsBackToReconnecting() {
        // Unknown manager captions must never leak raw sentence-case prose
        // into the compact QM cell.
        let q = claudeQuota(transientReason: "Some future caption we have not mapped")
        XCTAssertEqual(localized(q.reconnectingCaption), "reconnecting…")
        XCTAssertTrue(q.reconnectingCaptionUsesProviderName)
    }

    func testQuotaMeterProviderVisibilityDefaultsToAllShown() {
        for provider in QuotaMeterProvider.allCases {
            XCTAssertTrue(QuotaMeterProviderVisibility.isVisible(provider, hiddenProvidersRaw: ""))
            XCTAssertTrue(QuotaMeterProviderVisibility.isVisible(provider, hiddenProvidersRaw: "[]"))
        }
    }

    func testQuotaMeterProviderVisibilityTogglesIndependently() {
        let claudeHidden = QuotaMeterProviderVisibility.setting(
            .claude,
            visible: false,
            hiddenProvidersRaw: QuotaMeterProviderVisibility.defaultRawValue
        )
        XCTAssertFalse(QuotaMeterProviderVisibility.isVisible(.claude, hiddenProvidersRaw: claudeHidden))
        XCTAssertTrue(QuotaMeterProviderVisibility.isVisible(.codex, hiddenProvidersRaw: claudeHidden))

        let bothHidden = QuotaMeterProviderVisibility.setting(.codex, visible: false, hiddenProvidersRaw: claudeHidden)
        XCTAssertFalse(QuotaMeterProviderVisibility.isVisible(.claude, hiddenProvidersRaw: bothHidden))
        XCTAssertFalse(QuotaMeterProviderVisibility.isVisible(.codex, hiddenProvidersRaw: bothHidden))
    }

    func testQuotaMeterProviderVisibilityPreservesUnknownFutureIDs() {
        let raw = "[\"future-provider\",\"claude\"]"
        let updated = QuotaMeterProviderVisibility.setting(.claude, visible: true, hiddenProvidersRaw: raw)
        XCTAssertEqual(QuotaMeterProviderVisibility.hiddenIDs(from: updated), ["future-provider"])
    }
}
