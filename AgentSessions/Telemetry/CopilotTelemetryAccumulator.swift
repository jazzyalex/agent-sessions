import Foundation

/// Builds `SessionTelemetry` from a Copilot CLI transcript in one pass.
///
/// Copilot splits the two halves of telemetry further apart than any other
/// provider:
///
/// - **Configuration is excellent.** `session.model_change` states the new model,
///   the previous one, and the reasoning effort, so nothing has to be inferred.
/// - **Tokens are end-of-process only.** There is no per-turn usage. Everything
///   arrives in a `session.shutdown` summary, which means a session still running
///   reports no tokens at all, and tokens can never be attributed to the
///   configuration in force when they were spent. That is why the source declares
///   `tokens` and `cost` as `partial`.
///
/// `session.usage_checkpoint` looks like a token source and is not: it carries
/// `totalNanoAiu` and `totalPremiumRequests` — Copilot's billing units, not tokens.
struct CopilotTelemetryAccumulator {

    /// Copilot's placeholder for "model not yet resolved". Never a real model.
    private static let autoModel = "auto"

    /// The token keys a real `modelMetrics[*].usage` breakdown carries. At least one
    /// must be present for the object to count as a breakdown at all.
    private static let usageKeys = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]

    /// Convenience for tests and small inputs. The engine drives `consume`/`finish`.
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = CopilotTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(provenance: .providerChangeRecord)
    private var slices = UsageSliceTable()
    private var sawAnyRecord = false
    private var sawModelMetrics = false
    private var sawTokenDetails = false

    mutating func consume(line: String, index: Int) {
        guard let obj = ClaudeRunwayLog.jsonObject(line),
              let type = obj["type"] as? String,
              let data = obj["data"] as? [String: Any] else { return }
        let observedAt = ClaudeRunwayLog.date(obj["timestamp"])

        switch type {
        case "session.model_change":
            sawAnyRecord = true
            // `previousModel` is deliberately ignored: it is "auto" on the first
            // change, and reading it would invent a configuration the session never
            // actually ran on.
            let model = data["newModel"] as? String
            timeline.observe(model: model == Self.autoModel ? nil : model,
                             effort: data["reasoningEffort"] as? String,
                             observedAt: observedAt,
                             anchorLine: index)

        case "session.shutdown":
            sawAnyRecord = true
            // Each shutdown covers ONE process lifetime; a resumed session appends
            // another for the next process. They sum — taking only the last would
            // silently drop everything before the resume.
            consumeShutdown(data: data, observedAt: observedAt, anchorLine: index)

        default:
            return
        }
    }

    private mutating func consumeShutdown(data: [String: Any], observedAt: Date?, anchorLine: Int) {
        // `tokenDetails` and `modelMetrics[*].usage` describe the SAME tokens at
        // different resolutions. Per-model wins where it exists, because it can be
        // priced per model; the session totals are the fallback. Reading both from
        // one record would double that process's tokens.
        if let models = data["modelMetrics"] as? [String: Any] {
            var consumedAny = false
            for (modelID, raw) in models.sorted(by: { $0.key < $1.key }) {
                guard let entry = raw as? [String: Any],
                      let usage = entry["usage"] as? [String: Any],
                      // A `usage` object with none of the token keys is an empty
                      // shell, not a breakdown. Accepting it would mark this record
                      // consumed and suppress the tokenDetails fallback below,
                      // discarding the whole process's tokens.
                      Self.usageKeys.contains(where: { usage[$0] != nil }) else { continue }
                consumedAny = true
                func int(_ key: String) -> Int { Int(ClaudeRunwayLog.double(usage[key]) ?? 0) }
                slices.addComponents(fresh: int("inputTokens"),
                         cacheRead: int("cacheReadTokens"),
                         write5m: int("cacheWriteTokens"),
                         write1h: 0,
                         output: int("outputTokens"),
                         model: modelID,
                         effort: timeline.effort,
                         speed: RunwaySpeedTier.standard.rawValue)
            }
            if consumedAny {
                sawModelMetrics = true
                return
            }
        }

        guard let details = data["tokenDetails"] as? [String: Any] else { return }
        func count(_ key: String) -> Int {
            guard let entry = details[key] as? [String: Any] else { return 0 }
            return Int(ClaudeRunwayLog.double(entry["tokenCount"]) ?? 0)
        }
        sawTokenDetails = true
        slices.addComponents(fresh: count("input"),
                         cacheRead: count("cache_read"),
                         write5m: count("cache_write"),
                         write1h: 0,
                         output: count("output"),
                         // No per-model split available, so the process's own
                         // current model is the best attribution there is.
                         model: (data["currentModel"] as? String) ?? timeline.model,
                         effort: timeline.effort,
                         speed: RunwaySpeedTier.standard.rawValue)
    }

    func finish() -> SessionTelemetry {
        var families: [String] = []
        if sawModelMetrics { families.append("session.shutdown.modelMetrics") }
        if sawTokenDetails { families.append("session.shutdown.tokenDetails") }

        let summary: TelemetryUsageSummary? = sawAnyRecord
            ? TelemetryUsageSummary(topLineTokens: slices.topLineTokens,
                                    hasComponentBreakdown: !families.isEmpty,
                                    recordedTotalTokens: nil,
                                    usageFamilies: families,
                                    // Not a conflict: the two shapes come from
                                    // different processes in a resumed session, and
                                    // within one record only one of them is read.
                                    usageFamilyConflict: false)
            : nil

        return SessionTelemetry(source: .copilot,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: slices.ordered,
                                usageSummary: summary,
                                costEstimate: nil)
    }
}
