import Foundation

/// How a session's newest burst prices in the $ lens.
enum OpenCodePricing: Equatable, Sendable {
    case priced(dollarsPerHour: Double)
    /// Every contributing request ran on a free route.
    case allFreeRoute
    /// At least one contributing request has no API price. Both lists come from the
    /// burst's own `TelemetryCostEstimate`; both may be empty when an event simply
    /// came back without a price.
    case unpriced(unknownModels: [String], missingComponents: [String])
}

struct OpenCodeSessionActivity: Equatable, Sendable {
    let tokensPerHour: Double
    let pricing: OpenCodePricing
    let newestCompletion: Date
}

/// What one OpenCode session row shows in the Quota Meter.
enum OpenCodeRateValue: Equatable, Sendable {
    case rate(Double, RunwayRateUnit)
    case free
    case unpriced(unknownModels: [String], missingComponents: [String])
    case unavailable
    case working
    case idle
}

/// Per-session tk/h and $/h for OpenCode, from the newest burst of completed
/// requests. These rules differ from Claude's on purpose: OpenCode records a
/// request's tokens only when it completes, so freshness is longer and there is
/// no provisional single-turn rate. Only the token weight is shared.
enum OpenCodeSessionRate {
    /// Longest pause between one request's completion and the next one's start.
    static let burstGap: TimeInterval = 30 * 60
    /// A shorter burst (one quick request with a large cached prompt) would read
    /// as millions of tk/h, so it shows "working" instead.
    static let minimumSpan: TimeInterval = 60
    /// A rate stays on screen this long after the newest completion.
    static let freshness: TimeInterval = 5 * 60
    /// Same weight as `ClaudeRunwayTokenActivityParser.weightedTokens`.
    static let cacheReadWeight = 0.10

    /// Contributing events of the newest burst, oldest first, or nil when there
    /// is no burst of at least `minimumSpan`.
    static func burst(_ events: [TelemetryUsageEvent]) -> [TelemetryUsageEvent]? {
        let contributing = events
            .filter { $0.topLineTokens > 0 && $0.completedAt != nil }
            .sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        guard let newest = contributing.last, let newestEnd = newest.completedAt else { return nil }
        var burst = [newest]
        for previous in contributing.dropLast().reversed() {
            guard let previousEnd = previous.completedAt else { continue }
            let nextStart = start(of: burst[0])
            guard nextStart.timeIntervalSince(previousEnd) <= burstGap else { break }
            burst.insert(previous, at: 0)
        }
        let span = newestEnd.timeIntervalSince(burst.map(start(of:)).min() ?? newestEnd)
        return span >= minimumSpan ? burst : nil
    }

    static func activity(burst: [TelemetryUsageEvent], prices: RunwayPriceSnapshot) -> OpenCodeSessionActivity {
        let newestCompletion = burst.compactMap(\.completedAt).max() ?? .distantPast
        let first = burst.map(start(of:)).min() ?? newestCompletion
        let span = max(newestCompletion.timeIntervalSince(first), minimumSpan)
        let weighted = burst.reduce(0.0) { total, event in
            total + Double(event.freshInputTokens + event.outputTokens
                           + event.cacheWrite5mTokens + event.cacheWrite1hTokens)
                + cacheReadWeight * Double(event.cacheReadTokens)
        }
        // Price exactly the burst, so a request outside it cannot change the result,
        // with OpenCode's own evidence flags, so the rate agrees with Session Info
        // (OpenCode records one cache-write count with no TTL).
        let capabilities = SessionSourceDescriptor.opencode.telemetry
        let priced = TelemetryCostCalculator.price(events: burst, fallbackSlices: [], snapshot: prices,
                                                   cacheWriteTTLVerified: capabilities.cacheWriteTTLVerified,
                                                   recordsCacheWrites: capabilities.recordsCacheWrites)
        var pricing = pricing(burstUSD: priced.events.map(\.apiEquivalentUSD), estimate: priced.estimate)
        if case .priced(let total) = pricing {
            let freeModels = Set(priced.estimate.freeRouteModels)
            let allFree = !burst.isEmpty && burst.allSatisfy { event in
                event.model.map(freeModels.contains) ?? false
            }
            pricing = allFree ? .allFreeRoute : .priced(dollarsPerHour: total / span * 3600)
        }
        return OpenCodeSessionActivity(tokensPerHour: weighted / span * 3600,
                                       pricing: pricing,
                                       newestCompletion: newestCompletion)
    }

    /// The burst's total USD as `.priced` (not yet per hour), or `.unpriced` with
    /// the estimate's reasons when any event lacks a price.
    static func pricing(burstUSD: [Double?], estimate: TelemetryCostEstimate) -> OpenCodePricing {
        let unknown = Array(Set(estimate.unpricedModels)).sorted()
        let missing = Array(Set(estimate.missingPriceComponents)).sorted()
        guard unknown.isEmpty, missing.isEmpty, !burstUSD.contains(where: { $0 == nil }) else {
            return .unpriced(unknownModels: unknown, missingComponents: missing)
        }
        return .priced(dollarsPerHour: burstUSD.compactMap { $0 }.reduce(0, +))
    }

    static func unit(for presentation: RunwayPresentation) -> RunwayRateUnit {
        presentation == .dollar ? .dollarsPerHour : .tokensPerHour
    }

    static func value(window: OpenCodeRecentWindow?, activity: OpenCodeSessionActivity?,
                      isWorking: Bool, unit: RunwayRateUnit, now: Date) -> OpenCodeRateValue {
        guard isWorking else { return .idle }
        if window == .unavailable { return .unavailable }
        guard let activity, now.timeIntervalSince(activity.newestCompletion) <= freshness else { return .working }
        guard unit == .dollarsPerHour else { return .rate(activity.tokensPerHour, .tokensPerHour) }
        switch activity.pricing {
        case .priced(let perHour): return .rate(perHour, .dollarsPerHour)
        case .allFreeRoute: return .free
        case .unpriced(let models, let components): return .unpriced(unknownModels: models, missingComponents: components)
        }
    }

    /// The request start used for spans: `observedAt`, else the completion.
    private static func start(of event: TelemetryUsageEvent) -> Date {
        event.observedAt ?? event.completedAt ?? .distantPast
    }
}
