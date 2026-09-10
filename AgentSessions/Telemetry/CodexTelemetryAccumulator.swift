import Foundation

/// Builds `SessionTelemetry` from a Codex rollout in one pass.
///
/// Codex is the easier provider for configuration and the harder one for tokens:
/// `turn_context` states the effective model and effort for every turn, but the
/// token counters are CUMULATIVE and rewind mid-file when a session resumes, so
/// naive subtraction produces negative deltas. Both are handled here.
///
/// Driven line by line (`consume` then `finish`) so `SessionTelemetryEngine` can
/// stream a large rollout — the biggest observed locally is 256 MB — without ever
/// materializing it.
struct CodexTelemetryAccumulator {

    /// Convenience for tests and small inputs.
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry {
        var accumulator = CodexTelemetryAccumulator()
        for (index, line) in lines.enumerated() {
            accumulator.consume(line: line, index: index)
        }
        return accumulator.finish()
    }

    private var timeline = ConfigurationTimeline(provenance: .effectiveTurnContext)
    /// The two usage families accumulate into SEPARATE tables, and `finish()` picks
    /// the winner. They cannot share one table: which family is authoritative is a
    /// property of the whole file, and a single pass cannot know mid-stream whether
    /// a `token_count` record is still coming. Merging as we go double-counted every
    /// transcript whose `turn.completed` records preceded its `token_count` ones.
    private var cumulativeSlices = UsageSliceTable()
    private var turnSlices = UsageSliceTable()
    private var cumulativeEvents: [TelemetryUsageEvent] = []
    private var turnEvents: [TelemetryUsageEvent] = []
    private var cumulative = CumulativeCounters()
    private var turnCumulative = CumulativeCounters()
    private var recordedTotal = 0
    private var turnRecordedTotal = 0
    private var sawCumulativeMarker = false
    private var sawCumulativeFamily = false
    private var sawTurnCompletedFamily = false
    private var turnCompletedTokens = 0
    private var sawAmbiguousTurnUsage = false
    private var cumulativeHasComponents = false
    private var turnHasComponents = false

    mutating func consume(line: String, index: Int) {
        guard let obj = ClaudeRunwayLog.jsonObject(line) else { return }
        // Old rollouts omit the `payload` wrapper and write fields at the top level;
        // newer ones nest under `event_msg`/`payload`.
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let observedAt = ClaudeRunwayLog.date(obj["timestamp"]) ?? ClaudeRunwayLog.date(payload["timestamp"])

        let payloadType = (payload["type"] as? String)?.lowercased()

        if (obj["type"] as? String) == "turn_context" || payloadType == "turn_context" {
            timeline.observe(model: payload["model"] as? String,
                             effort: payload["effort"] as? String,
                             observedAt: observedAt,
                             anchorLine: index)
            return
        }

        if payloadType == "token_count" {
            sawCumulativeMarker = true
            guard let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else { return }
            // Authority requires a usable cumulative payload. A malformed
            // token_count marker must not suppress valid turn.completed usage.
            sawCumulativeFamily = true
            let sample = CumulativeCounters.Sample(usage: usage)
            // A decrease means the counters restarted (a resume). Close the epoch,
            // bank its final total, and treat this record as the new baseline.
            if cumulative.isReset(by: sample) {
                recordedTotal += cumulative.lastTotal
                cumulative = CumulativeCounters()
            }
            var delta = cumulative.advance(to: sample)
            if let lastUsage = info["last_token_usage"] as? [String: Any] {
                let request = CumulativeCounters.Sample(usage: lastUsage)
                let requestDelta = UsageDelta(sample: request)
                // `total_token_usage` remains the accounting authority. The
                // request-scoped record is used only when it exactly describes
                // this cumulative increment; otherwise tier selection would apply
                // one request's context size to an aggregate of several requests.
                if request.hasComponents,
                   requestDelta.fresh == delta.fresh,
                   requestDelta.cacheRead == delta.cacheRead,
                   requestDelta.cacheWrite == delta.cacheWrite,
                   requestDelta.output == delta.output {
                    delta = delta.withContextInput(request.input)
                } else {
                    delta = delta.withContextInput(nil)
                }
            } else {
                delta = delta.withContextInput(nil)
            }
            if delta.hasComponents { cumulativeHasComponents = true }
            cumulativeSlices.add(delta, model: timeline.model, effort: timeline.effort,
                                 speed: "standard-normalized")
            if delta.topLine > 0 {
                cumulativeEvents.append(event(delta: delta, payload: payload, observedAt: observedAt,
                                              anchorLine: index, family: "token_count"))
            }
            return
        }

        if payloadType == "turn.completed" || payloadType == "turn_completed" || payloadType == "turn-completed" {
            guard let usage = (payload["usage"] as? [String: Any])
                    ?? ((payload["data"] as? [String: Any])?["usage"] as? [String: Any]) else { return }
            sawTurnCompletedFamily = true
            let sample = CumulativeCounters.Sample(usage: usage)
            // Current Codex exec JSONL writes `turn.completed` at the top level
            // and its usage is cumulative. Historical rollout/event_msg records
            // use the same usage keys but do not persist a version or semantic
            // discriminator. Refuse to guess whether those wrapped records are
            // cumulative or incremental.
            guard obj["payload"] == nil else {
                sawAmbiguousTurnUsage = sawAmbiguousTurnUsage || sample.total > 0
                return
            }
            if turnCumulative.isReset(by: sample) {
                turnRecordedTotal += turnCumulative.lastTotal
                turnCumulative = CumulativeCounters()
            }
            let increment = turnCumulative.advance(to: sample).withContextInput(nil)
            turnCompletedTokens += increment.topLine
            // Always recorded, into its own table. Whether it counts is decided in
            // `finish()`, once the whole file has been seen.
            if increment.hasComponents { turnHasComponents = true }
            turnSlices.add(increment, model: timeline.model, effort: timeline.effort,
                           speed: "standard-normalized")
            if increment.topLine > 0 {
                turnEvents.append(event(delta: increment, payload: payload, observedAt: observedAt,
                                        anchorLine: index, family: "turn.completed"))
            }
        }
    }

