import Foundation

enum AnalyticsSection: String, CaseIterable, Identifiable {
    case overview
    case economics

    var id: Self { self }

    var displayName: LocalizedStringResource {
        switch self {
        case .overview: return "Overview"
        case .economics: return "Economics"
        }
    }
}

enum EconomicsMetric: String, CaseIterable, Identifiable {
    case quotaPerHour
    case apiCostPerHour

    var id: Self { self }

    var displayName: LocalizedStringResource {
        switch self {
        case .quotaPerHour: return "Attributed quota / timed hour"
        case .apiCostPerHour: return "API $ / timed hour"
        }
    }
}

struct EconomicsConfigurationKey: Hashable, Identifiable, Sendable {
    let source: SessionSource
    let model: String
    let effort: String

    var id: String { "\(source.rawValue)|\(model)|\(effort)" }

    var modelDisplayName: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Unknown model") }
        return trimmed
            .replacingOccurrences(of: "openai/", with: "")
            .replacingOccurrences(of: "anthropic/", with: "")
            .replacingOccurrences(of: "google/", with: "")
    }

    var effortDisplayName: String {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Unspecified effort") }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

struct EconomicsObservation: Equatable, Sendable {
    let sessionID: String
    let configuration: EconomicsConfigurationKey
    /// nil is valid only for lifetime totals. Undated evidence is never used for
    /// quota attribution, trends, or timed rates.
    let observedAt: Date?
    let apiEquivalentUSD: Double?
    let weeklyQuotaPercentPoints: Double?
    /// Nearby timestamp evidence covered by each metric. nil means the transcript
    /// proves spend but cannot put that spend in the corresponding hourly rate.
    let apiTimedSeconds: TimeInterval?
    let quotaTimedSeconds: TimeInterval?
}

struct EconomicsPeriod: Equatable, Sendable {
    let start: Date?
    let end: Date

    func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        return date < end
    }

    func containsForTotals(_ date: Date?) -> Bool {
        guard let date else { return start == nil }
        return contains(date)
    }

    func contains(start intervalStart: Date, end intervalEnd: Date) -> Bool {
        intervalEnd > intervalStart && contains(intervalStart) && intervalEnd <= end
    }
}

enum EconomicsTiming {
    struct Interval: Equatable, Sendable {
        let start: Date
        let end: Date

        var seconds: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The existing Runway activity parsers use the same 30-minute continuity
    /// boundary. Longer gaps are human idle/unknown time, not model work.
    static let maximumNearbyGap: TimeInterval = 30 * 60

    /// Returns timing evidence keyed by the event's original array index. Exact
    /// request start/completion wins. Otherwise, a later usage event receives the
    /// gap from the preceding event only when both are nearby. The first event and
    /// events after an idle gap remain untimed instead of inventing a duration.
    static func intervals(for events: [TelemetryUsageEvent]) -> [Int: Interval] {
        let ordered = events.enumerated().compactMap { index, event -> (Int, TelemetryUsageEvent, Date)? in
            guard let end = event.completedAt ?? event.observedAt else { return nil }
            return (index, event, end)
        }.sorted { $0.2 < $1.2 }

        var result: [Int: Interval] = [:]
        var previousEnd: Date?
        var previousEvent: TelemetryUsageEvent?
        for (index, event, end) in ordered {
            if exactIntervalIsMeasured(event),
               let start = event.observedAt,
               let completed = event.completedAt,
               completed > start {
                result[index] = Interval(start: start, end: completed)
                previousEnd = completed
                previousEvent = event
                continue
            }
            if let previousEnd, let previousEvent,
               previousEvent.model == event.model,
               previousEvent.reasoningEffort == event.reasoningEffort {
                let gap = end.timeIntervalSince(previousEnd)
                if gap > 0, gap <= maximumNearbyGap {
                    result[index] = Interval(start: previousEnd, end: end)
                }
            }
            previousEnd = end
            previousEvent = event
        }
        return result
    }

