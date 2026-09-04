import Foundation

/// Where a telemetry observation came from. Kept explicit because the two
/// providers record configuration very differently: Codex writes the effective
/// settings for every turn, while Claude only ever stamps the model on the
/// assistant record that used it — so Claude's "initial" configuration is an
/// inference from the first record, not something the transcript states.
public enum TelemetryProvenance: String, Codable, Sendable {
    /// Codex `turn_context` payload — the effective settings for that turn.
    case effectiveTurnContext
    /// Claude assistant record (`message.model` / the record's top-level `effort`).
    case assistantRecord
    /// Initial configuration backfilled from the first value ever observed for a
    /// field, rather than read from a session-start record.
    case inferredFirstObservation
    /// A dedicated change event the provider emits in its own right — Pi's
    /// `model_change` / `thinking_level_change`, Copilot's `session.model_change`.
    /// Stronger than an inference: the provider is stating the change happened.
    case providerChangeRecord
}

/// A model + reasoning-effort pair observed at one point in a transcript.
public struct SessionConfiguration: Equatable, Codable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let observedAt: Date?
    /// 0-based index within the record stream the accumulator was given.
    ///
    /// NOT a raw file line number: the shared `JSONLReader` silently drops blank
    /// lines and replaces oversize ones with a stub, so the two diverge on any file
    /// containing either. It is stable and comparable as long as a consumer walks
    /// the file with that same reader, which is how every caller reads transcripts.
    public let anchorLine: Int
    public let provenance: TelemetryProvenance

    public init(model: String?,
                reasoningEffort: String?,
                observedAt: Date?,
                anchorLine: Int,
                provenance: TelemetryProvenance) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.observedAt = observedAt
        self.anchorLine = anchorLine
        self.provenance = provenance
    }
}

/// One field changing to a different non-empty value.
///
/// A field going absent is NOT a change: both providers omit fields routinely
/// (10,466 of 47,671 sampled Claude assistant records carry no `effort`), so
/// accumulators carry the last non-empty value forward instead of recording a
/// change to nil.
public struct ConfigurationChange: Equatable, Codable, Sendable {
    public enum Field: String, Codable, Sendable {
        case model
        case reasoningEffort
    }

    public let field: Field
    public let oldValue: String?
    public let newValue: String?
    public let observedAt: Date?
    public let anchorLine: Int
    public let provenance: TelemetryProvenance

    public init(field: Field,
                oldValue: String?,
                newValue: String?,
                observedAt: Date?,
                anchorLine: Int,
                provenance: TelemetryProvenance) {
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.observedAt = observedAt
        self.anchorLine = anchorLine
        self.provenance = provenance
    }
}

/// Tokens attributed to one effective (model, effort, speed) configuration.
///
/// `speed` is part of the identity, not a display detail: Anthropic fast mode is a
/// whole second rate set (Opus 5 / 4.8 bill 2x), so a fast slice and a standard
/// slice of the same model must never merge.
///
/// Slices are a BREAKDOWN, not a pricing requirement: cost is linear in tokens, so
/// any UI regrouping (per model, per speed) sums slices without re-pricing. Effort
/// does not affect price at all — it is part of the key because "what did xhigh
/// cost me in tokens" is the question this answers.
public struct TelemetryUsageSlice: Equatable, Codable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    /// `RunwaySpeedTier.rawValue`. Always `"standard"` for Codex, which has no
    /// speed tiers.
    public var speed: String

    public var freshInputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWrite5mTokens: Int
    public var cacheWrite1hTokens: Int
    public var outputTokens: Int
    /// Informational only: both providers report reasoning/thinking tokens as a
    /// SUBSET of output. Adding it to a total double-counts every thinking token.
    public var reasoningOutputTokens: Int

    public init(model: String?,
                reasoningEffort: String?,
                speed: String,
                freshInputTokens: Int = 0,
                cacheReadTokens: Int = 0,
                cacheWrite5mTokens: Int = 0,
                cacheWrite1hTokens: Int = 0,
                outputTokens: Int = 0,
                reasoningOutputTokens: Int = 0) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.freshInputTokens = freshInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    /// Fresh input + cache reads + cache writes + output. Reasoning is deliberately
    /// absent — see `reasoningOutputTokens`.
    public var topLineTokens: Int {
        freshInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens + outputTokens
    }

    /// True when this slice contributes no billable tokens. Such a slice is skipped
    /// by the cost calculator, so an unpriceable model that never actually ran
    /// cannot make a whole session unpriceable.
    public var isEmpty: Bool { topLineTokens == 0 }
}

