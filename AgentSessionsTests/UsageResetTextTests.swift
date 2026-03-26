import XCTest
@testable import AgentSessions

final class UsageResetTextTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FreshUntilKeys.codex)
        UserDefaults.standard.removeObject(forKey: FreshUntilKeys.claude)
        UserDefaults.standard.removeObject(forKey: UsageProbeCooldownKeys.codexAutoProbe)
        super.tearDown()
    }

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

    func testCodexAutoProbeCooldownDoesNotAffectEffectiveEventTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventTimestamp = now.addingTimeInterval(-2 * 60 * 60)
        setCodexAutoProbeCooldown(until: now.addingTimeInterval(4 * 60 * 60))

        let effective = effectiveEventTimestamp(
            source: .codex,
            eventTimestamp: eventTimestamp,
            lastUpdate: nil,
            now: now
        )

        XCTAssertEqual(effective, eventTimestamp)
    }

    func testCodexFreshUntilStillSmoothsEffectiveEventTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventTimestamp = now.addingTimeInterval(-2 * 60 * 60)
        setFreshUntil(for: .codex, until: now.addingTimeInterval(UsageFreshnessTTL.probeFreshness))

        let effective = effectiveEventTimestamp(
            source: .codex,
            eventTimestamp: eventTimestamp,
            lastUpdate: nil,
            now: now
        )

        XCTAssertEqual(effective, now)
    }

    func testFormatUsageWeeklyResetLabelIncludesTimeBeyondTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(49 * 60 * 60)

        let label = formatUsageWeeklyResetLabel(reset, now: now)

        XCTAssertEqual(label, "\(AppDateFormatting.weekdayAbbrev(reset)) \(AppDateFormatting.timeShort(reset))")
    }

    func testCodexStatusServiceStartClearsPersistedAutoProbeCooldown() async {
        let now = Date()
        setCodexAutoProbeCooldown(until: now.addingTimeInterval(4 * 60 * 60))

        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.start()
        await service.stop()

        let cooldown = codexAutoProbeCooldownUntil(now: now)
        XCTAssertNotNil(cooldown)
        XCTAssertLessThanOrEqual(cooldown!, Date())
    }

    func testClaudeEffectiveEventTimestampUsesLastUpdateWithoutFreshTTL() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastUpdate = now.addingTimeInterval(-2 * 60 * 60)

        let effective = effectiveEventTimestamp(
            source: .claude,
            eventTimestamp: nil,
            lastUpdate: lastUpdate,
            now: now
        )

        XCTAssertEqual(effective, lastUpdate)
    }

    func testClaudeFreshUntilSmoothsEffectiveEventTimestamp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastUpdate = now.addingTimeInterval(-2 * 60 * 60)
        setFreshUntil(for: .claude, until: now.addingTimeInterval(UsageFreshnessTTL.probeFreshness))

        let effective = effectiveEventTimestamp(
            source: .claude,
            eventTimestamp: nil,
            lastUpdate: lastUpdate,
            now: now
        )

        XCTAssertEqual(effective, now)
    }

    func testFormatResetDisplayForMenuShowsOutdatedCopyWhenClaudeDataIsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastUpdate = now.addingTimeInterval(-(UsageStaleThresholds.claudeWeekly + 60))

        let text = formatResetDisplayForMenu(
            kind: "Wk",
            source: .claude,
            raw: "2026-03-19T20:00:00Z",
            lastUpdate: lastUpdate,
            eventTimestamp: nil,
            now: now
        )

        XCTAssertEqual(text, UsageStaleThresholds.outdatedCopy)
    }

    func testFormatResetDisplayForMenuIncludesRelativeAndAbsoluteForFreshClaudeData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(49 * 60 * 60)
        let raw = ISO8601DateFormatter().string(from: reset)

        let text = formatResetDisplayForMenu(
            kind: "Wk",
            source: .claude,
            raw: raw,
            lastUpdate: now,
            eventTimestamp: nil,
            now: now
        )

        XCTAssertTrue(text.contains("("))
        XCTAssertTrue(text.contains(AppDateFormatting.weekdayAbbrev(reset)))
        XCTAssertTrue(text.contains(AppDateFormatting.timeShort(reset)))
    }

    func testFormatResetDisplayUsesOutdatedCopyWhenCodexDataIsStale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let eventTimestamp = now.addingTimeInterval(-(UsageStaleThresholds.codexWeekly + 60))

        let text = formatResetDisplay(
            kind: "Wk",
            source: .codex,
            raw: "resets 14:00 on 15 Mar (UTC)",
            lastUpdate: nil,
            eventTimestamp: eventTimestamp,
            now: now
        )

        XCTAssertEqual(text, UsageStaleThresholds.outdatedCopy)
    }

    func testFormatResetDisplayReturnsNormalizedResetTextForFreshClaudeData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = "2026-03-19T20:00:00Z"

        let text = formatResetDisplay(
            kind: "Wk",
            source: .claude,
            raw: raw,
            lastUpdate: now,
            eventTimestamp: nil,
            now: now
        )

        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("T"))
        XCTAssertNotEqual(text, UsageStaleThresholds.outdatedCopy)
    }

    func testFormatResetDisplayPreservesUnavailableCopy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let text = formatResetDisplay(
            kind: "Wk",
            source: .codex,
            raw: UsageStaleThresholds.unavailableCopy,
            lastUpdate: nil,
            eventTimestamp: now,
            now: now
        )

        XCTAssertEqual(text, UsageStaleThresholds.unavailableCopy)
    }

    func testFormatResetDisplayForMenuPreservesUnavailableCopy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let text = formatResetDisplayForMenu(
            kind: "Wk",
            source: .codex,
            raw: UsageStaleThresholds.unavailableCopy,
            lastUpdate: nil,
            eventTimestamp: now,
            now: now
        )

        XCTAssertEqual(text, UsageStaleThresholds.unavailableCopy)
    }
}