    /// OpenCode v1 creates a step-finish row when the request is already done;
    /// its create-to-update delta is database-write time, not execution time.
    /// Synthetic v2 step-finish rows use the adapter's documented `-step-finish`
    /// record ID and carry a real request-start/completion pair.
    private static func exactIntervalIsMeasured(_ event: TelemetryUsageEvent) -> Bool {
        guard event.usageFamily == "opencode.step-finish.tokens" else { return true }
        return event.recordID?.hasSuffix("-step-finish") == true
    }
}

struct EconomicsEventSelection: Sendable {
    let allEvents: [TelemetryUsageEvent]
    let eventsInPeriod: [TelemetryUsageEvent]

    /// A lifetime aggregate may stand in only when the source emitted no request
    /// events. Otherwise dated and undated evidence must not be moved to a filter
    /// merely because its individual events did not land there.
    var canUseAggregateFallback: Bool { allEvents.isEmpty }

    static func select(
        from telemetry: SessionTelemetry,
        period: EconomicsPeriod
    ) -> EconomicsEventSelection {
        let allEvents = telemetry.usageEvents.filter {
            $0.ownership == .session && $0.topLineTokens > 0
        }
        let eventsInPeriod = allEvents.filter {
            period.containsForTotals($0.completedAt ?? $0.observedAt)
        }
        return EconomicsEventSelection(allEvents: allEvents, eventsInPeriod: eventsInPeriod)
    }
}

struct EconomicsConfigurationRow: Identifiable, Equatable, Sendable {
    let configuration: EconomicsConfigurationKey
    let sessionIDs: Set<String>
    let apiTimedSeconds: TimeInterval
    let quotaTimedSeconds: TimeInterval
    let apiEquivalentUSD: Double
    let weeklyQuotaPercentPoints: Double?
    let pricedObservationCount: Int
    let observationCount: Int
    let quotaObservationCount: Int
    let timedPricedObservationCount: Int
    let timedQuotaObservationCount: Int
    let apiCostPerHour: Double?
    let weeklyQuotaPercentPointsPerHour: Double?
    let previousAPICostPerHour: Double?
    let previousWeeklyQuotaPercentPointsPerHour: Double?

    var id: String { configuration.id }
    var sessions: Int { sessionIDs.count }

    var priceCoverage: Double {
        guard observationCount > 0 else { return 0 }
        return Double(pricedObservationCount) / Double(observationCount)
    }

    var quotaCoverage: Double {
        guard pricedObservationCount > 0 else { return 0 }
        return Double(quotaObservationCount) / Double(pricedObservationCount)
    }

    var timedPriceCoverage: Double {
        guard pricedObservationCount > 0 else { return 0 }
        return Double(timedPricedObservationCount) / Double(pricedObservationCount)
    }

    func timedSeconds(for metric: EconomicsMetric) -> TimeInterval {
        switch metric {
        case .quotaPerHour: return quotaTimedSeconds
        case .apiCostPerHour: return apiTimedSeconds
        }
    }

    func hasSufficientTimedSample(for metric: EconomicsMetric) -> Bool {
        timedSeconds(for: metric) >= EconomicsSnapshotBuilder.minimumTimedSecondsForRate
    }

    func currentValue(for metric: EconomicsMetric) -> Double? {
        switch metric {
        case .quotaPerHour: return weeklyQuotaPercentPointsPerHour
        case .apiCostPerHour: return apiCostPerHour
        }
    }

    func previousValue(for metric: EconomicsMetric) -> Double? {
        switch metric {
        case .quotaPerHour: return previousWeeklyQuotaPercentPointsPerHour
        case .apiCostPerHour: return previousAPICostPerHour
        }
    }
}

struct EconomicsTrendPoint: Identifiable, Equatable, Sendable {
    let weekStart: Date
    let apiCostPerHour: Double?
    let weeklyQuotaPercentPointsPerHour: Double?

    var id: Date { weekStart }

