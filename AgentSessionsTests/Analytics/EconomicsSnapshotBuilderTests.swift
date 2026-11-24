import XCTest
@testable import AgentSessions

final class EconomicsSnapshotBuilderTests: XCTestCase {

    func testShortDurationDistinguishesZeroFromSubminuteActivity() {
        XCTAssertEqual(EconomicsAnalyticsView.shortDuration(0), "0m")
        XCTAssertEqual(EconomicsAnalyticsView.shortDuration(30), "<1m")
        XCTAssertEqual(EconomicsAnalyticsView.shortDuration(60), "1m")
    }

    func testCoverageCountShowsTheDenominatorAndPercentage() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(EconomicsAnalyticsView.coverageCount(count: 22, total: 100, locale: locale), "22 of 100 (22%)")
        XCTAssertEqual(EconomicsAnalyticsView.coverageCount(count: 0, total: 100, locale: locale), "0 of 100 (0%)")
        XCTAssertEqual(EconomicsAnalyticsView.coverageCount(count: 0, total: 0, locale: locale), "No records")
    }

    func testHeadlineDistinguishesUnpricedUsageFromPricedZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = EconomicsConfigurationKey(source: .claude, model: "opus", effort: "medium")
        func snapshot(price: Double?) -> EconomicsSnapshot {
            EconomicsSnapshotBuilder.build(
                observations: [observation("a", key, now, api: price, quota: nil, active: nil)],
                current: EconomicsPeriod(start: nil, end: now.addingTimeInterval(1)),
                previous: nil,
                now: now,
                calendar: calendar,
                eligibleSessions: 1,
                analyzedSessions: 1
            )
        }
        let unpriced = snapshot(price: nil)
        XCTAssertEqual(unpriced.coverage.totalObservations, 1)
        XCTAssertNil(unpriced.pricedAPIEquivalentUSD)
        XCTAssertEqual(snapshot(price: 0).pricedAPIEquivalentUSD, 0)
    }

    func testUnknownModelsDoNotOfferEffortComparison() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = EconomicsSnapshotBuilder.build(
            observations: ["", " "].flatMap { model in
                ["medium", "high"].map { effort in
                    let key = EconomicsConfigurationKey(source: .claude, model: model, effort: effort)
                    return observation(key.id, key, now, api: nil, quota: nil, active: nil)
                }
            },
            current: EconomicsPeriod(start: nil, end: now.addingTimeInterval(1)),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 4,
            analyzedSessions: 4
        ).rows
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertTrue(EconomicsRowOrdering.otherEfforts(for: row, in: rows).isEmpty)
        }
    }

    func testTranscriptAvailabilityRecognizesCompressedRolloutsAndMissingPaths() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let rollout = folder.appendingPathComponent("rollout-test.jsonl")
        let session = Session(id: "a", startTime: nil, endTime: nil, model: nil,
                              filePath: rollout.path, eventCount: 0, events: [])
        XCTAssertFalse(EconomicsTranscriptAvailability.hasStorage(for: session))
        try Data().write(to: CodexRolloutStorage.compressedSibling(of: rollout))
        XCTAssertTrue(EconomicsTranscriptAvailability.hasStorage(for: session))
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }()

    func testGroupsAgentModelEffortAndComparesPreviousPeriod() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let currentStart = try date("2026-11-13T12:00:00Z")
        let previousStart = try date("2026-11-06T12:00:00Z")
        let key = EconomicsConfigurationKey(
            source: .codex,
            model: "openai/gpt-6.2-sol",
            effort: "high"
        )
        let observations = [
            observation("a", key, try date("2026-11-18T12:00:00Z"),
                        api: 1, quota: 1.3, active: 1800),
            observation("b", key, try date("2026-11-19T12:00:00Z"),
                        api: 1, quota: 1.3, active: 1800),
            observation("c", key, try date("2026-11-10T12:00:00Z"),
                        api: 0.5, quota: nil, active: 3600)
        ]

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: observations,
            current: EconomicsPeriod(start: currentStart, end: now),
            previous: EconomicsPeriod(start: previousStart, end: currentStart),
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 3
        )

        let row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(row.configuration.modelDisplayName, "gpt-6.2-sol")
        XCTAssertEqual(row.configuration.effortDisplayName, "High")
        XCTAssertEqual(row.sessions, 2)
        XCTAssertEqual(row.sessionIDs, ["a", "b"])
        XCTAssertEqual(row.apiEquivalentUSD, 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.apiCostPerHour), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.weeklyQuotaPercentPointsPerHour), 2.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.previousAPICostPerHour), 0.5, accuracy: 0.0001)
        XCTAssertNil(row.previousWeeklyQuotaPercentPointsPerHour)
    }

    func testEffortComparisonAndContributingSessionsUseTheSelectedPeriod() throws {
        let start = try date("2026-11-13T12:00:00Z")
        let now = try date("2026-11-20T12:00:00Z")
        let inside = try date("2026-11-18T12:00:00Z")
        let outside = try date("2026-11-12T12:00:00Z")
        let medium = EconomicsConfigurationKey(source: .claude, model: "opus", effort: "medium")
        let high = EconomicsConfigurationKey(source: .claude, model: "opus", effort: "high")
        let low = EconomicsConfigurationKey(source: .claude, model: "opus", effort: "low")
        let otherModel = EconomicsConfigurationKey(source: .claude, model: "sonnet", effort: "high")
        let otherSource = EconomicsConfigurationKey(source: .codex, model: "opus", effort: "high")
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("shared", medium, inside, api: 1, quota: 1, active: 900),
                observation("shared", medium, inside, api: 1, quota: 1, active: 900),
                observation("shared", high, inside, api: 1, quota: 1, active: 1800),
                observation("high-only", high, inside, api: 1, quota: nil, active: 1800),
                observation("older", medium, outside, api: 1, quota: 1, active: 1800),
                observation("older", low, outside, api: 1, quota: 1, active: 1800),
                observation("other-model", otherModel, inside, api: 1, quota: 1, active: 1800),
                observation("other-source", otherSource, inside, api: 1, quota: 1, active: 1800)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 4,
            analyzedSessions: 4
        )
        let row = try XCTUnwrap(snapshot.rows.first { $0.configuration == medium })
        let comparisons = EconomicsRowOrdering.otherEfforts(for: row, in: snapshot.rows)
        XCTAssertEqual(comparisons.map(\.configuration), [high])
        XCTAssertEqual(row.sessionIDs, ["shared"])
        XCTAssertEqual(comparisons.first?.sessionIDs, ["shared", "high-only"])
        XCTAssertEqual(comparisons.first?.quotaTimedSeconds, 1800)
        XCTAssertEqual(comparisons.first?.apiTimedSeconds, 3600)
    }

    func testQuotaDoesNotBackfillWhenOnlyAPICostIsKnown() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let key = EconomicsConfigurationKey(source: .claude, model: "claude-opus", effort: "max")

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("a", key, try date("2026-11-19T12:00:00Z"),
                            api: 9, quota: nil, active: 3600)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 1,
            analyzedSessions: 1
        )

        XCTAssertEqual(snapshot.totalAPIEquivalentUSD, 9, accuracy: 0.0001)
        XCTAssertNil(snapshot.rows.first?.weeklyQuotaPercentPointsPerHour)
        XCTAssertEqual(snapshot.coverage.quotaFraction, 0)
    }

    func testRowsRemainSeparatedByEffort() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let high = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-sol", effort: "high")
        let xhigh = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-sol", effort: "xhigh")

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("a", high, try date("2026-11-18T12:00:00Z"),
                            api: 1, quota: 1.3, active: 3600),
                observation("b", xhigh, try date("2026-11-18T13:00:00Z"),
                            api: 2, quota: 2.1, active: 3600)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 2
        )

        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(Set(snapshot.rows.map(\.configuration.effort)), ["high", "xhigh"])
    }

    func testTrendExcludesObservationsOutsideCurrentPeriod() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-19T12:00:00Z")
        let key = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-sol", effort: "high")

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("current", key, try date("2026-11-20T10:00:00Z"),
                            api: 1, quota: 1, active: 3600),
                observation("historical", key, try date("2026-10-20T10:00:00Z"),
                            api: 99, quota: 99, active: 3600)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 1,
            analyzedSessions: 1
        )

        let points = try XCTUnwrap(snapshot.trendByConfiguration[key.id])
        XCTAssertEqual(points.compactMap(\.apiCostPerHour), [1])
        XCTAssertEqual(snapshot.totalAPIEquivalentUSD, 1, accuracy: 0.0001)
    }

    func testShortTimedSampleKeepsValueButDoesNotExtrapolateHourlyRate() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let key = EconomicsConfigurationKey(
            source: .claude,
            model: "claude-sonnet-5-5",
            effort: "medium"
        )

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("short", key, try date("2026-11-20T11:00:00Z"),
                            api: 0.14, quota: 0.003, active: 5)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 1,
            analyzedSessions: 1
        )

        let row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(row.apiEquivalentUSD, 0.14, accuracy: 0.0001)
        XCTAssertEqual(row.apiTimedSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(row.quotaTimedSeconds, 5, accuracy: 0.0001)
        XCTAssertNil(row.apiCostPerHour)
        XCTAssertNil(row.weeklyQuotaPercentPointsPerHour)
        XCTAssertFalse(row.hasSufficientTimedSample(for: .apiCostPerHour))
    }

    func testUntimedSpendIsExcludedFromHourlyRateNumerator() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let key = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-astra", effort: "xhigh")

        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("timed", key, try date("2026-11-20T10:00:00Z"),
                            api: 2, quota: 0.4, active: 3600),
                observation("untimed", key, try date("2026-11-20T11:00:00Z"),
                            api: 20, quota: 4, active: nil)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 2
        )

        let row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(row.apiEquivalentUSD, 22, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.apiCostPerHour), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.weeklyQuotaPercentPointsPerHour), 0.4, accuracy: 0.0001)
        XCTAssertEqual(row.timedPriceCoverage, 0.5, accuracy: 0.0001)
    }

    func testTimingRequiresTwoUsageTimestampsAndUsesTheirSpan() throws {
        let start = try date("2026-11-20T10:00:00Z")
        let end = try date("2026-11-20T10:05:00Z")
        let first = usageEvent(at: start, input: 100)
        let last = usageEvent(at: end, input: 200)

        XCTAssertTrue(EconomicsTiming.intervals(for: [first]).isEmpty)
        let intervals = EconomicsTiming.intervals(for: [last, first])
        XCTAssertEqual(try XCTUnwrap(intervals[0]).seconds, 300, accuracy: 0.0001)
    }

    func testTimingRejectsIdleGapsAndConfigurationChangesButUsesExactRequestDuration() throws {
        let start = try date("2026-11-20T10:00:00Z")
        let idle = try date("2026-11-20T10:31:00Z")
        let switched = try date("2026-11-20T10:35:00Z")
        let exactEnd = try date("2026-11-20T10:45:00Z")
        let events = [
            usageEvent(at: start, input: 100),
            usageEvent(at: idle, input: 200),
            usageEvent(at: switched, input: 300, model: "gpt-6.2-astra"),
            usageEvent(at: switched, input: 400, model: "gpt-6.2-astra", completedAt: exactEnd)
        ]

        let intervals = EconomicsTiming.intervals(for: events)
        XCTAssertNil(intervals[0])
        XCTAssertNil(intervals[1], "gaps above 30 minutes are idle, not model time")
        XCTAssertNil(intervals[2], "a gap crossing a configuration change is ambiguous")
        XCTAssertEqual(try XCTUnwrap(intervals[3]).seconds, 600, accuracy: 0.0001)
    }

    func testTimingTreatsOpenCodeV1FinishWriteAsPointButKeepsV2RequestInterval() throws {
        let start = try date("2026-11-20T10:00:00Z")
        let v1 = usageEvent(
            at: start,
            input: 100,
            completedAt: start.addingTimeInterval(0.001),
            recordID: "native-part-id",
            usageFamily: "opencode.step-finish.tokens"
        )
        let v2 = usageEvent(
            at: start,
            input: 100,
            completedAt: start.addingTimeInterval(6.5),
            recordID: "assistant-step-finish",
            usageFamily: "opencode.step-finish.tokens"
        )

        XCTAssertTrue(EconomicsTiming.intervals(for: [v1]).isEmpty,
                      "v1 part create-to-update time is a database write, not request execution")
        XCTAssertEqual(try XCTUnwrap(EconomicsTiming.intervals(for: [v2])[0]).seconds,
                       6.5, accuracy: 0.0001)
    }

    func testAPIAndQuotaRatesUseSeparateCoveredSeconds() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let key = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-astra", effort: "xhigh")
        let observations = [
            EconomicsObservation(
                sessionID: "covered",
                configuration: key,
                observedAt: try date("2026-11-20T10:00:00Z"),
                apiEquivalentUSD: 2,
                weeklyQuotaPercentPoints: 0.4,
                apiTimedSeconds: 3600,
                quotaTimedSeconds: 3600
            ),
            EconomicsObservation(
                sessionID: "api-only",
                configuration: key,
                observedAt: try date("2026-11-20T11:00:00Z"),
                apiEquivalentUSD: 20,
                weeklyQuotaPercentPoints: nil,
                apiTimedSeconds: 9 * 3600,
                quotaTimedSeconds: nil
            )
        ]
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: observations,
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 2
        )

        let row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(try XCTUnwrap(row.apiCostPerHour), 2.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.weeklyQuotaPercentPointsPerHour), 0.4, accuracy: 0.0001)
        XCTAssertEqual(row.apiTimedSeconds, 10 * 3600, accuracy: 0.0001)
        XCTAssertEqual(row.quotaTimedSeconds, 3600, accuracy: 0.0001)
    }

    func testQuotaTotalsRemainSeparatedByProvider() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let codex = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-astra", effort: "xhigh")
        let claude = EconomicsConfigurationKey(source: .claude, model: "claude-fable-5-2", effort: "high")
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("codex", codex, try date("2026-11-20T10:00:00Z"),
                            api: 2, quota: 30, active: 3600),
                observation("claude", claude, try date("2026-11-20T11:00:00Z"),
                            api: 3, quota: 20, active: 3600)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 2
        )

        XCTAssertEqual(snapshot.quotaPercentPointsBySource[.codex], 30)
        XCTAssertEqual(snapshot.quotaPercentPointsBySource[.claude], 20)
    }

    func testAllTimeIncludesUndatedSpendWithoutRatesQuotaOrTrend() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let key = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-sol", effort: "high")
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                EconomicsObservation(
                    sessionID: "undated",
                    configuration: key,
                    observedAt: nil,
                    apiEquivalentUSD: 7,
                    weeklyQuotaPercentPoints: nil,
                    apiTimedSeconds: nil,
                    quotaTimedSeconds: nil
                ),
                observation("dated", key, try date("2026-11-20T10:00:00Z"),
                            api: 2, quota: 1, active: 60)
            ],
            current: EconomicsPeriod(start: nil, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 2,
            analyzedSessions: 2
        )

        XCTAssertEqual(snapshot.totalAPIEquivalentUSD, 9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.rows.first?.apiEquivalentUSD), 9, accuracy: 0.0001)
        XCTAssertNil(snapshot.rows.first?.apiCostPerHour)
        XCTAssertEqual(snapshot.quotaPercentPointsBySource[.codex], 1)
        XCTAssertTrue(snapshot.trendByConfiguration[key.id]?.allSatisfy {
            $0.apiCostPerHour == nil && $0.weeklyQuotaPercentPointsPerHour == nil
        } == true)
    }

    func testTrendRejectsTimedIntervalCrossingWeekBoundary() throws {
        let now = try date("2026-11-18T12:00:00Z")
        let weekStart = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: now)?.start)
        let key = EconomicsConfigurationKey(source: .codex, model: "gpt-6.2-sol", effort: "high")
        let crossingEnd = weekStart.addingTimeInterval(60)
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("crossing", key, crossingEnd, api: 10, quota: 2, active: 20 * 60)
            ],
            current: EconomicsPeriod(start: weekStart.addingTimeInterval(-3600), end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 1,
            analyzedSessions: 1
        )

        let point = try XCTUnwrap(snapshot.trendByConfiguration[key.id]?.first {
            $0.weekStart == weekStart
        })
        XCTAssertNil(point.apiCostPerHour)
        XCTAssertNil(point.weeklyQuotaPercentPointsPerHour)
    }

    func testRowsSortBySelectedMetricWithUnavailableValuesLast() throws {
        let now = try date("2026-11-20T12:00:00Z")
        let start = try date("2026-11-13T12:00:00Z")
        let apiLeader = EconomicsConfigurationKey(source: .codex, model: "api-leader", effort: "high")
        let quotaLeader = EconomicsConfigurationKey(source: .codex, model: "quota-leader", effort: "high")
        let unavailable = EconomicsConfigurationKey(source: .codex, model: "unavailable", effort: "high")
        let snapshot = EconomicsSnapshotBuilder.build(
            observations: [
                observation("api", apiLeader, try date("2026-11-20T09:00:00Z"),
                            api: 10, quota: 1, active: 3600),
                observation("quota", quotaLeader, try date("2026-11-20T10:00:00Z"),
                            api: 2, quota: 5, active: 3600),
                observation("none", unavailable, try date("2026-11-20T11:00:00Z"),
                            api: 100, quota: 100, active: 5)
            ],
            current: EconomicsPeriod(start: start, end: now),
            previous: nil,
            now: now,
            calendar: calendar,
            eligibleSessions: 3,
            analyzedSessions: 3
        )

        XCTAssertEqual(EconomicsRowOrdering.sorted(snapshot.rows, by: .apiCostPerHour).map(\.configuration.model),
                       ["api-leader", "quota-leader", "unavailable"])
        XCTAssertEqual(EconomicsRowOrdering.sorted(snapshot.rows, by: .quotaPerHour).map(\.configuration.model),
                       ["quota-leader", "api-leader", "unavailable"])
    }

    func testDatedEvidenceOutsideFilterCannotFallBackToLifetimeCost() throws {
        let period = EconomicsPeriod(
            start: try date("2026-11-13T12:00:00Z"),
            end: try date("2026-11-20T12:00:00Z")
        )
        let historical = indexedTelemetry(events: [
            usageEvent(at: try date("2026-10-20T12:00:00Z"), input: 100)
        ])
        let historicalSelection = EconomicsEventSelection.select(from: historical, period: period)
        XCTAssertTrue(historicalSelection.eventsInPeriod.isEmpty)
        XCTAssertFalse(historicalSelection.canUseAggregateFallback,
                       "cold backfill must match the warm date index and keep lifetime spend out")

        let eventless = indexedTelemetry(events: [])
        XCTAssertTrue(EconomicsEventSelection.select(from: eventless, period: period).canUseAggregateFallback)

        let mixed = indexedTelemetry(events: [
            usageEvent(at: try date("2026-11-19T12:00:00Z"), input: 100),
            usageEvent(at: nil, input: 200)
        ])
        XCTAssertEqual(EconomicsEventSelection.select(
            from: mixed,
            period: EconomicsPeriod(start: nil, end: period.end)
        ).eventsInPeriod.count, 2, "All Time keeps undated spend as lifetime-only evidence")
        XCTAssertEqual(EconomicsEventSelection.select(from: mixed, period: period).eventsInPeriod.count, 1,
                       "dated filters must not assign undated spend a synthetic date")
    }

    func testPersistentTelemetryIndexUsesEventDatesWithoutDroppingRepriceEvidence() async throws {
        let made = try makeTestIndexDB()
        defer { made.cleanup() }
        let inside = try date("2026-11-19T12:00:00Z")
        let outside = try date("2026-10-19T12:00:00Z")
        let telemetry = indexedTelemetry(events: [
            usageEvent(at: outside, input: 100),
            usageEvent(at: inside, input: 200)
        ])
        try await made.db.upsertEconomicsTelemetry(EconomicsTelemetryIndexEntry(
            source: .codex,
            sessionID: "indexed",
            revisionKey: "file:1:2",
            parserVersion: SessionTelemetry.parserVersion,
            durableAccountHash: "account-hash",
            referenceDate: inside,
            telemetry: telemetry
        ))
        let key = EconomicsTelemetryIndexKey(source: .codex, sessionID: "indexed")

        let current = try await made.db.economicsTelemetryLookups(
            keys: [key],
            periodStart: date("2026-11-18T00:00:00Z"),
            periodEnd: date("2026-11-20T00:00:00Z")
        )
        let currentLookup = try XCTUnwrap(current.first)
        XCTAssertEqual(currentLookup.revisionKey, "file:1:2")
        XCTAssertEqual(currentLookup.durableAccountHash, "account-hash")
        XCTAssertEqual(currentLookup.telemetry?.usageEvents, telemetry.usageEvents)

        let empty = try await made.db.economicsTelemetryLookups(
            keys: [key],
            periodStart: date("2026-11-01T00:00:00Z"),
            periodEnd: date("2026-11-02T00:00:00Z")
        )
        XCTAssertEqual(empty.count, 1, "current index metadata must remain distinguishable from a miss")
        XCTAssertNil(empty.first?.telemetry, "out-of-range events must not decode the payload")
    }

    func testPersistentTelemetryIndexReplacementRemovesSupersededEventDates() async throws {
        let made = try makeTestIndexDB()
        defer { made.cleanup() }
        let oldDate = try date("2026-11-01T12:00:00Z")
        let newDate = try date("2026-11-19T12:00:00Z")
        let key = EconomicsTelemetryIndexKey(source: .codex, sessionID: "changing")

        try await made.db.upsertEconomicsTelemetry(EconomicsTelemetryIndexEntry(
            source: .codex,
            sessionID: "changing",
            revisionKey: "file:old",
            parserVersion: SessionTelemetry.parserVersion,
            durableAccountHash: nil,
            referenceDate: oldDate,
            telemetry: indexedTelemetry(events: [usageEvent(at: oldDate, input: 100)])
        ))
        try await made.db.upsertEconomicsTelemetry(EconomicsTelemetryIndexEntry(
            source: .codex,
            sessionID: "changing",
            revisionKey: "file:new",
            parserVersion: SessionTelemetry.parserVersion,
            durableAccountHash: nil,
            referenceDate: newDate,
            telemetry: indexedTelemetry(events: [usageEvent(at: newDate, input: 300)])
        ))

        let oldPeriod = try await made.db.economicsTelemetryLookups(
            keys: [key],
            periodStart: date("2026-11-01T00:00:00Z"),
            periodEnd: date("2026-11-02T00:00:00Z")
        )
        XCTAssertNil(oldPeriod.first?.telemetry)

        let newPeriod = try await made.db.economicsTelemetryLookups(
            keys: [key],
            periodStart: date("2026-11-19T00:00:00Z"),
            periodEnd: date("2026-11-20T00:00:00Z")
        )
        XCTAssertEqual(newPeriod.first?.revisionKey, "file:new")
        XCTAssertEqual(newPeriod.first?.telemetry?.usageEvents.first?.freshInputTokens, 300)
    }

    private func observation(
        _ sessionID: String,
        _ configuration: EconomicsConfigurationKey,
        _ date: Date?,
        api: Double?,
        quota: Double?,
        active: TimeInterval?
    ) -> EconomicsObservation {
        EconomicsObservation(
            sessionID: sessionID,
            configuration: configuration,
            observedAt: date,
            apiEquivalentUSD: api,
            weeklyQuotaPercentPoints: quota,
            apiTimedSeconds: active,
            quotaTimedSeconds: active
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func usageEvent(
        at date: Date?,
        input: Int,
        model: String = "gpt-6.2-sol",
        effort: String = "high",
        completedAt: Date? = nil,
        recordID: String = UUID().uuidString,
        usageFamily: String = "test"
    ) -> TelemetryUsageEvent {
        TelemetryUsageEvent(
            recordID: recordID,
            observedAt: date,
            anchorLine: 0,
            usageFamily: usageFamily,
            ownership: .session,
            model: model,
            reasoningEffort: effort,
            speed: "standard",
            freshInputTokens: input,
            cacheReadTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            outputTokens: 0,
            contextInputTokens: input,
            completedAt: completedAt
        )
    }

    private func indexedTelemetry(events: [TelemetryUsageEvent]) -> SessionTelemetry {
        SessionTelemetry(
            source: .codex,
            initialConfiguration: nil,
            currentConfiguration: nil,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: events,
            usageSummary: nil,
            costEstimate: nil
        )
    }
}