    private func event(delta: UsageDelta,
                       payload: [String: Any],
                       observedAt: Date?,
                       anchorLine: Int,
                       family: String) -> TelemetryUsageEvent {
        TelemetryUsageEvent(
            recordID: (payload["id"] as? String)
                ?? ((payload["data"] as? [String: Any])?["id"] as? String)
                ?? "\(family):\(anchorLine)",
            observedAt: observedAt,
            anchorLine: anchorLine,
            usageFamily: family,
            ownership: .session,
            model: timeline.model,
            reasoningEffort: timeline.effort,
            // Codex rollout records do not preserve the actual API service tier.
            // This explicitly means "priced at the standard published rate", not
            // that a standard execution tier was observed.
            speed: "standard-normalized",
            freshInputTokens: delta.fresh,
            cacheReadTokens: delta.cacheRead,
            cacheWrite5mTokens: delta.cacheWrite,
            cacheWrite1hTokens: 0,
            outputTokens: delta.output,
            reasoningOutputTokens: delta.reasoning,
            contextInputTokens: delta.contextInput
        )
    }

    func finish() -> SessionTelemetry {
        var families: [String] = []
        if sawCumulativeMarker { families.append("token_count") }
        if sawTurnCompletedFamily { families.append("turn.completed") }

        let cumulativeBankedTotal = recordedTotal + cumulative.lastTotal
        let turnBankedTotal = turnRecordedTotal + turnCumulative.lastTotal

        // The authority decision, made once, with the whole file seen: cumulative
        // wins wherever it appears, so the two families are never summed.
        let winningSlices = sawCumulativeFamily ? cumulativeSlices : turnSlices
        let winningEvents = sawCumulativeFamily ? cumulativeEvents : turnEvents
        let hasComponents = sawCumulativeFamily ? cumulativeHasComponents : turnHasComponents

        let summary: TelemetryUsageSummary?
        if families.isEmpty {
            summary = nil
        } else {
            summary = TelemetryUsageSummary(
                topLineTokens: winningSlices.topLineTokens,
                hasComponentBreakdown: hasComponents,
                recordedTotalTokens: (sawCumulativeFamily ? cumulativeBankedTotal : turnBankedTotal) > 0
                    ? (sawCumulativeFamily ? cumulativeBankedTotal : turnBankedTotal)
                    : nil,
                usageFamilies: families,
                // Both families reporting positive tokens is a real conflict: the
                // totals come from the cumulative family alone.
                usageFamilyConflict: sawCumulativeFamily && sawTurnCompletedFamily
                    && (turnCompletedTokens > 0 || sawAmbiguousTurnUsage)
            )
        }

        return SessionTelemetry(source: .codex,
                                initialConfiguration: timeline.initialConfiguration,
                                currentConfiguration: timeline.currentConfiguration,
                                configurationChanges: timeline.changes,
                                usageSlices: winningSlices.ordered,
                                usageEvents: winningEvents,
                                usageSummary: summary,
                                costEstimate: nil)
    }
}

