import Foundation

/// Builds telemetry from Kimi Code's `wire.jsonl` journal.
///
/// Kimi writes both per-turn `usage.record` rows and, in some sessions, a
/// session-level summary. The per-turn rows are authoritative when present;
/// the session row is a fallback only, otherwise the same work would be counted
/// twice. `inputCacheCreation` is kept in the shared five-minute cache-write
/// bucket because Kimi does not record a TTL-specific split.
struct KimiTelemetryAccumulator {
    private static let speed = "standard-normalized"

    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = KimiTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(provenance: .requestRecord)
    private var turnSlices = UsageSliceTable()
    private var sessionSlices = UsageSliceTable()
    private var turnEvents: [TelemetryUsageEvent] = []
    private var sessionEvents: [TelemetryUsageEvent] = []
    private var sawAnyRecord = false
    private var sawTurnUsage = false
    private var sawSessionUsage = false
    private var invalidTurnUsage = false
    private var invalidSessionUsage = false
    private var invalidUnscopedUsage = false

    mutating func consume(line: String, index: Int) {
        let isUsageCandidate = line.contains("usage.record")
        guard line.contains("config.update")
                || line.contains("llm.request")
                || isUsageCandidate else { return }
        guard let object = ClaudeRunwayLog.jsonObject(line),
              let type = object["type"] as? String else {
            // A candidate usage row that cannot be decoded is still evidence.
            // Skipping it would let a valid sibling row look complete.
            if isUsageCandidate {
                sawAnyRecord = true
                invalidUnscopedUsage = true
            }
            return
        }

        let observedAt = Self.date(object["time"])
        switch type {
        case "config.update", "llm.request":
            sawAnyRecord = true
            let provenance: TelemetryProvenance
            if type == "config.update" {
                provenance = .providerChangeRecord
            } else if timeline.initialConfiguration == nil {
                provenance = .inferredFirstObservation
            } else {
                provenance = .requestRecord
            }
            timeline.observe(model: Self.model(in: object),
                             effort: object["thinkingEffort"] as? String,
                             observedAt: observedAt,
                             anchorLine: index,
                             provenance: provenance)

        case "usage.record":
            sawAnyRecord = true
            let scope = object["usageScope"] as? String
            let isSessionScope = scope == "session"
            let isTurnScope = scope == "turn"
            // An unknown scope is not safe to attribute or deduplicate.
            guard isSessionScope || isTurnScope else {
                invalidUnscopedUsage = true
                return
            }

            guard let usage = object["usage"] as? [String: Any] else {
                if isSessionScope {
                    invalidSessionUsage = true
                } else {
                    invalidTurnUsage = true
                }
                return
            }

            guard let components = Self.components(in: usage) else {
                if isSessionScope {
                    invalidSessionUsage = true
                } else {
                    invalidTurnUsage = true
                }
                return
            }

            let model = Self.model(in: object) ?? timeline.model
            let effort = timeline.effort
            let fresh = components.fresh
            let cacheRead = components.cacheRead
            let cacheWrite = components.cacheWrite
            let output = components.output

            if isSessionScope {
                sawSessionUsage = true
                sessionSlices.addComponents(fresh: fresh,
                                            cacheRead: cacheRead,
                                            write5m: cacheWrite,
                                            write1h: 0,
                                            output: output,
                                            model: model,
                                            effort: effort,
                                            speed: Self.speed)
            } else {
                sawTurnUsage = true
                turnSlices.addComponents(fresh: fresh,
                                         cacheRead: cacheRead,
                                         write5m: cacheWrite,
                                         write1h: 0,
                                         output: output,
                                         model: model,
                                         effort: effort,
                                         speed: Self.speed)
            }

            guard (components.topLine ?? 0) > 0 else { return }
            let event = TelemetryUsageEvent(
                recordID: "usage.record:\(index)",
                observedAt: observedAt,
                anchorLine: index,
                usageFamily: isSessionScope ? "usage.record.session" : "usage.record.turn",
                ownership: .session,
                model: model,
                reasoningEffort: effort,
                speed: Self.speed,
                freshInputTokens: fresh,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: output,
                contextInputTokens: fresh + cacheRead + cacheWrite)
            if isSessionScope {
                sessionEvents.append(event)
            } else {
                turnEvents.append(event)
            }

        default:
            return
        }
    }

    func finish() -> SessionTelemetry {
        let useTurns = sawTurnUsage
        let invalidSelectedFamily = useTurns
            ? (invalidTurnUsage || invalidUnscopedUsage)
            : (invalidSessionUsage || invalidUnscopedUsage || (!sawSessionUsage && invalidTurnUsage))
        let slices = invalidSelectedFamily
            ? []
            : (useTurns ? turnSlices.ordered : sessionSlices.ordered)
        let events = invalidSelectedFamily
            ? []
            : (useTurns ? turnEvents : sessionEvents)
        let hasUsage = useTurns ? sawTurnUsage : sawSessionUsage
        let family = useTurns ? "usage.record.turn" : "usage.record.session"
        let summary: TelemetryUsageSummary? = sawAnyRecord
            ? TelemetryUsageSummary(
                topLineTokens: invalidSelectedFamily
                    ? 0
                    : (useTurns ? turnSlices.topLineTokens : sessionSlices.topLineTokens),
                hasComponentBreakdown: hasUsage && !invalidSelectedFamily,
                recordedTotalTokens: nil,
                usageFamilies: hasUsage || invalidSelectedFamily ? [family] : [],
                usageFamilyConflict: false,
                unavailableReason: invalidSelectedFamily
                    ? "Kimi usage.record components are incomplete or malformed."
                    : (hasUsage ? nil : "Kimi did not record usable usage components."))
            : nil

        return SessionTelemetry(source: .kimi,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: slices,
                                usageEvents: events,
                                usageSummary: summary,
                                costEstimate: nil)
    }

    private static func model(in object: [String: Any]) -> String? {
        if let alias = object["modelAlias"] as? String,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return alias.split(separator: "/").last.map(String.init) ?? alias
        }
        if let model = object["model"] as? String,
           !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        return nil
    }

    private struct Components {
        let fresh: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int

        var topLine: Int? {
            var total = 0
            for value in [fresh, cacheRead, cacheWrite, output] {
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { return nil }
                total = next
            }
            return total
        }
    }

    private static func components(in usage: [String: Any]) -> Components? {
        guard let fresh = count(usage["inputOther"]),
              let cacheRead = count(usage["inputCacheRead"]),
              let cacheWrite = count(usage["inputCacheCreation"]),
              let output = count(usage["output"]) else { return nil }
        let components = Components(fresh: fresh,
                                    cacheRead: cacheRead,
                                    cacheWrite: cacheWrite,
                                    output: output)
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

    private static func date(_ value: Any?) -> Date? {
        guard let milliseconds = ClaudeRunwayLog.double(value),
              milliseconds.isFinite,
              milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

struct KimiTelemetryProvider: SessionTelemetryProvider {
    private var accumulator = KimiTelemetryAccumulator()

    mutating func consume(line: String, index: Int) {
        accumulator.consume(line: line, index: index)
    }

    func finish() -> SessionTelemetryProviderResult {
        SessionTelemetryProviderResult(telemetry: accumulator.finish(), durableAccountHash: nil)
    }
}