    func value(for metric: EconomicsMetric) -> Double? {
        switch metric {
        case .quotaPerHour: return weeklyQuotaPercentPointsPerHour
        case .apiCostPerHour: return apiCostPerHour
        }
    }
}

enum EconomicsRowOrdering {
    static func otherEfforts(
        for row: EconomicsConfigurationRow,
        in rows: [EconomicsConfigurationRow]
    ) -> [EconomicsConfigurationRow] {
        rows.filter {
            $0.configuration.source == row.configuration.source
                && $0.configuration.model == row.configuration.model
                && $0.configuration.effort != row.configuration.effort
        }
        .sorted { $0.configuration.effort < $1.configuration.effort }
    }

    static func sorted(
        _ rows: [EconomicsConfigurationRow],
        by metric: EconomicsMetric
    ) -> [EconomicsConfigurationRow] {
        rows.sorted { lhs, rhs in
            switch (lhs.currentValue(for: metric), rhs.currentValue(for: metric)) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.configuration.id < rhs.configuration.id
            }
        }
    }
}

struct EconomicsCoverage: Equatable, Sendable {
    let analyzedSessions: Int
    let eligibleSessions: Int
    let pricedObservations: Int
    let totalObservations: Int
    let quotaObservations: Int

    var pricedFraction: Double {
        guard totalObservations > 0 else { return 0 }
        return Double(pricedObservations) / Double(totalObservations)
    }

    var quotaFraction: Double {
        guard pricedObservations > 0 else { return 0 }
        return Double(quotaObservations) / Double(pricedObservations)
    }
}

struct EconomicsSnapshot: Equatable, Sendable {
    let rows: [EconomicsConfigurationRow]
    let trendByConfiguration: [String: [EconomicsTrendPoint]]
    let totalAPIEquivalentUSD: Double
    let quotaPercentPointsBySource: [SessionSource: Double]
    let totalTimedSeconds: TimeInterval
    let coverage: EconomicsCoverage
    let lastUpdated: Date

    static let empty = EconomicsSnapshot(
        rows: [],
        trendByConfiguration: [:],
        totalAPIEquivalentUSD: 0,
        quotaPercentPointsBySource: [:],
        totalTimedSeconds: 0,
        coverage: EconomicsCoverage(
            analyzedSessions: 0,
            eligibleSessions: 0,
            pricedObservations: 0,
            totalObservations: 0,
            quotaObservations: 0
        ),
        lastUpdated: Date()
    )
}

struct EconomicsAnalysisProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    static let empty = EconomicsAnalysisProgress(completed: 0, total: 0)

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

enum EconomicsAnalysisPhase: Equatable, Sendable {
    case idle
    case analyzing
    case ready
    case unavailable
}

/// Lossless transcript-derived evidence stored by the Economics index.
///
/// Pricing and weekly quota are deliberately not part of the cache identity:
/// token evidence can be repriced from the current manifest, while quota is
/// re-attributed from the current account/window calibration on every read.
struct EconomicsTelemetryIndexEntry: Sendable {
    let source: SessionSource
    let sessionID: String
    let revisionKey: String
    let parserVersion: Int
    let durableAccountHash: String?
    let referenceDate: Date
    let telemetry: SessionTelemetry
}

struct EconomicsTelemetryIndexKey: Hashable, Sendable {
    let source: SessionSource
    let sessionID: String

    var storageKey: String {
        EconomicsTelemetryIndexLookup.key(source: source, sessionID: sessionID)
    }
}

/// One indexed-session lookup. A nil telemetry payload means the session is
/// current in the index but has no usage event inside the requested date range.
/// Keeping that distinction prevents needless transcript backfills.
struct EconomicsTelemetryIndexLookup: Sendable {
    let source: SessionSource
    let sessionID: String
    let revisionKey: String
    let parserVersion: Int
    let durableAccountHash: String?
    let telemetry: SessionTelemetry?

    var key: String { Self.key(source: source, sessionID: sessionID) }

    static func key(source: SessionSource, sessionID: String) -> String {
        "\(source.rawValue)|\(sessionID)"
    }
}

enum EconomicsSnapshotBuilder {
    /// Smaller samples turn a few seconds of spend into a misleading hourly
    /// headline. Keep the value and coverage visible, but do not extrapolate a
    /// rate until the configuration has a useful timestamped sample.
    static let minimumTimedSecondsForRate: TimeInterval = 15 * 60