/// Whether a usage record belongs to the selected session itself or to work it
/// delegated. The distinction is evidence, not a summing instruction: callers can
/// present the whole session tree or self-only totals without re-parsing the log.
public enum TelemetryUsageOwnership: String, Codable, Sendable {
    case session
    case descendant
}

/// One provider usage record, before aggregation.
///
/// Request-level evidence is required for tiered pricing. In particular, Codex's
/// long-context multiplier is selected per request; aggregating a whole session
/// first can incorrectly push several short requests over the threshold.
public struct TelemetryUsageEvent: Equatable, Codable, Sendable {
    public let recordID: String?
    public let observedAt: Date?
    public let anchorLine: Int
    public let usageFamily: String
    public let ownership: TelemetryUsageOwnership
    public let model: String?
    public let reasoningEffort: String?
    public let speed: String
    public let freshInputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWrite5mTokens: Int
    public let cacheWrite1hTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    /// Total input presented to this request, including cached input when the
    /// provider reports it. nil means the transcript cannot establish the value.
    public let contextInputTokens: Int?
    /// API-equivalent cost under the stamped immutable price-table revision.
    /// nil means unpriced or not yet priced; consult the session cost reasons.
    public let apiEquivalentUSD: Double?
    public let priceTableRevision: Int?
    public let priceTableUpdated: String?

    public init(recordID: String?, observedAt: Date?, anchorLine: Int,
                usageFamily: String, ownership: TelemetryUsageOwnership,
                model: String?, reasoningEffort: String?, speed: String,
                freshInputTokens: Int, cacheReadTokens: Int,
                cacheWrite5mTokens: Int, cacheWrite1hTokens: Int,
                outputTokens: Int, reasoningOutputTokens: Int = 0,
                contextInputTokens: Int?, apiEquivalentUSD: Double? = nil,
                priceTableRevision: Int? = nil, priceTableUpdated: String? = nil) {
        self.recordID = recordID
        self.observedAt = observedAt
        self.anchorLine = anchorLine
        self.usageFamily = usageFamily
        self.ownership = ownership
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.freshInputTokens = freshInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.contextInputTokens = contextInputTokens
        self.apiEquivalentUSD = apiEquivalentUSD
        self.priceTableRevision = priceTableRevision
        self.priceTableUpdated = priceTableUpdated
    }

    public var topLineTokens: Int {
        freshInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens + outputTokens
    }

    func priced(usd: Double?, revision: Int, updated: String) -> TelemetryUsageEvent {
        TelemetryUsageEvent(recordID: recordID, observedAt: observedAt, anchorLine: anchorLine,
                            usageFamily: usageFamily, ownership: ownership, model: model,
                            reasoningEffort: reasoningEffort, speed: speed,
                            freshInputTokens: freshInputTokens, cacheReadTokens: cacheReadTokens,
                            cacheWrite5mTokens: cacheWrite5mTokens, cacheWrite1hTokens: cacheWrite1hTokens,
                            outputTokens: outputTokens, reasoningOutputTokens: reasoningOutputTokens,
                            contextInputTokens: contextInputTokens, apiEquivalentUSD: usd,
                            priceTableRevision: revision, priceTableUpdated: updated)
    }
}

/// Session-wide token totals plus the provenance needed to judge them.
public struct TelemetryUsageSummary: Equatable, Codable, Sendable {
    public let topLineTokens: Int
    /// False for legacy logs that expose only a recorded total and no components.
    /// Component fields are then zero and the session cannot be priced.
    public let hasComponentBreakdown: Bool
    /// The provider's own recorded total, when it states one (Codex `total_tokens`).
    public let recordedTotalTokens: Int?
    /// Which record families contributed, e.g. `["token_count"]` or
    /// `["message.usage"]`. More than one means both appeared and one was chosen
    /// as authoritative.
    public let usageFamilies: [String]
    /// True when two families both reported positive tokens — the totals come from
    /// the authoritative one, never from summing both.
    public let usageFamilyConflict: Bool