// MARK: - Cumulative counters

/// Tracks Codex's cumulative token counters and turns successive records into
/// per-record deltas, restarting when the counters rewind.
struct CumulativeCounters {
    struct Sample {
        let input: Int
        let cached: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int
        let total: Int
        /// False for legacy records carrying only `total_tokens` — those can report
        /// a session total but can never be priced.
        let hasComponents: Bool

        init(usage: [String: Any]) {
            func int(_ key: String) -> Int? {
                ClaudeRunwayLog.double(usage[key]).map { Int($0) }
            }
            let input = int("input_tokens")
            let output = int("output_tokens")
            self.input = input ?? 0
            self.cached = int("cached_input_tokens") ?? 0
            self.cacheWrite = int("cache_write_input_tokens") ?? 0
            self.output = output ?? 0
            self.reasoning = int("reasoning_output_tokens") ?? 0
            self.total = int("total_tokens") ?? ((input ?? 0) + (output ?? 0))
            self.hasComponents = input != nil || output != nil
        }
    }

    private var previous: Sample?
    private(set) var lastTotal = 0

    /// True when any counter went backwards, which only happens on a resume.
    func isReset(by sample: Sample) -> Bool {
        guard let previous else { return false }
        return sample.input < previous.input
            || sample.cached < previous.cached
            || sample.cacheWrite < previous.cacheWrite
            || sample.output < previous.output
            || sample.total < previous.total
    }

    mutating func advance(to sample: Sample) -> UsageDelta {
        let base = previous
        previous = sample
        lastTotal = sample.total
        guard let base else { return UsageDelta(sample: sample) }
        return UsageDelta.normalized(
            // Codex input includes both cache reads and cache writes. Normalize
            // the detail counters inside the input delta so top-line tokens remain
            // exactly input + output even if a malformed detail counter overshoots.
            input: max(0, sample.input - base.input),
            cacheRead: max(0, sample.cached - base.cached),
            cacheWrite: max(0, sample.cacheWrite - base.cacheWrite),
            output: max(0, sample.output - base.output),
            reasoning: max(0, sample.reasoning - base.reasoning),
            hasComponents: sample.hasComponents,
            contextInput: nil
        )
    }
}

/// One record's contribution to a usage slice.
struct UsageDelta {
    let fresh: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let hasComponents: Bool
    let contextInput: Int?

    init(fresh: Int, cacheRead: Int, cacheWrite: Int, output: Int, reasoning: Int,
         hasComponents: Bool, contextInput: Int? = nil) {
        self.fresh = fresh
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
        self.hasComponents = hasComponents
        self.contextInput = contextInput
    }

    /// A whole sample counted as one contribution — the first record of an epoch,
    /// or an incremental per-turn record.
    init(sample: CumulativeCounters.Sample) {
        self = Self.normalized(input: sample.input,
                               cacheRead: sample.cached,
                               cacheWrite: sample.cacheWrite,
                               output: sample.output,
                               reasoning: sample.reasoning,
                               hasComponents: sample.hasComponents,
                               contextInput: nil)
    }

    static func normalized(input: Int, cacheRead: Int, cacheWrite: Int,
                           output: Int, reasoning: Int, hasComponents: Bool,
                           contextInput: Int?) -> UsageDelta {
        let safeInput = max(0, input)
        let safeRead = min(safeInput, max(0, cacheRead))
        let safeWrite = min(safeInput - safeRead, max(0, cacheWrite))
        return UsageDelta(fresh: safeInput - safeRead - safeWrite,
                          cacheRead: safeRead,
                          cacheWrite: safeWrite,
                          output: max(0, output),
                          reasoning: max(0, reasoning),
                          hasComponents: hasComponents,
                          contextInput: contextInput)
    }

