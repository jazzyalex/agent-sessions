import Foundation

/// Builds provider-neutral telemetry from OpenClaw's v3 JSONL records.
///
/// OpenClaw records one complete usage object on assistant messages. Model and
/// thinking changes may also be stated by dedicated change records. The native
/// `cost` object is intentionally ignored here: its meaning depends on the
/// upstream provider and subscription, so the descriptor reports API-equivalent
/// cost as unavailable rather than presenting a misleading dollar estimate.
struct OpenClawTelemetryProvider: SessionTelemetryProvider {
    private static let usageFamily = "openclaw.message.usage"
    private static let speed = "standard-normalized"

    private struct Components: Equatable {
        let freshInput: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cacheWrite1h: Int
        let output: Int
        let reasoning: Int

        var cacheWrite5m: Int { cacheWrite - cacheWrite1h }

        var topLine: Int? {
            guard let input = Self.adding(freshInput, cacheRead),
                  let cached = Self.adding(input, cacheWrite) else { return nil }
            return Self.adding(cached, output)
        }

        var contextInput: Int? {
            guard let input = Self.adding(freshInput, cacheRead) else { return nil }
            return Self.adding(input, cacheWrite)
        }

        static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? nil : value
        }
    }

    private struct UsageRow: Equatable {
        let components: Components
        let recordedTotal: Int?
        let contextUsage: ContextUsage
        let cacheTelemetryState: CacheTelemetryState
        let requestedModel: String?
        let usageModel: String?
        let effort: String?
        let observedAt: Date?
    }

    private enum ContextUsage: Equatable {
        case absent(fallback: Int?)
        case available(promptTokens: Int, totalTokens: Int)
        case unavailable

        var inputTokens: Int? {
            switch self {
            case .absent(let fallback): return fallback
            case .available(let promptTokens, _): return promptTokens
            case .unavailable: return nil
            }
        }
    }

    private enum CacheTelemetryState: Equatable {
        case absent
        case available
        case unavailable
    }

    private struct Totals {
        var freshInput = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var reasoning = 0
        var recordedTotal = 0

        mutating func add(_ components: Components, recordedTotal: Int?) -> Bool {
            guard let freshInput = Components.adding(freshInput, components.freshInput),
                  let cacheRead = Components.adding(cacheRead, components.cacheRead),
                  let cacheWrite = Components.adding(cacheWrite, components.cacheWrite),
                  let output = Components.adding(output, components.output),
                  let reasoning = Components.adding(reasoning, components.reasoning) else {
                return false
            }
            let nextComponents = Components(freshInput: freshInput,
                                            cacheRead: cacheRead,
                                            cacheWrite: cacheWrite,
                                            cacheWrite1h: 0,
                                            output: output,
                                            reasoning: reasoning)
            guard nextComponents.topLine != nil else { return false }
            let nextRecordedTotal: Int
            if let recordedTotal {
                guard let value = Components.adding(self.recordedTotal, recordedTotal) else { return false }
                nextRecordedTotal = value
            } else {
                nextRecordedTotal = self.recordedTotal
            }
            self.recordedTotal = nextRecordedTotal
            self.freshInput = freshInput
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.output = output
            self.reasoning = reasoning
            return true
        }

        var components: Components {
            Components(freshInput: freshInput,
                       cacheRead: cacheRead,
                       cacheWrite: cacheWrite,
                       cacheWrite1h: 0,
                       output: output,
                       reasoning: reasoning)
        }
    }

    private enum IngestOutcome {
        case accepted
        case duplicate
        case rejected
        case ignoredAfterFailure
    }

    private var timeline = ConfigurationTimeline(
        provenance: .assistantRecord,
        initialProvenance: .inferredFirstObservation)
    private var slices = UsageSliceTable()
    private var events: [TelemetryUsageEvent] = []
    private var totals = Totals()
    private var seenUsageRows: [String: UsageRow] = [:]
    private var seenUsageEvidence: [String: String] = [:]
    private var sawUsageRecord = false
    private var allRowsHaveRecordedTotal = true
    private var sawAnyRecordedTotal = false
    private var unavailableReason: String?

    static func accumulate<S: Sequence>(lines: S) -> SessionTelemetry where S.Element == String {
        var provider = Self()
        for (index, line) in lines.enumerated() {
            provider.consume(line: line, index: index)
        }
        return provider.finish().telemetry
    }

    mutating func consume(line: String, index: Int) {
        guard !Task.isCancelled else { return }
        guard let object = ClaudeRunwayLog.jsonObject(line) else {
            if line.contains("\"usage\"") {
                sawUsageRecord = true
                unavailableReason = "OpenClaw usage is unavailable because a usage record is malformed."
            }
            return
        }

        let type = Self.normalizedType(object["type"])
        let message = object["message"] as? [String: Any]
        let observedAt = Self.date(object["timestamp"]) ?? Self.date(message?["timestamp"])

        switch type {
        case "modelchange":
            timeline.observe(model: Self.string(object, keys: ["modelId", "model_id", "model"]),
                             effort: nil,
                             observedAt: observedAt,
                             anchorLine: index,
                             provenance: .providerChangeRecord)

        case "thinkinglevelchange":
            timeline.observe(model: nil,
                             effort: Self.string(object, keys: ["thinkingLevel", "thinking_level", "level"]),
                             observedAt: observedAt,
                             anchorLine: index,
                             provenance: .providerChangeRecord)

        case "message":
            guard let message else { return }
            let role = Self.string(message, keys: ["role"])?.lowercased()
            guard role == "assistant" else { return }

            let model = Self.string(message, keys: ["model", "modelId", "model_id"])
            let effort = Self.string(message, keys: ["thinkingLevel", "thinking_level", "reasoningLevel", "reasoning_level"])
            let usageModel = Self.string(message, keys: ["responseModel", "response_model"]) ?? model
            guard let rawUsage = message["usage"] else {
                timeline.observe(model: model,
                                 effort: effort,
                                 observedAt: observedAt,
                                 anchorLine: index,
                                 provenance: .assistantRecord)
                return
            }
            sawUsageRecord = true
            guard let identifier = Self.string(object, keys: ["id"]) else {
                unavailableReason = "OpenClaw usage is unavailable because a usage record lacks its canonical top-level entry ID."
                return
            }
            guard let evidence = Self.canonicalUsageEvidence(rawUsage: rawUsage,
                                                              requestedModel: model,
                                                              usageModel: usageModel,
                                                              effort: effort,
                                                              observedAt: observedAt) else {
                unavailableReason = "OpenClaw usage is unavailable because a usage record cannot be canonicalized safely."
                return
            }
            switch registerUsageEvidence(identifier: identifier, evidence: evidence) {
            case .duplicate:
                return
            case .conflict:
                unavailableReason = "OpenClaw usage is unavailable because the same assistant record has conflicting raw usage evidence."
                return
            case .new:
                break
            }
            guard let usage = rawUsage as? [String: Any] else {
                unavailableReason = "OpenClaw usage is unavailable because an explicit usage value is malformed."
                return
            }
            let effectiveEffort = effort ?? timeline.currentConfiguration?.reasoningEffort
            switch ingest(usage: usage,
                          identifier: identifier,
                          requestedModel: model,
                          usageModel: usageModel,
                          effort: effort,
                          effectiveEffort: effectiveEffort,
                          observedAt: observedAt,
                          anchorLine: index) {
            case .accepted:
                timeline.observe(model: model,
                                 effort: effort,
                                 observedAt: observedAt,
                                 anchorLine: index,
                                 provenance: .assistantRecord)
            case .duplicate, .rejected:
                return
            case .ignoredAfterFailure:
                timeline.observe(model: model,
                                 effort: effort,
                                 observedAt: observedAt,
                                 anchorLine: index,
                                 provenance: .assistantRecord)
            }

        default:
            return
        }
    }

    func finish() -> SessionTelemetryProviderResult {
        var usageSlices = slices.ordered
        var usageEvents = events
        let summary: TelemetryUsageSummary?
        if let unavailableReason {
            usageSlices = []
            usageEvents = []
            summary = TelemetryUsageSummary(topLineTokens: 0,
                                            hasComponentBreakdown: false,
                                            recordedTotalTokens: nil,
                                            usageFamilies: sawUsageRecord ? [Self.usageFamily] : [],
                                            usageFamilyConflict: false,
                                            displayTotalTokens: nil,
                                            unavailableReason: unavailableReason)
        } else if sawUsageRecord, let topLineTokens = totals.components.topLine, topLineTokens > 0 {
            summary = TelemetryUsageSummary(
                topLineTokens: topLineTokens,
                hasComponentBreakdown: true,
                recordedTotalTokens: allRowsHaveRecordedTotal && sawAnyRecordedTotal
                    ? totals.recordedTotal
                    : nil,
                usageFamilies: [Self.usageFamily],
                usageFamilyConflict: false,
                displayTotalTokens: topLineTokens,
                unavailableReason: nil)
        } else {
            summary = nil
        }

        let telemetry = SessionTelemetry(
            source: .openclaw,
            initialConfiguration: timeline.initialConfiguration,
            currentConfiguration: timeline.currentConfiguration,
            configurationChanges: timeline.changes,
            usageSlices: usageSlices,
            usageEvents: usageEvents,
            usageSummary: summary,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderResult(telemetry: telemetry,
                                              durableAccountHash: nil)
    }

    private mutating func ingest(usage: [String: Any],
                                 identifier: String,
                                 requestedModel: String?,
                                 usageModel: String?,
                                 effort: String?,
                                 effectiveEffort: String?,
                                 observedAt: Date?,
                                 anchorLine: Int) -> IngestOutcome {
        guard let cacheTelemetryState = Self.cacheTelemetryState(in: usage) else {
            unavailableReason = "OpenClaw usage is unavailable because an explicit cache telemetry state is malformed."
            return .rejected
        }
        guard cacheTelemetryState != .unavailable else {
            unavailableReason = "OpenClaw usage is unavailable because OpenClaw did not report a trustworthy cache split."
            return .rejected
        }
        guard let components = Self.components(from: usage) else {
            unavailableReason = "OpenClaw usage is unavailable because a record lacks a valid component token breakdown."
            return .rejected
        }
        guard let contextUsage = Self.contextUsage(in: usage, fallback: components.contextInput) else {
            unavailableReason = "OpenClaw usage is unavailable because an explicit context usage value is malformed."
            return .rejected
        }

        let recordedTotal: Int?
        if Self.containsValue(in: usage, keys: ["totalTokens", "total_tokens"]) {
            guard let value = Self.integer(in: usage, keys: ["totalTokens", "total_tokens"]),
                  let topLine = components.topLine,
                  value == topLine else {
                unavailableReason = "OpenClaw usage is unavailable because a recorded total does not match its token components."
                return .rejected
            }
            recordedTotal = value
        } else {
            recordedTotal = nil
        }

        let row = UsageRow(components: components,
                           recordedTotal: recordedTotal,
                           contextUsage: contextUsage,
                           cacheTelemetryState: cacheTelemetryState,
                           requestedModel: requestedModel,
                           usageModel: usageModel,
                           effort: effort,
                           observedAt: observedAt)
        if let previous = seenUsageRows[identifier] {
            guard previous == row else {
                unavailableReason = "OpenClaw usage is unavailable because the same assistant record has conflicting usage values."
                return .rejected
            }
            return .duplicate
        }

        // Preserve structurally valid identity evidence even after usage has
        // failed closed. A later conflicting copy must not fabricate a model
        // change merely because aggregate accounting is already unavailable.
        seenUsageRows[identifier] = row
        if unavailableReason != nil {
            return .ignoredAfterFailure
        }

        guard totals.add(components, recordedTotal: recordedTotal) else {
            unavailableReason = "OpenClaw token totals exceed the supported integer range."
            return .rejected
        }
        if recordedTotal != nil {
            sawAnyRecordedTotal = true
        } else {
            allRowsHaveRecordedTotal = false
        }
        slices.addComponents(fresh: components.freshInput,
                             cacheRead: components.cacheRead,
                             write5m: components.cacheWrite5m,
                             write1h: components.cacheWrite1h,
                             output: components.output,
                             model: usageModel,
                             effort: effectiveEffort,
                             speed: Self.speed)
        guard components.topLine ?? 0 > 0 else { return .accepted }
        events.append(TelemetryUsageEvent(
            recordID: identifier,
            observedAt: observedAt,
            anchorLine: anchorLine,
            usageFamily: Self.usageFamily,
            ownership: .session,
            model: usageModel,
            reasoningEffort: effectiveEffort,
            speed: Self.speed,
            freshInputTokens: components.freshInput,
            cacheReadTokens: components.cacheRead,
            cacheWrite5mTokens: components.cacheWrite5m,
            cacheWrite1hTokens: components.cacheWrite1h,
            outputTokens: components.output,
            reasoningOutputTokens: components.reasoning,
            contextInputTokens: contextUsage.inputTokens))
        return .accepted
    }

    private enum RawEvidenceOutcome {
        case new
        case duplicate
        case conflict
    }

    private mutating func registerUsageEvidence(identifier: String,
                                                evidence: String) -> RawEvidenceOutcome {
        if let previous = seenUsageEvidence[identifier] {
            return previous == evidence ? .duplicate : .conflict
        }
        seenUsageEvidence[identifier] = evidence
        return .new
    }

    private static func canonicalUsageEvidence(rawUsage: Any,
                                               requestedModel: String?,
                                               usageModel: String?,
                                               effort: String?,
                                               observedAt: Date?) -> String? {
        let evidence: [String: Any] = [
            "usage": rawUsage,
            "requestedModel": requestedModel ?? NSNull(),
            "usageModel": usageModel ?? NSNull(),
            "effort": effort ?? NSNull(),
            "observedAt": observedAt.map { String($0.timeIntervalSince1970.bitPattern, radix: 16) } ?? NSNull()
        ]
        guard JSONSerialization.isValidJSONObject(evidence),
              let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func components(from usage: [String: Any]) -> Components? {
        guard let freshInput = integer(in: usage, keys: ["input", "input_tokens"]),
              let cacheRead = integer(in: usage, keys: ["cacheRead", "cache_read", "cache_read_tokens"]),
              let cacheWrite = integer(in: usage, keys: ["cacheWrite", "cache_write", "cache_write_tokens"]),
              let output = integer(in: usage, keys: ["output", "output_tokens"]) else { return nil }
        let cacheWrite1h: Int
        if containsValue(in: usage, keys: ["cacheWrite1h", "cache_write_1h", "cache_write_1h_tokens"]) {
            guard let value = integer(in: usage, keys: ["cacheWrite1h", "cache_write_1h", "cache_write_1h_tokens"]),
                  value <= cacheWrite else { return nil }
            cacheWrite1h = value
        } else {
            cacheWrite1h = 0
        }
        let reasoning: Int
        if containsValue(in: usage, keys: ["reasoning", "reasoningTokens", "reasoning_tokens"]) {
            guard let value = integer(in: usage, keys: ["reasoning", "reasoningTokens", "reasoning_tokens"]) else { return nil }
            reasoning = value
        } else {
            reasoning = 0
        }
        return Components(freshInput: freshInput,
                          cacheRead: cacheRead,
                          cacheWrite: cacheWrite,
                          cacheWrite1h: cacheWrite1h,
                          output: output,
                          reasoning: reasoning)
    }

    private static func contextUsage(in usage: [String: Any], fallback: Int?) -> ContextUsage? {
        guard let raw = usage["contextUsage"] else {
            return .absent(fallback: fallback)
        }
        guard let object = raw as? [String: Any],
              let state = string(object, keys: ["state"])?.lowercased() else { return nil }
        switch state {
        case "available":
            guard let promptTokens = integer(in: object, keys: ["promptTokens", "prompt_tokens"]),
                  let totalTokens = integer(in: object, keys: ["totalTokens", "total_tokens"]),
                  totalTokens >= promptTokens else { return nil }
            return .available(promptTokens: promptTokens, totalTokens: totalTokens)
        case "unavailable":
            return .unavailable
        default:
            return nil
        }
    }

    private static func cacheTelemetryState(in usage: [String: Any]) -> CacheTelemetryState? {
        guard let raw = usage["cacheTelemetry"] else { return .absent }
        guard let object = raw as? [String: Any],
              let state = string(object, keys: ["state"])?.lowercased() else { return nil }
        switch state {
        case "available": return .available
        case "unavailable": return .unavailable
        default: return nil
        }
    }

    private static func normalizedType(_ value: Any?) -> String {
        guard let value = value as? String else { return "" }
        return value.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func containsValue(in object: [String: Any], keys: [String]) -> Bool {
        keys.contains { object[$0] != nil }
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys where object[key] != nil {
            return nonNegativeInteger(object[key])
        }
        return nil
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number),
              integer >= 0 else { return nil }
        return integer
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: value)
        }
        guard !(value is Bool), let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        let seconds: Double
        if raw > 1e14 {
            seconds = raw / 1_000_000
        } else if raw > 1e11 {
            seconds = raw / 1_000
        } else {
            seconds = raw
        }
        return seconds.isFinite && seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }
}