    public init(topLineTokens: Int,
                hasComponentBreakdown: Bool,
                recordedTotalTokens: Int?,
                usageFamilies: [String],
                usageFamilyConflict: Bool) {
        self.topLineTokens = topLineTokens
        self.hasComponentBreakdown = hasComponentBreakdown
        self.recordedTotalTokens = recordedTotalTokens
        self.usageFamilies = usageFamilies
        self.usageFamilyConflict = usageFamilyConflict
    }
}

/// What this session's own work would have cost at published API rates.
///
/// Deliberately NOT actual spend: Codex and Claude subscription sessions are not
/// API invoices. Descendant events keep their own priced evidence but do not enter
/// this total, because their child transcript may be indexed separately. Fails
/// closed — a session with any unpriceable self-owned contribution reports no
/// dollar figure and names the cause, because a partial sum silently understates.
public struct TelemetryCostEstimate: Equatable, Codable, Sendable {
    /// nil means unavailable. nil with BOTH arrays empty means there was simply
    /// nothing to price — not a failure.
    public let apiEquivalentUSD: Double?
    /// Model slugs with billable tokens and no price entry.
    public let unpricedModels: [String]
    /// Priced models missing a rate a slice actually needs, e.g.
    /// `"claude-opus-5:fast"` or `"claude-opus-5:cacheWrite1h"`.
    public let missingPriceComponents: [String]
    /// `updated` date of the price manifest used, so a stored result can be
    /// re-judged when rates move.
    public let priceTableUpdated: String
    /// Stable content hash of the exact manifest used for every priced event.
    public let priceTableRevision: Int

    public init(apiEquivalentUSD: Double?,
                unpricedModels: [String],
                missingPriceComponents: [String],
                priceTableUpdated: String,
                priceTableRevision: Int = 0) {
        self.apiEquivalentUSD = apiEquivalentUSD
        self.unpricedModels = unpricedModels
        self.missingPriceComponents = missingPriceComponents
        self.priceTableUpdated = priceTableUpdated
        self.priceTableRevision = priceTableRevision
    }

    private enum CodingKeys: String, CodingKey {
        case apiEquivalentUSD, unpricedModels, missingPriceComponents
        case priceTableUpdated, priceTableRevision
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiEquivalentUSD = try values.decodeIfPresent(Double.self, forKey: .apiEquivalentUSD)
        unpricedModels = try values.decode([String].self, forKey: .unpricedModels)
        missingPriceComponents = try values.decode([String].self, forKey: .missingPriceComponents)
        priceTableUpdated = try values.decode(String.self, forKey: .priceTableUpdated)
        priceTableRevision = try values.decodeIfPresent(Int.self, forKey: .priceTableRevision) ?? 0
    }
}

public enum TelemetryWeeklyQuotaStatus: String, Equatable, Codable, Sendable {
    case estimated
    case unavailable
}

/// Estimated share of the account's weekly allowance consumed by this session.
/// It is never labelled exact: the account-wide quota drop can include activity
/// from other devices that local transcripts cannot observe.
public struct TelemetryWeeklyQuotaEstimate: Equatable, Codable, Sendable {
    public let status: TelemetryWeeklyQuotaStatus
    public let percentPoints: Double?
    public let unavailableReason: String?
    public let percentPointsPerAPIDollar: Double?
    public let accountScoped: Bool
    public let sourceFamily: String?
    public let quotaResetAt: Date?
    public let quotaObservedAt: Date?
    public let quotaPrecision: String?
    public let calculatedAt: Date
    public let priceTableRevision: Int
}

