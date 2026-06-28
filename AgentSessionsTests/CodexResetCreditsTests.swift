import XCTest
@testable import AgentSessions

final class CodexResetCreditsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed reference

    private func credit(daysFromNow: Double, status: String? = "available") -> CodexResetCredit {
        CodexResetCredit(
            grantedAt: now,
            expiresAt: now.addingTimeInterval(daysFromNow * 86_400),
            status: status
        )
    }

    // MARK: renderable

    func testRenderableExcludesExpiredAndRedeemedStatus() {
        let credits = [
            credit(daysFromNow: 30, status: "available"),
            credit(daysFromNow: 30, status: "expired"),
            credit(daysFromNow: 30, status: "redeemed"),
            credit(daysFromNow: 30, status: "REDEEMED"), // case-insensitive
        ]
        XCTAssertEqual(CodexResetCredits.renderable(credits, now: now).count, 1)
    }

    func testRenderableExcludesPastExpiry() {
        let credits = [credit(daysFromNow: -1), credit(daysFromNow: 10)]
        XCTAssertEqual(CodexResetCredits.renderable(credits, now: now).count, 1)
    }

    func testRenderableSortsByExpiryAscending() {
        let later = credit(daysFromNow: 30)
        let sooner = credit(daysFromNow: 5)
        let result = CodexResetCredits.renderable([later, sooner], now: now)
        XCTAssertEqual(result.first?.expiresAt, sooner.expiresAt)
    }

    // MARK: quotaMeterLine

    func testQuotaMeterLineNilWhenNoneRenderable() {
        XCTAssertNil(CodexResetCredits.quotaMeterLine([], now: now))
        XCTAssertNil(CodexResetCredits.quotaMeterLine([credit(daysFromNow: -1)], now: now))
    }

    func testQuotaMeterLineSingular() {
        let line = CodexResetCredits.quotaMeterLine([credit(daysFromNow: 10)], now: now)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("↑ 1 reset credit · expires "), line ?? "")
    }

    func testQuotaMeterLinePlural() {
        let line = CodexResetCredits.quotaMeterLine(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("↑ 2 reset credits · next expires "), line ?? "")
    }

    // MARK: menuSummaryLine

    func testMenuSummaryLineSingular() {
        let line = CodexResetCredits.menuSummaryLine([credit(daysFromNow: 10)], now: now)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("1 available · expires "), line ?? "")
    }

    func testMenuSummaryLinePlural() {
        let line = CodexResetCredits.menuSummaryLine(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertTrue(line!.hasPrefix("2 available · next expires "), line ?? "")
    }

    func testMenuSummaryLineNilWhenEmpty() {
        XCTAssertNil(CodexResetCredits.menuSummaryLine([], now: now))
    }

    func testMenuExpiryLinesOnePerRenderableCredit() {
        let lines = CodexResetCredits.menuExpiryLines(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("expires ") })
    }

    // MARK: decoder

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParseIssueSamplePayload() {
        let json = """
        {"available_count": 1,
         "credits": [
            {"granted_at": "2026-06-17T17:38:38Z",
             "expires_at": "2026-07-17T17:38:38Z",
             "status": "available"}
         ]}
        """
        let snap = CodexResetCreditsParser.parse(data(json))
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.available, 1)
        XCTAssertEqual(snap?.credits.count, 1)
        XCTAssertEqual(snap?.credits.first?.status, "available")
        XCTAssertNotNil(snap?.credits.first?.expiresAt)
    }

    func testParseZeroCredits() {
        let snap = CodexResetCreditsParser.parse(data(#"{"available_count": 0, "credits": []}"#))
        XCTAssertEqual(snap?.available, 0)
        XCTAssertEqual(snap?.credits.count, 0)
    }

    func testParseMissingFieldsAreNil() {
        let snap = CodexResetCreditsParser.parse(data(#"{"credits": [{}]}"#))
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.credits.count, 1)
        XCTAssertNil(snap?.credits.first?.grantedAt)
        XCTAssertNil(snap?.credits.first?.expiresAt)
        XCTAssertNil(snap?.credits.first?.status)
        // available falls back to credits.count when available_count absent
        XCTAssertEqual(snap?.available, 1)
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(CodexResetCreditsParser.parse(data("not json")))
    }

    func testParseFractionalSecondsISO() {
        let json = #"{"available_count": 1, "credits": [{"expires_at": "2026-07-17T17:38:38.397911+00:00"}]}"#
        let snap = CodexResetCreditsParser.parse(data(json))
        XCTAssertNotNil(snap?.credits.first?.expiresAt)
    }

    // MARK: model apply

    @MainActor
    func testModelApplyResetCreditsPublishesValues() {
        let model = CodexUsageModel()
        let snap = CodexResetCreditsSnapshot(
            available: 2,
            credits: [
                CodexResetCredit(grantedAt: now, expiresAt: now.addingTimeInterval(86_400), status: "available"),
                CodexResetCredit(grantedAt: now, expiresAt: now.addingTimeInterval(172_800), status: "available"),
            ]
        )
        model.applyResetCredits(snap)
        XCTAssertEqual(model.resetCreditsAvailable, 2)
        XCTAssertEqual(model.resetCredits.count, 2)
        XCTAssertNotNil(model.resetCreditsLastFetch)
    }
}