    private struct Aggregate {
        var sessions = Set<String>()
        var apiTimedSeconds: TimeInterval = 0
        var quotaTimedSeconds: TimeInterval = 0
        var apiEquivalentUSD = 0.0
        var timedAPIEquivalentUSD = 0.0
        var weeklyQuotaPercentPoints = 0.0
        var timedWeeklyQuotaPercentPoints = 0.0
        var hasQuota = false
        var pricedObservations = 0
        var totalObservations = 0
        var quotaObservations = 0
        var timedPricedObservations = 0
        var timedQuotaObservations = 0

        mutating func add(_ observation: EconomicsObservation) {
            sessions.insert(observation.sessionID)
            totalObservations += 1
            if let api = observation.apiEquivalentUSD, api.isFinite, api >= 0 {
                apiEquivalentUSD += api
                pricedObservations += 1
            }
            if let quota = observation.weeklyQuotaPercentPoints,
               quota.isFinite, quota >= 0 {
                weeklyQuotaPercentPoints += quota
                quotaObservations += 1
                hasQuota = true
            }
            if let seconds = observation.apiTimedSeconds,
               seconds.isFinite, seconds > 0,
               let api = observation.apiEquivalentUSD, api.isFinite, api >= 0 {
                apiTimedSeconds += seconds
                timedAPIEquivalentUSD += api
                timedPricedObservations += 1
            }
            if let seconds = observation.quotaTimedSeconds,
               seconds.isFinite, seconds > 0,
               let quota = observation.weeklyQuotaPercentPoints,
               quota.isFinite, quota >= 0 {
                quotaTimedSeconds += seconds
                timedWeeklyQuotaPercentPoints += quota
                timedQuotaObservations += 1
            }
        }

        /// Weekly trend rates use only intervals wholly contained by that week.
        /// Full-period rates still use every interval contained by the selected
        /// Analytics filter.
        mutating func addTimed(
            _ observation: EconomicsObservation,
            intervalStart: Date,
            intervalEnd: Date
        ) {
            guard let observedAt = observation.observedAt,
                  observedAt >= intervalStart, observedAt < intervalEnd else { return }
            if let seconds = observation.apiTimedSeconds,
               seconds.isFinite, seconds > 0,
               observedAt.addingTimeInterval(-seconds) >= intervalStart,
               let api = observation.apiEquivalentUSD, api.isFinite, api >= 0 {
                apiTimedSeconds += seconds
                timedAPIEquivalentUSD += api
                timedPricedObservations += 1
            }
            if let seconds = observation.quotaTimedSeconds,
               seconds.isFinite, seconds > 0,
               observedAt.addingTimeInterval(-seconds) >= intervalStart,
               let quota = observation.weeklyQuotaPercentPoints,
               quota.isFinite, quota >= 0 {
                quotaTimedSeconds += seconds
                timedWeeklyQuotaPercentPoints += quota
                timedQuotaObservations += 1
            }
        }

        var apiCostPerHour: Double? {
            guard apiTimedSeconds >= EconomicsSnapshotBuilder.minimumTimedSecondsForRate,
                  timedPricedObservations > 0 else { return nil }
            return timedAPIEquivalentUSD / (apiTimedSeconds / 3600)
        }

        var quotaPerHour: Double? {
            guard quotaTimedSeconds >= EconomicsSnapshotBuilder.minimumTimedSecondsForRate,
                  timedQuotaObservations > 0 else { return nil }
            return timedWeeklyQuotaPercentPoints / (quotaTimedSeconds / 3600)
        }
    }