    func withContextInput(_ value: Int?) -> UsageDelta {
        UsageDelta(fresh: fresh, cacheRead: cacheRead, cacheWrite: cacheWrite,
                   output: output, reasoning: reasoning,
                   hasComponents: hasComponents, contextInput: value)
    }

    var topLine: Int { fresh + cacheRead + cacheWrite + output }
}

// MARK: - Slice table

/// Accumulates contributions into one slice per (model, effort, speed).
struct UsageSliceTable {
    private struct Key: Hashable {
        let model: String?
        let effort: String?
        let speed: String
    }

    private var totals: [Key: TelemetryUsageSlice] = [:]
    /// Preserves first-seen order so output is stable across runs.
    private var order: [Key] = []

    private mutating func slice(for key: Key) -> TelemetryUsageSlice {
        if let existing = totals[key] { return existing }
        order.append(key)
        return TelemetryUsageSlice(model: key.model, reasoningEffort: key.effort, speed: key.speed)
    }

    mutating func add(_ delta: UsageDelta, model: String?, effort: String?, speed: String) {
        let key = Key(model: model, effort: effort, speed: speed)
        var slice = slice(for: key)
        slice.freshInputTokens += delta.fresh
        slice.cacheReadTokens += delta.cacheRead
        slice.cacheWrite5mTokens += delta.cacheWrite
        slice.outputTokens += delta.output
        slice.reasoningOutputTokens += delta.reasoning
        totals[key] = slice
    }

    /// Adds a contribution whose components are already separated by the provider.
    /// Only Claude distinguishes cache-write TTLs; the others pass write1h: 0.
    mutating func addComponents(fresh: Int, cacheRead: Int, write5m: Int, write1h: Int, output: Int,
                            model: String?, effort: String?, speed: String) {
        let key = Key(model: model, effort: effort, speed: speed)
        var slice = slice(for: key)
        slice.freshInputTokens += fresh
        slice.cacheReadTokens += cacheRead
        slice.cacheWrite5mTokens += write5m
        slice.cacheWrite1hTokens += write1h
        slice.outputTokens += output
        totals[key] = slice
    }

    var ordered: [TelemetryUsageSlice] { order.compactMap { totals[$0] } }
    var topLineTokens: Int { totals.values.reduce(0) { $0 + $1.topLineTokens } }
    var isEmpty: Bool { totals.isEmpty }
}

// MARK: - Configuration timeline

/// Tracks model and effort independently, with carry-forward.
///
/// The rule both providers need: an ABSENT field is not an observation. Codex writes
/// context lines that omit effort, and 10,466 of 47,671 sampled Claude assistant
/// records carry no effort at all — treating absence as a value would emit a stream
/// of phantom "changed to nil" entries.
///
/// Initial configuration is the subset stated by the first configuration record.
/// A later first sighting cannot be backdated into that configuration, because doing
/// so invents a model/effort pair that no record observed. Field-level anchors and
/// provenance retain the evidence for each value that is actually present.
struct ConfigurationTimeline {
    /// Default provenance for observations and changes — what the record itself is.
    /// Individual observations may override this (Pi assistant-message fallback).
    private let provenance: TelemetryProvenance
    /// Provenance for the INITIAL configuration, which can differ: Codex states the
    /// effective settings for its first turn, whereas Claude's initial values are
    /// inferred from the first assistant record (and absent fields stay unknown).
    private let initialProvenance: TelemetryProvenance

    private(set) var model: String?
    private(set) var effort: String?
    private(set) var changes: [ConfigurationChange] = []

    private var firstObservedAt: Date?
    private var firstAnchorLine: Int?
    private struct FieldObservation {
        let value: String
        let observedAt: Date?
        let anchorLine: Int
        let provenance: TelemetryProvenance
    }
    private var initialModel: FieldObservation?
    private var initialEffort: FieldObservation?
    private var currentModel: FieldObservation?
    private var currentEffort: FieldObservation?
    private var lastObservedAt: Date?
    private var lastAnchorLine = 0
    private var lastProvenance: TelemetryProvenance?

