import XCTest
@testable import AgentSessions

final class EconomicsSnapshotBuilderTests: XCTestCase {
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
        XCTAssertEqual(row.apiEquivalentUSD, 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.apiCostPerHour), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.weeklyQuotaPercentPointsPerHour), 2.6, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(row.previousAPICostPerHour), 0.5, accuracy: 0.0001)
        XCTAssertNil(row.previousWeeklyQuotaPercentPointsPerHour)
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
        XCTAssertNil(snapshot.totalWeeklyQuotaPercentPoints)
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
        _ date: Date,
        api: Double?,
        quota: Double?,
        active: TimeInterval
    ) -> EconomicsObservation {
        EconomicsObservation(
            sessionID: sessionID,
            configuration: configuration,
            observedAt: date,
            apiEquivalentUSD: api,
            weeklyQuotaPercentPoints: quota,
            activeSeconds: active
        )
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }

    private func usageEvent(at date: Date, input: Int) -> TelemetryUsageEvent {
        TelemetryUsageEvent(
            recordID: UUID().uuidString,
            observedAt: date,
            anchorLine: 0,
            usageFamily: "test",
            ownership: .session,
            model: "gpt-6.2-sol",
            reasoningEffort: "high",
            speed: "standard",
            freshInputTokens: input,
            cacheReadTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            outputTokens: 0,
            contextInputTokens: input
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
