import Foundation

/// Builds `SessionTelemetry` from a Pi transcript in one pass.
///
/// Pi is the most cooperative provider of the four: it emits explicit
/// `model_change` and `thinking_level_change` events (so the configuration
/// timeline is stated rather than inferred), and every assistant message carries a
/// complete per-call usage block. Nothing is cumulative, so usage is summed.
///
/// `usage.input` is FRESH input, with `cacheRead` counted separately — the Claude
/// convention, NOT the Codex one where `input_tokens` already includes cache reads.
/// Verified 2026-08-31 against real sessions in `~/.pi/agent/sessions`: every record
/// with a non-zero `cacheRead` satisfies `totalTokens == input + output + cacheRead`
/// exactly (e.g. 1201 + 758 + 1024 = 2983). Under the Codex reading that total would
/// have been 1959. Do not "fix" this by subtracting `cacheRead` from `input`; that
/// would undercount fresh input by the entire cache-read volume.
struct PiTelemetryAccumulator {

    /// Convenience for tests and small inputs. The engine drives `consume`/`finish`.
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = PiTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(provenance: .providerChangeRecord)
    private var slices = UsageSliceTable()
    private var sawAnyRecord = false
    private var sawUsageRecord = false

    mutating func consume(line: String, index: Int) {
        guard let obj = ClaudeRunwayLog.jsonObject(line),
              let type = obj["type"] as? String else { return }
        let observedAt = ClaudeRunwayLog.date(obj["timestamp"])

        switch type {
        case "model_change":
            sawAnyRecord = true
            timeline.observe(model: obj["modelId"] as? String, effort: nil,
                             observedAt: observedAt, anchorLine: index)
        case "thinking_level_change":
            sawAnyRecord = true
            // Pi's thinking level is its reasoning effort under another name.
            timeline.observe(model: nil, effort: obj["thinkingLevel"] as? String,
                             observedAt: observedAt, anchorLine: index)
        case "message":
            guard let message = obj["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant" else { return }
            sawAnyRecord = true
            let model = message["model"] as? String
            // A message states the model that actually served it, which is the right
            // attribution even when no model_change announced it.
            timeline.observe(model: model, effort: nil, observedAt: observedAt, anchorLine: index)

            guard let usage = message["usage"] as? [String: Any] else { return }
            sawUsageRecord = true
            func int(_ key: String) -> Int {
                Int(ClaudeRunwayLog.double(usage[key]) ?? 0)
            }
            slices.addComponents(fresh: int("input"),
                         cacheRead: int("cacheRead"),
                             // Pi reports one undifferentiated cache-write figure,
                             // like Codex; it goes in the 5-minute bucket, which is
                             // what a single such column has always meant.
                         write5m: int("cacheWrite"),
                         write1h: 0,
                         output: int("output"),
                         model: model,
                         effort: timeline.effort,
                             speed: RunwaySpeedTier.standard.rawValue)
        default:
            return
        }
    }

    func finish() -> SessionTelemetry {
        let summary: TelemetryUsageSummary? = sawAnyRecord
            ? TelemetryUsageSummary(topLineTokens: slices.topLineTokens,
                                    hasComponentBreakdown: sawUsageRecord,
                                    recordedTotalTokens: nil,
                                    usageFamilies: ["message.usage"],
                                    usageFamilyConflict: false)
            : nil

        return SessionTelemetry(source: .pi,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: slices.ordered,
                                usageSummary: summary,
                                costEstimate: nil)
    }
}
