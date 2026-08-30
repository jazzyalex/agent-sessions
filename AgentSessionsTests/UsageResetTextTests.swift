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

    // MARK: - ISO 8601 memoization parity
    //
    // `parseISO8601` is a pure function of its input text (no `now` parameter — the
    // parsed instant does not depend on when parsing happens), which is exactly why
    // it's safe to memoize by raw string. These tests prove repeated/varied calls
    // through the memoized path return identical results to a fresh, uncached parse,
    // including the nil (unparseable) case, and that `now`-variance still works
    // correctly for other call sites that DO thread `now` through (this parse itself
    // just doesn't use it).

    func testParseISO8601MemoizationReturnsIdenticalResultOnRepeatedCalls() {
        let raw = "2026-03-14T09:00:00.397911+00:00"
        let first = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        let second = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        let third = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    func testParseISO8601MemoizationHandlesVariedInputsIndependently() {
        let rawA = "2026-03-14T09:00:00Z"
        let rawB = "2026-06-01T18:30:00.500000+02:00"

        let a1 = UsageResetText.resetDate(kind: "5h", source: .claude, raw: rawA)
        let b1 = UsageResetText.resetDate(kind: "5h", source: .claude, raw: rawB)
        let a2 = UsageResetText.resetDate(kind: "5h", source: .claude, raw: rawA)
        let b2 = UsageResetText.resetDate(kind: "5h", source: .claude, raw: rawB)

        XCTAssertNotNil(a1)
        XCTAssertNotNil(b1)
        XCTAssertEqual(a1, a2, "cache must not conflate distinct raw strings")
        XCTAssertEqual(b1, b2, "cache must not conflate distinct raw strings")
        XCTAssertNotEqual(a1, b1, "sanity: the two fixtures represent different instants")
    }

    func testParseISO8601MemoizationCachesNilResultForUnparseableInput() {
        // Contains "T" (passes the fast-reject) but is not valid ISO 8601, so it must
        // fall through to nil both on a fresh parse and on a repeated (cached) call —
        // a cached nil must not be mistaken for "not yet attempted" and re-attempted
        // forever, but it also must not accidentally resolve to some other cached date.
        let raw = "Totally not a date T but has one"
        let first = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        let second = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw)
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    func testParseISO8601MemoizationDoesNotAffectNowDependentRelativeParsing() {
        // `resetDate` dispatches ISO8601 first, then falls through to other parse
        // strategies (e.g. `parseRelativeReset`) that DO depend on `now`. Prove that
        // varying `now` for a non-ISO8601 (relative) raw string still yields different,
        // correct results — i.e. the ISO8601 memoization layer does not leak into or
        // short-circuit the now-dependent paths.
        let raw = "resets in 1h 30m"
        let nowA = Date(timeIntervalSince1970: 1_800_000_000)
        let nowB = nowA.addingTimeInterval(3600)

        let dateA = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw, now: nowA)
        let dateB = UsageResetText.resetDate(kind: "5h", source: .claude, raw: raw, now: nowB)

        XCTAssertNotNil(dateA)
        XCTAssertNotNil(dateB)
        XCTAssertEqual(dateA, nowA.addingTimeInterval(90 * 60))
        XCTAssertEqual(dateB, nowB.addingTimeInterval(90 * 60))
        XCTAssertNotEqual(dateA, dateB, "now-dependent relative parsing must still vary with now despite ISO8601 memoization")
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

    func testClaudeRelativeResetDateParsesHoursMinutesAndDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let fiveHour = UsageResetText.resetDate(kind: "5h", source: .claude, raw: "resets in 1h 30m", now: now)
        let weekly = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: "in 2d", now: now)

        XCTAssertNotNil(fiveHour)
        XCTAssertNotNil(weekly)
        XCTAssertEqual(fiveHour!.timeIntervalSince(now), 90 * 60, accuracy: 0.001)
        XCTAssertEqual(weekly!.timeIntervalSince(now), 2 * 24 * 60 * 60, accuracy: 0.001)
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

    // MARK: - Anchor stability

    /// A relative countdown resolves against `now`, so it names a different instant
    /// every call. `resetDate` must keep doing that — a countdown is exactly what a
    /// user wants displayed — while `resetAnchorDate` must refuse, because callers
    /// that key a cache or match an interval need an identity, not a moving target.
    func testRelativeResetIsDisplayableButNotAnAnchor() {
        let now = Date(timeIntervalSince1970: 1_788_130_000)
        let raw = "resets in 4h 28m"

        let displayed = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: raw, now: now)
        XCTAssertNotNil(displayed, "the UI countdown must keep working")
        XCTAssertEqual(displayed?.timeIntervalSince(now) ?? 0, 4 * 3600 + 28 * 60, accuracy: 60)

        XCTAssertNil(UsageResetText.resetAnchorDate(kind: "Wk", source: .claude,
                                                    raw: raw, now: now),
                     "a countdown cannot identify a window")
    }

    /// The live failure this guard exists for: polled a few minutes apart, a
    /// countdown produced anchors 130s apart — past the 120s tolerance that decides
    /// whether two readings describe the same window — so every poll wrote a fresh
    /// bootstrap cache key. Seven accumulated in 75 minutes.
    func testACountdownYieldsAMovingAnchorAcrossPolls() {
        let raw = "resets in 4h 28m"
        let first = Date(timeIntervalSince1970: 1_788_130_000)
        let second = first.addingTimeInterval(130)

        let a = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: raw, now: first)
        let b = UsageResetText.resetDate(kind: "Wk", source: .claude, raw: raw, now: second)
        let drift = abs((b ?? .distantPast).timeIntervalSince(a ?? .distantFuture))
        XCTAssertEqual(drift, 130, accuracy: 5)
        XCTAssertGreaterThan(drift, 120, "drifts past the anchor-equality tolerance")

        XCTAssertNil(UsageResetText.resetAnchorDate(kind: "Wk", source: .claude,
                                                    raw: raw, now: first))
        XCTAssertNil(UsageResetText.resetAnchorDate(kind: "Wk", source: .claude,
                                                    raw: raw, now: second))
    }

    /// An absolute instant is unaffected — the OAuth path must keep calibrating.
    func testAnAbsoluteResetIsStillAnAnchor() {
        let now = Date(timeIntervalSince1970: 1_788_130_000)
        let raw = "resets 2026-09-06T11:59:59.814154+00:00"
        let anchor = UsageResetText.resetAnchorDate(kind: "Wk", source: .claude,
                                                    raw: raw, now: now)
        XCTAssertEqual(anchor?.timeIntervalSince1970 ?? 0, 1_788_695_999.814, accuracy: 1)
        XCTAssertEqual(anchor, UsageResetText.resetDate(kind: "Wk", source: .claude,
                                                        raw: raw, now: now))
        // Stable across polls, which is the whole point.
        XCTAssertEqual(anchor, UsageResetText.resetAnchorDate(
            kind: "Wk", source: .claude, raw: raw, now: now.addingTimeInterval(3600)))
    }
}