/// Provider-neutral telemetry for one transcript.
///
/// Computed on demand from the transcript file, never stored on `Session` or in
/// SQLite, and never derived from hydrated `SessionEvent`s — both parsers truncate
/// `rawJSON`, so usage on large assistant lines is already gone by then.
///
/// Each transcript is accounted independently: a subagent's own first effective
/// configuration is its initial configuration, and a parent's changes never mutate
/// an already-running child's history.
public struct SessionTelemetry: Equatable, Codable, Sendable {
    /// Bump when accumulator semantics change; caches key on it.
    public static let parserVersion = 2

    public let source: SessionSource
    public let initialConfiguration: SessionConfiguration?
    public let currentConfiguration: SessionConfiguration?
    public let configurationChanges: [ConfigurationChange]
    public let usageSlices: [TelemetryUsageSlice]
    public let usageEvents: [TelemetryUsageEvent]
    public let usageSummary: TelemetryUsageSummary?
    public let costEstimate: TelemetryCostEstimate?
    public let weeklyQuotaEstimate: TelemetryWeeklyQuotaEstimate?
    public let parserVersion: Int

    public var sessionOwnedTopLineTokens: Int {
        usageEvents.filter { $0.ownership == .session }.reduce(0) { $0 + $1.topLineTokens }
    }

    public var descendantTopLineTokens: Int {
        usageEvents.filter { $0.ownership == .descendant }.reduce(0) { $0 + $1.topLineTokens }
    }

    /// nil when any contributing event in that ownership class is unpriced.
    public func apiEquivalentUSD(ownership: TelemetryUsageOwnership) -> Double? {
        let contributing = usageEvents.filter { $0.ownership == ownership && $0.topLineTokens > 0 }
        guard !contributing.isEmpty, contributing.allSatisfy({ $0.apiEquivalentUSD != nil }) else { return nil }
        return contributing.compactMap(\.apiEquivalentUSD).reduce(0, +)
    }

    public init(source: SessionSource,
                initialConfiguration: SessionConfiguration?,
                currentConfiguration: SessionConfiguration?,
                configurationChanges: [ConfigurationChange],
                usageSlices: [TelemetryUsageSlice],
                usageEvents: [TelemetryUsageEvent] = [],
                usageSummary: TelemetryUsageSummary?,
                costEstimate: TelemetryCostEstimate?,
                weeklyQuotaEstimate: TelemetryWeeklyQuotaEstimate? = nil,
                parserVersion: Int = SessionTelemetry.parserVersion) {
        self.source = source
        self.initialConfiguration = initialConfiguration
        self.currentConfiguration = currentConfiguration
        self.configurationChanges = configurationChanges
        self.usageSlices = usageSlices
        self.usageEvents = usageEvents
        self.usageSummary = usageSummary
        self.costEstimate = costEstimate
        self.weeklyQuotaEstimate = weeklyQuotaEstimate
        self.parserVersion = parserVersion
    }

    private enum CodingKeys: String, CodingKey {
        case source, initialConfiguration, currentConfiguration, configurationChanges
        case usageSlices, usageEvents, usageSummary, costEstimate, weeklyQuotaEstimate, parserVersion
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(SessionSource.self, forKey: .source)
        initialConfiguration = try values.decodeIfPresent(SessionConfiguration.self, forKey: .initialConfiguration)
        currentConfiguration = try values.decodeIfPresent(SessionConfiguration.self, forKey: .currentConfiguration)
        configurationChanges = try values.decode([ConfigurationChange].self, forKey: .configurationChanges)
        usageSlices = try values.decode([TelemetryUsageSlice].self, forKey: .usageSlices)
        usageEvents = try values.decodeIfPresent([TelemetryUsageEvent].self, forKey: .usageEvents) ?? []
        usageSummary = try values.decodeIfPresent(TelemetryUsageSummary.self, forKey: .usageSummary)
        costEstimate = try values.decodeIfPresent(TelemetryCostEstimate.self, forKey: .costEstimate)
        weeklyQuotaEstimate = try values.decodeIfPresent(TelemetryWeeklyQuotaEstimate.self,
                                                          forKey: .weeklyQuotaEstimate)
        parserVersion = try values.decode(Int.self, forKey: .parserVersion)
    }
}
