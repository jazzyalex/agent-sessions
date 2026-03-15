import XCTest
@testable import AgentSessions

final class UsageResetTextTests: XCTestCase {

    // MARK: - ISO 8601 parsing

    func testParseISO8601_fractionalSeconds() {
        let raw = "2026-03-14T09:00:00.397911+00:00"
        let date = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        XCTAssertNotNil(date, "Should parse ISO 8601 with fractional seconds")
        if let d = date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            XCTAssertEqual(comps.year, 2026)
            XCTAssertEqual(comps.month, 3)
            XCTAssertEqual(comps.day, 14)
            XCTAssertEqual(comps.hour, 9)
            XCTAssertEqual(comps.minute, 0)
        }
    }

    func testParseISO8601_zulu() {
        let raw = "2026-03-14T09:00:00Z"
        let date = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        XCTAssertNotNil(date, "Should parse ISO 8601 Zulu format")
    }

    func testParseISO8601_noFraction() {
        let raw = "2026-03-14T09:00:00+00:00"
        let date = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        XCTAssertNotNil(date, "Should parse ISO 8601 without fractional seconds")
    }

    // MARK: - Display text for ISO 8601

    func testDisplayText_iso8601FiveHour_returnsTimeFormat() {
        // 5h kind → time-only format (e.g. "9:00 AM")
        let raw = "2026-03-14T09:00:00Z"
        let text = UsageResetText.displayText(kind: "5h", source: .claude, raw: raw)
        XCTAssertFalse(text.isEmpty, "Should produce non-empty display text for 5h ISO 8601")
        // Should not contain raw ISO characters
        XCTAssertFalse(text.contains("T"), "Should not contain raw ISO 8601 'T' separator")
        XCTAssertFalse(text.contains("+00:00"), "Should not contain raw timezone offset")
    }

    func testDisplayText_iso8601Weekly_returnsDateTimeFormat() {
        // Wk kind → date+time format (e.g. "3/19, 8:00 PM")
        let raw = "2026-03-19T20:00:00Z"
        let text = UsageResetText.displayText(kind: "Wk", source: .claude, raw: raw)
        XCTAssertFalse(text.isEmpty, "Should produce non-empty display text for Wk ISO 8601")
        XCTAssertFalse(text.contains("T"), "Should not contain raw ISO 8601 'T' separator")
    }

    func testResetDate_iso8601_returnsNonNil() {
        let raw = "2026-03-19T20:00:00.000000+00:00"
        let date = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: raw)
        XCTAssertNotNil(date)
    }

    // MARK: - Existing formats still work (regression)

    func testDisplayText_codexLegacy_unaffected() {
        let raw = "resets 14:00 on 15 Mar (America/Los_Angeles)"
        let date = UsageResetText.resetDate(kind: "5h", source: .codex, raw: raw)
        XCTAssertNotNil(date, "Codex legacy format should still parse after adding ISO 8601 support")
    }

    func testDisplayText_claudeHumanReadable_unaffected() {
        let raw = "Mar 19 at 8pm"
        let date = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: raw)
        XCTAssertNotNil(date, "Claude human-readable format should still parse")
    }
}
