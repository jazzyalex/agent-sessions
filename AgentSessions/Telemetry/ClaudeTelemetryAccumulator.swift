import Foundation

/// Builds `SessionTelemetry` from a Claude transcript in one pass.
///
/// Claude is the easier provider for tokens (usage is per-message and complete,
/// including the 5m/1h cache-write split and the fast-mode tier) and the harder one
/// for configuration: it never records a session-start setting, and its assistant
/// records include nested subagents, `<synthetic>` error placeholders, and records
/// that simply omit `effort`. Each is excluded explicitly below; without those rules
/// the timeline fills with changes that never happened.
struct ClaudeTelemetryAccumulator {

    /// Claude's placeholder model on error records. Never a real configuration and
    /// never carries tokens.
    private static let syntheticModel = "<synthetic>"

    /// Convenience for tests and small inputs. The engine drives `consume`/`finish`.
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = ClaudeTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(provenance: .assistantRecord,
                                                 initialProvenance: .inferredFirstObservation)
    private var slices = UsageSliceTable()
    private var events: [TelemetryUsageEvent] = []
    private var seenMessageIDs = Set<String>()
    private var sawAssistantRecord = false
    private var sawUsageRecord = false

    mutating func consume(line: String, index: Int) {
        guard let obj = ClaudeRunwayLog.jsonObject(line),
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any] else { return }
        sawAssistantRecord = true

        let rawModel = message["model"] as? String
        // An error placeholder contributes nothing at all — not a configuration
        // observation, not a change, not a token.
        guard rawModel != Self.syntheticModel else { return }

        let effort = obj["effort"] as? String
        // Nested subagents run on their own model. Their tokens are real spend, but
        // letting their model into the timeline rewrites the parent's configuration
        // history with a subagent's settings.
        let isSidechain = (obj["isSidechain"] as? Bool) ?? false
        if !isSidechain {
            timeline.observe(model: rawModel,
                             effort: effort,
                             observedAt: ClaudeRunwayLog.date(obj["timestamp"]),
                             anchorLine: index)
        }

        guard let usage = message["usage"] as? [String: Any] else { return }
        sawUsageRecord = true

        // Streaming writes the same message more than once. The id is consumed here
        // — before any token check — exactly as ClaudeRunwayTokenActivityParser does
        // it, so a zero-token record still spends its id and a later duplicate
        // cannot re-add the same tokens.
        if let messageID = message["id"] as? String {
            guard !seenMessageIDs.contains(messageID) else { return }
            seenMessageIDs.insert(messageID)
        }

        let writes = ClaudeRunwayLog.cacheCreation(usage: usage)
        let fresh = Int(ClaudeRunwayLog.double(usage["input_tokens"]) ?? 0)
        let cacheRead = Int(ClaudeRunwayLog.double(usage["cache_read_input_tokens"]) ?? 0)
        let output = Int(ClaudeRunwayLog.double(usage["output_tokens"]) ?? 0)
        let effectiveEffort = effort ?? timeline.effort
        let speed = RunwaySpeedTier(usageValue: usage["speed"]).rawValue

        slices.addComponents(fresh: fresh,
                         cacheRead: cacheRead,
                         write5m: Int(writes.fiveMinute),
                         write1h: Int(writes.oneHour),
                         output: output,
                         model: rawModel,
                         // A record that omits effort belongs to the effort still in
                         // force, not to a separate "unknown effort" slice. Note the
                         // carried value comes from the PARENT timeline, which
                         // excludes sidechains — so a subagent record with no effort
                         // of its own is attributed the parent's. That is the best
                         // available answer, not a measured one.
                         effort: effectiveEffort,
                         speed: speed)

        let write5m = Int(writes.fiveMinute)
        let write1h = Int(writes.oneHour)
        if fresh + cacheRead + write5m + write1h + output > 0 {
            events.append(TelemetryUsageEvent(
                recordID: (message["id"] as? String) ?? "message.usage:\(index)",
                observedAt: ClaudeRunwayLog.date(obj["timestamp"]),
                anchorLine: index,
                usageFamily: "message.usage",
                ownership: isSidechain ? .descendant : .session,
                model: rawModel,
                reasoningEffort: effectiveEffort,
                speed: speed,
                freshInputTokens: fresh,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: write5m,
                cacheWrite1hTokens: write1h,
                outputTokens: output,
                contextInputTokens: fresh + cacheRead + write5m + write1h
            ))
        }
    }

    func finish() -> SessionTelemetry {
        // nil means "this transcript has no assistant records at all". A file with
        // assistant records but no usage reports zero, which is a different fact.
        let summary: TelemetryUsageSummary? = sawAssistantRecord
            ? TelemetryUsageSummary(topLineTokens: slices.topLineTokens,
                                    hasComponentBreakdown: sawUsageRecord,
                                    recordedTotalTokens: nil,
                                    usageFamilies: ["message.usage"],
                                    usageFamilyConflict: false)
            : nil

        return SessionTelemetry(source: .claude,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: slices.ordered,
                                usageEvents: events,
                                usageSummary: summary,
                                costEstimate: nil)
    }
}
