import Foundation

/// Prices a session's usage slices at published API rates.
///
/// Deliberately NOT `RunwayRateSet.dollars(...)`: that method falls back
/// (1h → 5m → input) so the live runway keeps showing a burn rate rather than
/// blanking. A stored per-session figure has the opposite requirement — it must be
/// right or absent, because it will be compared against other sessions.
enum TelemetryCostCalculator {

    struct Result {
        let estimate: TelemetryCostEstimate
        let events: [TelemetryUsageEvent]
    }

    static func estimate(slices: [TelemetryUsageSlice],
                         priceTable: RunwayPriceTable) -> TelemetryCostEstimate {
        estimate(slices: slices, snapshot: priceTable.snapshot())
    }

    static func price(events: [TelemetryUsageEvent],
                      fallbackSlices: [TelemetryUsageSlice],
                      priceTable: RunwayPriceTable) -> Result {
        let snapshot = priceTable.snapshot()
        guard !events.isEmpty else {
            return Result(estimate: estimate(slices: fallbackSlices, snapshot: snapshot), events: [])
        }

        var total = 0.0
        var unpricedModels: [String] = []
        var missingComponents: [String] = []
        var pricedEvents: [TelemetryUsageEvent] = []
        var hasSessionUsage = false
        for event in events {
            var eventUnpriced: [String] = []
            var eventMissing: [String] = []
            let usd = price(event: event, snapshot: snapshot,
                            unpricedModels: &eventUnpriced,
                            missingComponents: &eventMissing)
            if event.ownership == .session {
                hasSessionUsage = hasSessionUsage || event.topLineTokens > 0
                if let usd { total += usd }
                eventUnpriced.forEach { appendOnce($0, to: &unpricedModels) }
                eventMissing.forEach { appendOnce($0, to: &missingComponents) }
            }
            pricedEvents.append(event.priced(usd: usd, revision: snapshot.revision,
                                             updated: snapshot.updatedDate))
        }
        let available = unpricedModels.isEmpty && missingComponents.isEmpty
        return Result(
            estimate: TelemetryCostEstimate(
                apiEquivalentUSD: available && hasSessionUsage ? total : nil,
                unpricedModels: unpricedModels,
                missingPriceComponents: missingComponents,
                priceTableUpdated: snapshot.updatedDate,
                priceTableRevision: snapshot.revision),
            events: pricedEvents)
    }

    private static func estimate(slices: [TelemetryUsageSlice],
                                 snapshot: RunwayPriceSnapshot) -> TelemetryCostEstimate {
        var total = 0.0
        var unpricedModels: [String] = []
        var missingComponents: [String] = []

        for slice in slices {
            // A slice with no billable tokens is skipped entirely: an unpriceable
            // model that never actually ran must not sink a real session.
            guard !slice.isEmpty else { continue }

            let slug = slice.model ?? "(unknown)"
            guard let price = snapshot.price(forModel: slice.model) else {
                appendOnce(slug, to: &unpricedModels)
                continue
            }

            let tier = RunwaySpeedTier(rawValue: slice.speed) ?? .standard
            guard let rates = price.rates(for: tier) else {
                // Billing a fast record at standard would halve it. Refuse instead.
                appendOnce("\(slug):\(tier.rawValue)", to: &missingComponents)
                continue
            }

            var sliceUSD = Double(slice.freshInputTokens) * rates.inputPerMTok
                + Double(slice.cacheReadTokens) * rates.cachedInputPerMTok
                + Double(slice.outputTokens) * rates.outputPerMTok

            if slice.cacheWrite5mTokens > 0 {
                guard let rate = rates.cacheWritePerMTok else {
                    appendOnce("\(slug):cacheWrite5m", to: &missingComponents)
                    continue
                }
                sliceUSD += Double(slice.cacheWrite5mTokens) * rate
            }
            if slice.cacheWrite1hTokens > 0 {
                guard let rate = rates.cacheWrite1hPerMTok else {
                    appendOnce("\(slug):cacheWrite1h", to: &missingComponents)
                    continue
                }
                sliceUSD += Double(slice.cacheWrite1hTokens) * rate
            }

            total += sliceUSD / 1_000_000
        }

        // Any unpriceable contributing slice makes the whole figure unavailable.
        // Both arrays empty AND nil means there was simply nothing to price.
        let available = unpricedModels.isEmpty && missingComponents.isEmpty
        return TelemetryCostEstimate(
            apiEquivalentUSD: (available && slices.contains { !$0.isEmpty }) ? total : nil,
            unpricedModels: unpricedModels,
            missingPriceComponents: missingComponents,
            priceTableUpdated: snapshot.updatedDate,
            priceTableRevision: snapshot.revision
        )
    }

    private static func price(event: TelemetryUsageEvent,
                              snapshot: RunwayPriceSnapshot,
                              unpricedModels: inout [String],
                              missingComponents: inout [String]) -> Double? {
        guard event.topLineTokens > 0 else { return 0 }
        let slug = event.model ?? "(unknown)"
        guard let price = snapshot.price(forModel: event.model) else {
            appendOnce(slug, to: &unpricedModels)
            return nil
        }
        let tier = RunwaySpeedTier(rawValue: event.speed) ?? .standard
        guard let rates = price.rates(for: tier,
                                      contextInputTokens: event.contextInputTokens.map(Double.init)) else {
            appendOnce("\(slug):\(tier.rawValue)", to: &missingComponents)
            return nil
        }
        if event.cacheWrite5mTokens > 0, rates.cacheWritePerMTok == nil {
            appendOnce("\(slug):cacheWrite5m", to: &missingComponents)
            return nil
        }
        if event.cacheWrite1hTokens > 0, rates.cacheWrite1hPerMTok == nil {
            appendOnce("\(slug):cacheWrite1h", to: &missingComponents)
            return nil
        }
        return rates.dollars(input: Double(event.freshInputTokens),
                             cachedInput: Double(event.cacheReadTokens),
                             output: Double(event.outputTokens),
                             cacheWrite5m: Double(event.cacheWrite5mTokens),
                             cacheWrite1h: Double(event.cacheWrite1hTokens))
    }

    /// One cause is reported once however many slices hit it — the list names what
    /// to fix, not how often it occurred.
    private static func appendOnce(_ value: String, to list: inout [String]) {
        guard !list.contains(value) else { return }
        list.append(value)
    }
}
