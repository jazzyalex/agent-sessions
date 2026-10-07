import Foundation

/// Builds configuration telemetry from Grok assistant records.
///
/// Grok's audited transcript has model and reasoning-effort fields on assistant
/// records but no token counters. The provider therefore exposes the configuration
/// timeline while keeping token and cost output explicitly unavailable.
struct GrokTelemetryAccumulator {
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = GrokTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(
        provenance: .assistantRecord,
        initialProvenance: .inferredFirstObservation)
    private var sawAssistantRecord = false

    mutating func consume(line: String, index: Int) {
        guard line.contains("\"assistant\"") else { return }
        guard let object = ClaudeRunwayLog.jsonObject(line),
              object["type"] as? String == "assistant" else { return }
        sawAssistantRecord = true
        timeline.observe(model: object["model_id"] as? String,
                         effort: object["reasoning_effort"] as? String,
                         observedAt: nil,
                         anchorLine: index)
    }

    func finish() -> SessionTelemetry {
        let summary: TelemetryUsageSummary? = sawAssistantRecord
            ? TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: "Grok transcript records do not expose token counts.")
            : nil

        return SessionTelemetry(source: .grok,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: [],
                                usageEvents: [],
                                usageSummary: summary,
                                costEstimate: nil)
    }
}

struct GrokTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = GrokTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(), durableAccountHash: nil)
    }
}
