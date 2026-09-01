import Foundation

/// Prices a session's usage slices at published API rates.
///
/// Deliberately NOT `RunwayRateSet.dollars(...)`: that method falls back
/// (1h → 5m → input) so the live runway keeps showing a burn rate rather than
/// blanking. A stored per-session figure has the opposite requirement — it must be
/// right or absent, because it will be compared against other sessions.
enum TelemetryCostCalculator {

    static func estimate(slices: [TelemetryUsageSlice],
                         priceTable: RunwayPriceTable) -> TelemetryCostEstimate {
        var total = 0.0
        var unpricedModels: [String] = []
        var missingComponents: [String] = []

        for slice in slices {
            // A slice with no billable tokens is skipped entirely: an unpriceable
            // model that never actually ran must not sink a real session.
            guard !slice.isEmpty else { continue }

            let slug = slice.model ?? "(unknown)"
            guard let price = priceTable.price(forModel: slice.model) else {
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
            priceTableUpdated: priceTable.updatedDate
        )
    }

    /// One cause is reported once however many slices hit it — the list names what
    /// to fix, not how often it occurred.
    private static func appendOnce(_ value: String, to list: inout [String]) {
        guard !list.contains(value) else { return }
        list.append(value)
    }
}
