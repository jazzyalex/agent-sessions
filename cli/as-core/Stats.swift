import Foundation

// `stats <source> <file>`: token totals and API-equivalent cost of one session.
//
// Uses the same accumulators and cost calculator as the app's Session Info, so the numbers
// agree with it. Prices come from the price table bundled in the build (no network, and
// none of the app's cached overlay), so a very recent model may be reported as unpriced.
// Only sources whose descriptor declares token telemetry are supported; others answer
// with `"tokens": null` without reading the file.

/// The sources the app's telemetry engine dispatches to an accumulator.
private let telemetrySources: Set<SessionSource> = [.codex, .claude, .pi, .copilot]

private func stream(_ url: URL, _ consume: (String, Int) -> Void) -> Bool {
    var index = 0
    do {
        return try JSONLReader(url: url).forEachLineWhile { line in
            consume(line, index)
            index += 1
            return true
        }
    } catch {
        return false
    }
}

private func readTelemetry(source: SessionSource, url: URL) -> SessionTelemetry? {
    switch source {
    case .codex:
        var accumulator = CodexTelemetryAccumulator()
        guard stream(url, { accumulator.consume(line: $0, index: $1) }) else { return nil }
        return accumulator.finish()
    case .claude:
        var accumulator = ClaudeTelemetryAccumulator()
        guard stream(url, { accumulator.consume(line: $0, index: $1) }) else { return nil }
        return accumulator.finish()
    case .pi:
        var accumulator = PiTelemetryAccumulator()
        guard stream(url, { accumulator.consume(line: $0, index: $1) }) else { return nil }
        return accumulator.finish()
    case .copilot:
        var accumulator = CopilotTelemetryAccumulator()
        guard stream(url, { accumulator.consume(line: $0, index: $1) }) else { return nil }
        return accumulator.finish()
    default:
        return nil
    }
}

func runStats(_ options: Options) {
    guard options.positional.count == 2, let d = driver(named: options.positional[0]) else {
        fail("usage: as-core stats <source> <file>", code: 2)
    }
    let source = d.source
    let capabilities = SessionSourceDescriptorCatalog.descriptor(for: source).telemetry
    guard capabilities.tokens.isAvailable, telemetrySources.contains(source) else {
        emit(["type": "stats", "source": source.rawValue, "tokens": NSNull(), "reason": "unsupported"])
        return
    }
    let url = URL(fileURLWithPath: options.positional[1])
    guard let telemetry = readTelemetry(source: source, url: url) else {
        fail("could not read token usage from \(url.path)", code: 1)
    }
    guard let summary = telemetry.usageSummary else {
        emit(["type": "stats", "source": source.rawValue, "tokens": NSNull(), "reason": "no usage recorded"])
        return
    }

    // The breakdown regroups slices; the total is the provider-consistent summary figure.
    var input = 0, cacheRead = 0, cacheWrite = 0, output = 0, reasoning = 0
    for slice in telemetry.usageSlices {
        input += slice.freshInputTokens
        cacheRead += slice.cacheReadTokens
        cacheWrite += slice.cacheWrite5mTokens + slice.cacheWrite1hTokens
        output += slice.outputTokens
        reasoning += slice.reasoningOutputTokens
    }

    var costUSD: Any = NSNull()
    var unpricedModels: [String] = []
    var priceTableUpdated: Any = NSNull()
    // A legacy total-only transcript reports a count but can never be priced.
    if capabilities.cost.isAvailable, summary.hasComponentBreakdown {
        let table = RunwayPriceTable(loadBundled: true, readCache: false)
        let priced = TelemetryCostCalculator.price(events: telemetry.usageEvents,
                                                   fallbackSlices: telemetry.usageSlices,
                                                   priceTable: table)
        costUSD = orNull(priced.estimate.apiEquivalentUSD)
        unpricedModels = priced.estimate.unpricedModels
        priceTableUpdated = priced.estimate.priceTableUpdated
    }

    emit([
        "type": "stats",
        "source": source.rawValue,
        "tokens": [
            "total": summary.topLineTokens,
            "input": input,
            "cacheRead": cacheRead,
            "cacheWrite": cacheWrite,
            "output": output,
            "reasoning": reasoning,
            "hasBreakdown": summary.hasComponentBreakdown,
        ] as [String: Any],
        "costUSD": costUSD,
        "unpricedModels": unpricedModels,
        "priceTableUpdated": priceTableUpdated,
    ])
}