    init(provenance: TelemetryProvenance, initialProvenance: TelemetryProvenance? = nil) {
        self.provenance = provenance
        self.initialProvenance = initialProvenance ?? provenance
    }

    mutating func observe(model newModel: String?, effort newEffort: String?, observedAt: Date?, anchorLine: Int,
                          provenance observationProvenance: TelemetryProvenance? = nil) {
        let cleanModel = Self.clean(newModel)
        let cleanEffort = Self.clean(newEffort)
        guard cleanModel != nil || cleanEffort != nil else { return }
        let observationProvenance = observationProvenance ?? provenance
        let isFirstObservation = firstAnchorLine == nil

        if isFirstObservation {
            firstAnchorLine = anchorLine
            firstObservedAt = observedAt
        }
        lastAnchorLine = anchorLine
        lastObservedAt = observedAt
        lastProvenance = observationProvenance

        if let cleanModel {
            if let current = model, current != cleanModel {
                changes.append(ConfigurationChange(field: .model, oldValue: current, newValue: cleanModel,
                                                   observedAt: observedAt, anchorLine: anchorLine,
                                                   provenance: observationProvenance))
            }
            let observation = FieldObservation(value: cleanModel, observedAt: observedAt,
                                               anchorLine: anchorLine, provenance: observationProvenance)
            if isFirstObservation { initialModel = observation }
            currentModel = observation
            model = cleanModel
        }
        if let cleanEffort {
            if let current = effort, current != cleanEffort {
                changes.append(ConfigurationChange(field: .reasoningEffort, oldValue: current, newValue: cleanEffort,
                                                   observedAt: observedAt, anchorLine: anchorLine,
                                                   provenance: observationProvenance))
            }
            let observation = FieldObservation(value: cleanEffort, observedAt: observedAt,
                                               anchorLine: anchorLine, provenance: observationProvenance)
            if isFirstObservation { initialEffort = observation }
            currentEffort = observation
            effort = cleanEffort
        }
    }

    var initialConfiguration: SessionConfiguration? {
        guard let firstAnchorLine else { return nil }
        let model = initialModel?.value
        let effort = initialEffort?.value
        // A combined configuration is only as strong as the record that stated
        // both fields. When fields arrived independently, the aggregate metadata
        // describes the first field and field-level metadata preserves the truth.
        // Claude deliberately supplies `.inferredFirstObservation` as the
        // aggregate provenance even though its field evidence is stamped
        // `.assistantRecord`. For timelines without a distinct initial policy
        // (Codex/Pi/Copilot), retain the provenance of the first record itself.
        let aggregateProvenance = initialProvenance == provenance
            ? (initialModel?.provenance ?? initialEffort?.provenance ?? initialProvenance)
            : initialProvenance
        return SessionConfiguration(model: model, reasoningEffort: effort,
                                    observedAt: firstObservedAt, anchorLine: firstAnchorLine,
                                    provenance: aggregateProvenance,
                                    modelObservedAt: initialModel?.observedAt,
                                    modelAnchorLine: initialModel?.anchorLine,
                                    modelProvenance: initialModel?.provenance,
                                    reasoningEffortObservedAt: initialEffort?.observedAt,
                                    reasoningEffortAnchorLine: initialEffort?.anchorLine,
                                    reasoningEffortProvenance: initialEffort?.provenance)
    }

    var currentConfiguration: SessionConfiguration? {
        guard firstAnchorLine != nil else { return nil }
        return SessionConfiguration(model: model, reasoningEffort: effort,
                                    observedAt: lastObservedAt, anchorLine: lastAnchorLine,
                                    provenance: lastProvenance ?? provenance,
                                    modelObservedAt: currentModel?.observedAt,
                                    modelAnchorLine: currentModel?.anchorLine,
                                    modelProvenance: currentModel?.provenance,
                                    reasoningEffortObservedAt: currentEffort?.observedAt,
                                    reasoningEffortAnchorLine: currentEffort?.anchorLine,
                                    reasoningEffortProvenance: currentEffort?.provenance)
    }

    /// An empty string is absence, not a value — matching `SessionIndexer`'s
    /// `!turnModel.isEmpty` guard on the same records.
    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