    static func build(
        observations: [EconomicsObservation],
        current: EconomicsPeriod,
        previous: EconomicsPeriod?,
        now: Date,
        calendar: Calendar = .current,
        eligibleSessions: Int,
        analyzedSessions: Int
    ) -> EconomicsSnapshot {
        let currentObservations = observations.filter { current.containsForTotals($0.observedAt) }
        let previousObservations = previous.map { period in
            observations.filter { period.containsForTotals($0.observedAt) }
        } ?? []

        let currentByKey = aggregate(currentObservations)
        let previousByKey = aggregate(previousObservations)

        let rows = currentByKey.map { key, aggregate in
            let previousAggregate = previousByKey[key]
            return EconomicsConfigurationRow(
                configuration: key,
                sessionIDs: aggregate.sessions,
                apiTimedSeconds: aggregate.apiTimedSeconds,
                quotaTimedSeconds: aggregate.quotaTimedSeconds,
                apiEquivalentUSD: aggregate.apiEquivalentUSD,
                weeklyQuotaPercentPoints: aggregate.hasQuota ? aggregate.weeklyQuotaPercentPoints : nil,
                pricedObservationCount: aggregate.pricedObservations,
                observationCount: aggregate.totalObservations,
                quotaObservationCount: aggregate.quotaObservations,
                timedPricedObservationCount: aggregate.timedPricedObservations,
                timedQuotaObservationCount: aggregate.timedQuotaObservations,
                apiCostPerHour: aggregate.apiCostPerHour,
                weeklyQuotaPercentPointsPerHour: aggregate.quotaPerHour,
                previousAPICostPerHour: previousAggregate?.apiCostPerHour,
                previousWeeklyQuotaPercentPointsPerHour: previousAggregate?.quotaPerHour
            )
        }
        .sorted { $0.configuration.id < $1.configuration.id }

        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let trendStart = calendar.date(byAdding: .weekOfYear, value: -7, to: currentWeek) ?? currentWeek
        let trend = trendByConfiguration(
            observations: currentObservations.filter {
                guard let observedAt = $0.observedAt else { return false }
                return observedAt >= trendStart && observedAt < now
            },
            now: now,
            calendar: calendar
        )

        let total = currentObservations.reduce(into: Aggregate()) { $0.add($1) }
        let quotaPercentPointsBySource = currentObservations.reduce(into: [SessionSource: Double]()) {
            guard let quota = $1.weeklyQuotaPercentPoints, quota.isFinite, quota >= 0 else { return }
            $0[$1.configuration.source, default: 0] += quota
        }
        let coverage = EconomicsCoverage(
            analyzedSessions: analyzedSessions,
            eligibleSessions: eligibleSessions,
            pricedObservations: total.pricedObservations,
            totalObservations: total.totalObservations,
            quotaObservations: total.quotaObservations
        )

        return EconomicsSnapshot(
            rows: rows,
            trendByConfiguration: trend,
            totalAPIEquivalentUSD: total.apiEquivalentUSD,
            quotaPercentPointsBySource: quotaPercentPointsBySource,
            totalTimedSeconds: total.apiTimedSeconds,
            coverage: coverage,
            lastUpdated: now
        )
    }

    private static func aggregate(_ observations: [EconomicsObservation]) -> [EconomicsConfigurationKey: Aggregate] {
        var result: [EconomicsConfigurationKey: Aggregate] = [:]
        for observation in observations {
            result[observation.configuration, default: Aggregate()].add(observation)
        }
        return result
    }

    private static func trendByConfiguration(
        observations: [EconomicsObservation],
        now: Date,
        calendar: Calendar
    ) -> [String: [EconomicsTrendPoint]] {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let weeks = (0..<8).compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: offset - 7, to: currentWeek)
        }
        let grouped = Dictionary(grouping: observations, by: \.configuration)
        var result: [String: [EconomicsTrendPoint]] = [:]

        for (configuration, values) in grouped {
            result[configuration.id] = weeks.map { weekStart in
                let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? now
                var aggregate = Aggregate()
                for value in values {
                    aggregate.addTimed(value, intervalStart: weekStart, intervalEnd: weekEnd)
                }
                return EconomicsTrendPoint(
                    weekStart: weekStart,
                    apiCostPerHour: aggregate.apiCostPerHour,
                    weeklyQuotaPercentPointsPerHour: aggregate.quotaPerHour
                )
            }
        }
        return result
    }
}
