import Foundation

/// Builds token telemetry from Antigravity CLI planner responses.
///
/// Antigravity's CLI transcript records per-step `input_tokens`,
/// `cache_read_tokens`, and `output_tokens` on `PLANNER_RESPONSE`. The model
/// identifier is not present on those rows, so configuration remains explicitly
/// partial and the already-loaded Session row remains the current-model source.
struct AntigravityTelemetryAccumulator {
    private static let speed = "standard-normalized"

    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = AntigravityTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var slices = UsageSliceTable()
    private var events: [TelemetryUsageEvent] = []
    private var sawAnyRecord = false
    private var sawUsageRecord = false
    private var invalidUsageRecord = false

    mutating func consume(line: String, index: Int) {
        guard line.contains("PLANNER_RESPONSE") else { return }
        guard let object = ClaudeRunwayLog.jsonObject(line) else {
            // A candidate planner row that cannot be decoded is invalid
            // evidence, not an ignorable comment or metadata line.
            sawAnyRecord = true
            invalidUsageRecord = true
            return
        }
        guard object["type"] as? String == "PLANNER_RESPONSE" else { return }
        sawAnyRecord = true
        guard let components = Self.components(in: object) else {
            invalidUsageRecord = true
            return
        }
        sawUsageRecord = true

        let fresh = components.fresh
        let cacheRead = components.cacheRead
        let output = components.output
        slices.addComponents(fresh: fresh,
                             cacheRead: cacheRead,
                             write5m: 0,
                             write1h: 0,
                             output: output,
                             model: nil,
                             effort: nil,
                             speed: Self.speed)
        guard (components.topLine ?? 0) > 0 else { return }

        events.append(TelemetryUsageEvent(
            recordID: "PLANNER_RESPONSE:\(index)",
            observedAt: ClaudeRunwayLog.date(object["created_at"]),
            anchorLine: index,
            usageFamily: "PLANNER_RESPONSE",
            ownership: .session,
            model: nil,
            reasoningEffort: nil,
            speed: Self.speed,
            freshInputTokens: fresh,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            outputTokens: output,
            contextInputTokens: fresh + cacheRead))
    }

    func finish() -> SessionTelemetry {
        let summary: TelemetryUsageSummary? = sawAnyRecord
            ? TelemetryUsageSummary(
                topLineTokens: invalidUsageRecord ? 0 : slices.topLineTokens,
                hasComponentBreakdown: sawUsageRecord && !invalidUsageRecord,
                recordedTotalTokens: nil,
                usageFamilies: sawUsageRecord || invalidUsageRecord ? ["PLANNER_RESPONSE"] : [],
                usageFamilyConflict: false,
                unavailableReason: invalidUsageRecord
                    ? "Antigravity planner token components are incomplete or malformed."
                    : (sawUsageRecord ? nil : "Antigravity did not record planner token components."))
            : nil

        let usageSlices = invalidUsageRecord ? [] : slices.ordered
        let usageEvents = invalidUsageRecord ? [] : events

        return SessionTelemetry(source: .antigravity,
                                initialConfiguration: nil,
                                currentConfiguration: nil,
                                configurationChanges: [],
                                usageSlices: usageSlices,
                                usageEvents: usageEvents,
                                usageSummary: summary,
                                costEstimate: nil)
    }

    private struct Components {
        let fresh: Int
        let cacheRead: Int
        let output: Int

        var topLine: Int? {
            let (input, inputOverflow) = fresh.addingReportingOverflow(cacheRead)
            let (total, outputOverflow) = input.addingReportingOverflow(output)
            return inputOverflow || outputOverflow ? nil : total
        }
    }

    private static func components(in object: [String: Any]) -> Components? {
        guard let fresh = count(object["input_tokens"]),
              let cacheRead = count(object["cache_read_tokens"]),
              let output = count(object["output_tokens"]) else { return nil }
        let components = Components(fresh: fresh, cacheRead: cacheRead, output: output)
        guard components.topLine != nil else { return nil }
        return components
    }

    private static func count(_ value: Any?) -> Int? {
        guard let value = ClaudeRunwayLog.double(value),
              value.isFinite,
              value >= 0,
              value < Double(Int.max),
              value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
}

struct AntigravityTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = AntigravityTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(), durableAccountHash: nil)
    }
}
