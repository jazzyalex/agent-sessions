import Foundation

// `stats <source> <file>`: token totals and API-equivalent cost of one session.
//
// Uses the same accumulators and cost calculator as the app's Session Info, so the numbers
// agree with it. Prices come from the price table bundled in the build (no network, and
// none of the app's cached overlay), so a very recent model may be reported as unpriced.
// Only sources whose descriptor declares token telemetry are supported; others answer
// with `"tokens": null` without reading the file.

/// The sources the app's telemetry engine dispatches to an accumulator.
let telemetrySources: Set<SessionSource> = [.codex, .claude, .pi, .copilot]

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

func readTelemetry(source: SessionSource, url: URL) -> SessionTelemetry? {
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

/// Token usage and API-rate cost of one session file.
struct UsageResult {
    var total = 0
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0
    var hasBreakdown = false
    var costUSD: Double?
    var unpricedModels: [String] = []
    var priceTableUpdated: String?
}

enum UsageOutcome {
    /// The source's files do not record token usage.
    case unsupported
    /// The file could not be read.
    case unreadable
    /// The file was read and holds no usage records.
    case none
    case ready(UsageResult)
}

func supportsUsage(_ source: SessionSource) -> Bool {
    SessionSourceDescriptorCatalog.descriptor(for: source).telemetry.tokens.isAvailable
        && telemetrySources.contains(source)
}

/// Streams the file through the app's accumulators and prices it with the given table.
func computeUsage(source: SessionSource, url: URL, table: RunwayPriceTable) -> UsageOutcome {
    guard supportsUsage(source) else { return .unsupported }
    let capabilities = SessionSourceDescriptorCatalog.descriptor(for: source).telemetry
    guard let telemetry = readTelemetry(source: source, url: url) else { return .unreadable }
    guard let summary = telemetry.usageSummary else { return .none }

    // The breakdown regroups slices; the total is the provider-consistent summary figure.
    var result = UsageResult(total: summary.topLineTokens, hasBreakdown: summary.hasComponentBreakdown)
    for slice in telemetry.usageSlices {
        result.input += slice.freshInputTokens
        result.cacheRead += slice.cacheReadTokens
        result.cacheWrite += slice.cacheWrite5mTokens + slice.cacheWrite1hTokens
        result.output += slice.outputTokens
        result.reasoning += slice.reasoningOutputTokens
    }
    // A legacy total-only transcript reports a count but can never be priced.
    if capabilities.cost.isAvailable, summary.hasComponentBreakdown {
        let priced = TelemetryCostCalculator.price(events: telemetry.usageEvents,
                                                   fallbackSlices: telemetry.usageSlices,
                                                   priceTable: table)
        result.costUSD = priced.estimate.apiEquivalentUSD
        result.unpricedModels = priced.estimate.unpricedModels
        result.priceTableUpdated = priced.estimate.priceTableUpdated
    }
    return .ready(result)
}

func runStats(_ options: Options) {
    guard options.positional.count == 2, let d = driver(named: options.positional[0]) else {
        fail("usage: as-core stats <source> <file>", code: 2)
    }
    let source = d.source
    let url = URL(fileURLWithPath: options.positional[1])
    let table = RunwayPriceTable(loadBundled: true, readCache: false)
    switch computeUsage(source: source, url: url, table: table) {
    case .unsupported:
        emit(["type": "stats", "source": source.rawValue, "tokens": NSNull(), "reason": "unsupported"])
    case .unreadable:
        fail("could not read token usage from \(url.path)", code: 1)
    case .none:
        emit(["type": "stats", "source": source.rawValue, "tokens": NSNull(), "reason": "no usage recorded"])
    case .ready(let r):
        emit([
            "type": "stats",
            "source": source.rawValue,
            "tokens": [
                "total": r.total, "input": r.input, "cacheRead": r.cacheRead,
                "cacheWrite": r.cacheWrite, "output": r.output, "reasoning": r.reasoning,
                "hasBreakdown": r.hasBreakdown,
            ] as [String: Any],
            "costUSD": orNull(r.costUSD),
            "unpricedModels": r.unpricedModels,
            "priceTableUpdated": orNull(r.priceTableUpdated),
        ])
    }
}
