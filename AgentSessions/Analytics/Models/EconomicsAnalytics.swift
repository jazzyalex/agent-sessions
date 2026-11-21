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
        case .quotaPerHour: return "Quota / hour"
        case .apiCostPerHour: return "API $ / hour"
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
    let observedAt: Date
    let apiEquivalentUSD: Double?
    let weeklyQuotaPercentPoints: Double?
    let activeSeconds: TimeInterval
}

struct EconomicsPeriod: Equatable, Sendable {
    let start: Date?
    let end: Date

    func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        return date < end
    }
}

struct EconomicsConfigurationRow: Identifiable, Equatable, Sendable {
    let configuration: EconomicsConfigurationKey
    let sessions: Int
    let activeSeconds: TimeInterval
    let apiEquivalentUSD: Double
    let weeklyQuotaPercentPoints: Double?
    let pricedObservationCount: Int
    let observationCount: Int
    let quotaObservationCount: Int
    let apiCostPerHour: Double?
    let weeklyQuotaPercentPointsPerHour: Double?
    let previousAPICostPerHour: Double?
    let previousWeeklyQuotaPercentPointsPerHour: Double?

    var id: String { configuration.id }

    var priceCoverage: Double {
        guard observationCount > 0 else { return 0 }
        return Double(pricedObservationCount) / Double(observationCount)
    }

    var quotaCoverage: Double {
        guard pricedObservationCount > 0 else { return 0 }
        return Double(quotaObservationCount) / Double(pricedObservationCount)
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
    let totalWeeklyQuotaPercentPoints: Double?
    let totalActiveSeconds: TimeInterval
    let coverage: EconomicsCoverage
    let lastUpdated: Date

    static let empty = EconomicsSnapshot(
        rows: [],
        trendByConfiguration: [:],
        totalAPIEquivalentUSD: 0,
        totalWeeklyQuotaPercentPoints: nil,
        totalActiveSeconds: 0,
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
    private struct Aggregate {
        var sessions = Set<String>()
        var activeSeconds: TimeInterval = 0
        var apiEquivalentUSD = 0.0
        var weeklyQuotaPercentPoints = 0.0
        var hasQuota = false
        var pricedObservations = 0
        var totalObservations = 0
        var quotaObservations = 0

        mutating func add(_ observation: EconomicsObservation) {
            sessions.insert(observation.sessionID)
            activeSeconds += max(0, observation.activeSeconds)
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
        }

        var apiCostPerHour: Double? {
            guard activeSeconds > 0, pricedObservations > 0 else { return nil }
            return apiEquivalentUSD / (activeSeconds / 3600)
        }

        var quotaPerHour: Double? {
            guard activeSeconds > 0, hasQuota else { return nil }
            return weeklyQuotaPercentPoints / (activeSeconds / 3600)
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
        let currentObservations = observations.filter { current.contains($0.observedAt) }
        let previousObservations = previous.map { period in
            observations.filter { period.contains($0.observedAt) }
        } ?? []

        let currentByKey = aggregate(currentObservations)
        let previousByKey = aggregate(previousObservations)

        let rows = currentByKey.map { key, aggregate in
            let previousAggregate = previousByKey[key]
            return EconomicsConfigurationRow(
                configuration: key,
                sessions: aggregate.sessions.count,
                activeSeconds: aggregate.activeSeconds,
                apiEquivalentUSD: aggregate.apiEquivalentUSD,
                weeklyQuotaPercentPoints: aggregate.hasQuota ? aggregate.weeklyQuotaPercentPoints : nil,
                pricedObservationCount: aggregate.pricedObservations,
                observationCount: aggregate.totalObservations,
                quotaObservationCount: aggregate.quotaObservations,
                apiCostPerHour: aggregate.apiCostPerHour,
                weeklyQuotaPercentPointsPerHour: aggregate.quotaPerHour,
                previousAPICostPerHour: previousAggregate?.apiCostPerHour,
                previousWeeklyQuotaPercentPointsPerHour: previousAggregate?.quotaPerHour
            )
        }
        .sorted { lhs, rhs in
            let lq = lhs.weeklyQuotaPercentPointsPerHour ?? -1
            let rq = rhs.weeklyQuotaPercentPointsPerHour ?? -1
            if lq != rq { return lq > rq }
            let la = lhs.apiCostPerHour ?? -1
            let ra = rhs.apiCostPerHour ?? -1
            if la != ra { return la > ra }
            return lhs.configuration.id < rhs.configuration.id
        }

        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let trendStart = calendar.date(byAdding: .weekOfYear, value: -7, to: currentWeek) ?? currentWeek
        let trend = trendByConfiguration(
            observations: currentObservations.filter { $0.observedAt >= trendStart && $0.observedAt < now },
            now: now,
            calendar: calendar
        )

        let total = currentObservations.reduce(into: Aggregate()) { $0.add($1) }
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
            totalWeeklyQuotaPercentPoints: total.hasQuota ? total.weeklyQuotaPercentPoints : nil,
            totalActiveSeconds: total.activeSeconds,
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
                for value in values where value.observedAt >= weekStart && value.observedAt < weekEnd {
                    aggregate.add(value)
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
