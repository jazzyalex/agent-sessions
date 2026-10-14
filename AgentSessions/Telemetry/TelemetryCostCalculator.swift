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
                         priceTable: RunwayPriceTable,
                         cacheWriteTTLVerified: Bool = true,
                         recordsCacheWrites: Bool = true) -> TelemetryCostEstimate {
        estimate(slices: slices, snapshot: priceTable.snapshot(),
                 cacheWriteTTLVerified: cacheWriteTTLVerified,
                 recordsCacheWrites: recordsCacheWrites)
    }

    static func price(events: [TelemetryUsageEvent],
                      fallbackSlices: [TelemetryUsageSlice],
                      priceTable: RunwayPriceTable,
                      cacheWriteTTLVerified: Bool = true,
                      recordsCacheWrites: Bool = true) -> Result {
        price(events: events, fallbackSlices: fallbackSlices, snapshot: priceTable.snapshot(),
              cacheWriteTTLVerified: cacheWriteTTLVerified,
              recordsCacheWrites: recordsCacheWrites)
    }

    static func price(events: [TelemetryUsageEvent],
                      fallbackSlices: [TelemetryUsageSlice],
                      snapshot: RunwayPriceSnapshot,
                      cacheWriteTTLVerified: Bool = true,
                      recordsCacheWrites: Bool = true) -> Result {
        guard !events.isEmpty else {
            return Result(estimate: estimate(slices: fallbackSlices, snapshot: snapshot,
                                             cacheWriteTTLVerified: cacheWriteTTLVerified,
                                             recordsCacheWrites: recordsCacheWrites),
                          events: [])
        }

        var total = 0.0
        var unpricedModels: [String] = []
        var missingComponents: [String] = []
        var freeRouteModels: [String] = []
        var pricedEvents: [TelemetryUsageEvent] = []
        var hasSessionUsage = false
        for event in events {
            var eventUnpriced: [String] = []
            var eventMissing: [String] = []
            var eventFreeRoute: [String] = []
            let usd = price(event: event, snapshot: snapshot,
                            cacheWriteTTLVerified: cacheWriteTTLVerified,
                            recordsCacheWrites: recordsCacheWrites,
                            unpricedModels: &eventUnpriced,
                            missingComponents: &eventMissing,
                            freeRouteModels: &eventFreeRoute)
            if event.ownership == .session {
                hasSessionUsage = hasSessionUsage || event.topLineTokens > 0
                if let usd { total += usd }
                eventUnpriced.forEach { appendOnce($0, to: &unpricedModels) }
                eventMissing.forEach { appendOnce($0, to: &missingComponents) }
                eventFreeRoute.forEach { appendOnce($0, to: &freeRouteModels) }
            }
            pricedEvents.append(event.priced(usd: usd, revision: snapshot.revision,
                                             updated: snapshot.updatedDate,
                                             manifestFingerprint: snapshot.manifestFingerprint))
        }
        let available = unpricedModels.isEmpty && missingComponents.isEmpty
        return Result(
            estimate: TelemetryCostEstimate(
                apiEquivalentUSD: available && hasSessionUsage ? total : nil,
                unpricedModels: unpricedModels,
                missingPriceComponents: missingComponents,
                freeRouteModels: freeRouteModels,
                priceTableUpdated: snapshot.updatedDate,
                priceTableRevision: snapshot.revision,
                priceManifestFingerprint: snapshot.manifestFingerprint),
            events: pricedEvents)
    }

    private static func estimate(slices: [TelemetryUsageSlice],
                                 snapshot: RunwayPriceSnapshot,
                                 cacheWriteTTLVerified: Bool,
                                 recordsCacheWrites: Bool) -> TelemetryCostEstimate {
        var total = 0.0
        var unpricedModels: [String] = []
        var missingComponents: [String] = []
        var freeRouteModels: [String] = []

        for slice in slices {
            // A slice with no billable tokens is skipped entirely: an unpriceable
            // model that never actually ran must not sink a real session.
            guard !slice.isEmpty else { continue }

            let slug = slice.model ?? "(unknown)"
            guard let resolved = snapshot.resolvedPrice(forModel: slice.model) else {
                appendOnce(slug, to: &unpricedModels)
                continue
            }
            let price = resolved.price

            guard let tier = RunwaySpeedTier(rawValue: slice.speed) else {
                appendOnce("\(slug):\(slice.speed)", to: &missingComponents)
                continue
            }
            if price.longContext != nil {
                appendOnce("\(slug):contextInputTokens", to: &missingComponents)
                continue
            }
            guard let rates = price.rates(for: tier, inferenceGeo: slice.inferenceGeo) else {
                // Billing a fast record at standard would halve it. Refuse instead.
                appendOnce("\(slug):\(slice.inferenceGeo.map { "inferenceGeo:\($0)" } ?? tier.rawValue)", to: &missingComponents)
                continue
            }
            // Writes the format may have folded into input would be billed at the
            // input rate; only a row that bills writes at that rate is safe.
            if hidesCacheWrites(rates, recordsCacheWrites: recordsCacheWrites) {
                appendOnce("\(slug):cacheWrite", to: &missingComponents)
                continue
            }

            let writes = slice.cacheWrite5mTokens + slice.cacheWrite1hTokens
            // TTL is required evidence when the row prices the two writes differently.
            if !cacheWriteTTLVerified, writes > 0,
               let write5m = rates.cacheWritePerMTok, let write1h = rates.cacheWrite1hPerMTok,
               write5m != write1h {
                appendOnce("\(slug):cacheWriteTTL", to: &missingComponents)
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

            if resolved.viaFreeRoute { appendOnce(slug, to: &freeRouteModels) }
            total += sliceUSD / 1_000_000
        }

        // Any unpriceable contributing slice makes the whole figure unavailable.
        // Both arrays empty AND nil means there was simply nothing to price.
        let available = unpricedModels.isEmpty && missingComponents.isEmpty
        return TelemetryCostEstimate(
            apiEquivalentUSD: (available && slices.contains { !$0.isEmpty }) ? total : nil,
            unpricedModels: unpricedModels,
            missingPriceComponents: missingComponents,
            freeRouteModels: freeRouteModels,
            priceTableUpdated: snapshot.updatedDate,
            priceTableRevision: snapshot.revision,
            priceManifestFingerprint: snapshot.manifestFingerprint
        )
    }

    private static func price(event: TelemetryUsageEvent,
                              snapshot: RunwayPriceSnapshot,
                              cacheWriteTTLVerified: Bool,
                              recordsCacheWrites: Bool,
                              unpricedModels: inout [String],
                              missingComponents: inout [String],
                              freeRouteModels: inout [String]) -> Double? {
        guard event.topLineTokens > 0 else { return 0 }
        let slug = event.model ?? "(unknown)"
        guard let resolved = snapshot.resolvedPrice(forModel: event.model) else {
            appendOnce(slug, to: &unpricedModels)
            return nil
        }
        let price = resolved.price
        guard let tier = RunwaySpeedTier(rawValue: event.speed) else {
            appendOnce("\(slug):\(event.speed)", to: &missingComponents)
            return nil
        }
        if price.longContext != nil, event.contextInputTokens == nil {
            appendOnce("\(slug):contextInputTokens", to: &missingComponents)
            return nil
        }
        guard let rates = price.rates(for: tier,
                                      contextInputTokens: event.contextInputTokens.map(Double.init),
                                      inferenceGeo: event.inferenceGeo) else {
            appendOnce("\(slug):\(event.inferenceGeo.map { "inferenceGeo:\($0)" } ?? tier.rawValue)", to: &missingComponents)
            return nil
        }
        // Writes the format may have folded into input would be billed at the
        // input rate; only a row that bills writes at that rate is safe.
        if hidesCacheWrites(rates, recordsCacheWrites: recordsCacheWrites) {
            appendOnce("\(slug):cacheWrite", to: &missingComponents)
            return nil
        }
        let writes = event.cacheWrite5mTokens + event.cacheWrite1hTokens
        // TTL is required evidence when the row prices the two writes differently.
        if !cacheWriteTTLVerified, writes > 0,
           let write5m = rates.cacheWritePerMTok, let write1h = rates.cacheWrite1hPerMTok,
           write5m != write1h {
            appendOnce("\(slug):cacheWriteTTL", to: &missingComponents)
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
        if resolved.viaFreeRoute { appendOnce(slug, to: &freeRouteModels) }
        return rates.dollars(input: Double(event.freshInputTokens),
                             cachedInput: Double(event.cacheReadTokens),
                             output: Double(event.outputTokens),
                             cacheWrite5m: Double(event.cacheWrite5mTokens),
                             cacheWrite1h: Double(event.cacheWrite1hTokens))
    }

    /// A source without a cache-write count may carry writes inside its input count.
    /// That is safe only when the row has no separate write rate (the vendor bills
    /// writes as input) or its write rate equals the input rate.
    private static func hidesCacheWrites(_ rates: RunwayRateSet, recordsCacheWrites: Bool) -> Bool {
        guard !recordsCacheWrites, let write = rates.cacheWritePerMTok else { return false }
        return write != rates.inputPerMTok
    }

    /// One cause is reported once however many slices hit it — the list names what
    /// to fix, not how often it occurred.
    private static func appendOnce(_ value: String, to list: inout [String]) {
        guard !list.contains(value) else { return }
        list.append(value)
    }
}
