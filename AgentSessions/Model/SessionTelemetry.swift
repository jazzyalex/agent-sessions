import Foundation

/// Where a telemetry observation came from. Kept explicit because the two
/// providers record configuration very differently: Codex writes the effective
    /// settings for every turn, while Claude only ever stamps the model on the
    /// assistant record that used it — so Claude's "initial" configuration is an
    /// inference from the first observed record, not something the transcript
    /// states in a session-start event.
public enum TelemetryProvenance: String, Codable, Sendable {
    /// Codex `turn_context` payload — the effective settings for that turn.
    case effectiveTurnContext
    /// Claude assistant record (`message.model` / the record's top-level `effort`).
    case assistantRecord
    /// Initial configuration inferred from the first observed record, rather than
    /// read from a session-start record. Fields absent from that record stay unknown.
    case inferredFirstObservation
    /// A dedicated change event the provider emits in its own right — Pi's
    /// `model_change` / `thinking_level_change`, Copilot's `session.model_change`.
    /// Stronger than an inference: the provider is stating the change happened.
    case providerChangeRecord
}

/// Configuration fields observed at one point in a transcript. Either field may be
/// unknown when the provider's record states only the other one.
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

    /// Field-level evidence. These remain optional because a configuration record
    /// may state only one field; an absent field must stay unknown rather than being
    /// filled from a later record.
    public let modelObservedAt: Date?
    public let modelAnchorLine: Int?
    public let modelProvenance: TelemetryProvenance?
    public let reasoningEffortObservedAt: Date?
    public let reasoningEffortAnchorLine: Int?
    public let reasoningEffortProvenance: TelemetryProvenance?

    public init(model: String?,
                reasoningEffort: String?,
                observedAt: Date?,
                anchorLine: Int,
                provenance: TelemetryProvenance,
                modelObservedAt: Date? = nil,
                modelAnchorLine: Int? = nil,
                modelProvenance: TelemetryProvenance? = nil,
                reasoningEffortObservedAt: Date? = nil,
                reasoningEffortAnchorLine: Int? = nil,
                reasoningEffortProvenance: TelemetryProvenance? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.observedAt = observedAt
        self.anchorLine = anchorLine
        self.provenance = provenance
        self.modelObservedAt = model == nil ? nil : (modelObservedAt ?? observedAt)
        self.modelAnchorLine = model == nil ? nil : (modelAnchorLine ?? anchorLine)
        self.modelProvenance = model == nil ? nil : (modelProvenance ?? provenance)
        self.reasoningEffortObservedAt = reasoningEffort == nil
            ? nil : (reasoningEffortObservedAt ?? observedAt)
        self.reasoningEffortAnchorLine = reasoningEffort == nil
            ? nil : (reasoningEffortAnchorLine ?? anchorLine)
        self.reasoningEffortProvenance = reasoningEffort == nil
            ? nil : (reasoningEffortProvenance ?? provenance)
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
    /// A normalized pricing basis. `"standard-normalized"` is used when Codex's
    /// actual service tier is not observed; it must not be presented as evidence
    /// that the request ran on a provider-reported standard tier.
    public var speed: String
    /// Provider-reported inference region. nil means the field was absent;
    /// unsupported or malformed explicit values are preserved as `unknown`.
    public var inferenceGeo: String?

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
                inferenceGeo: String? = nil,
                freshInputTokens: Int = 0,
                cacheReadTokens: Int = 0,
                cacheWrite5mTokens: Int = 0,
                cacheWrite1hTokens: Int = 0,
                outputTokens: Int = 0,
                reasoningOutputTokens: Int = 0) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.inferenceGeo = inferenceGeo
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
    public let inferenceGeo: String?
    public let freshInputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWrite5mTokens: Int
    public let cacheWrite1hTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    /// Total input presented to this request, including cached input when the
    /// provider reports it. nil means the transcript cannot establish the value.
    public let contextInputTokens: Int?
    /// API-equivalent cost under the stamped price-table identity.
    /// nil means unpriced or not yet priced; consult the session cost reasons.
    public let apiEquivalentUSD: Double?
    public let priceTableRevision: Int?
    public let priceTableUpdated: String?
    /// Exact canonical manifest identity, including metadata.
    public let priceManifestFingerprint: String?

    public init(recordID: String?, observedAt: Date?, anchorLine: Int,
                usageFamily: String, ownership: TelemetryUsageOwnership,
                model: String?, reasoningEffort: String?, speed: String,
                inferenceGeo: String? = nil,
                freshInputTokens: Int, cacheReadTokens: Int,
                cacheWrite5mTokens: Int, cacheWrite1hTokens: Int,
                outputTokens: Int, reasoningOutputTokens: Int = 0,
                contextInputTokens: Int?, apiEquivalentUSD: Double? = nil,
                priceTableRevision: Int? = nil, priceTableUpdated: String? = nil,
                priceManifestFingerprint: String? = nil) {
        self.recordID = recordID
        self.observedAt = observedAt
        self.anchorLine = anchorLine
        self.usageFamily = usageFamily
        self.ownership = ownership
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.inferenceGeo = inferenceGeo
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
        self.priceManifestFingerprint = priceManifestFingerprint
    }

    public var topLineTokens: Int {
        freshInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens + outputTokens
    }

    func priced(usd: Double?, revision: Int, updated: String,
                manifestFingerprint: String) -> TelemetryUsageEvent {
        TelemetryUsageEvent(recordID: recordID, observedAt: observedAt, anchorLine: anchorLine,
                            usageFamily: usageFamily, ownership: ownership, model: model,
                            reasoningEffort: reasoningEffort, speed: speed,
                            inferenceGeo: inferenceGeo,
                            freshInputTokens: freshInputTokens, cacheReadTokens: cacheReadTokens,
                            cacheWrite5mTokens: cacheWrite5mTokens, cacheWrite1hTokens: cacheWrite1hTokens,
                            outputTokens: outputTokens, reasoningOutputTokens: reasoningOutputTokens,
                            contextInputTokens: contextInputTokens, apiEquivalentUSD: usd,
                            priceTableRevision: revision, priceTableUpdated: updated,
                            priceManifestFingerprint: manifestFingerprint)
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
    /// Stable semantic hash of the model/rate content used for priced events.
    /// Pair with `priceTableUpdated` to identify metadata-only manifest changes.
    public let priceTableRevision: Int
    /// Exact canonical manifest identity used for this estimate. This is separate
    /// from the semantic revision so metadata-only corrections remain auditable.
    public let priceManifestFingerprint: String?

    public init(apiEquivalentUSD: Double?,
                unpricedModels: [String],
                missingPriceComponents: [String],
                priceTableUpdated: String,
                priceTableRevision: Int = 0,
                priceManifestFingerprint: String? = nil) {
        self.apiEquivalentUSD = apiEquivalentUSD
        self.unpricedModels = unpricedModels
        self.missingPriceComponents = missingPriceComponents
        self.priceTableUpdated = priceTableUpdated
        self.priceTableRevision = priceTableRevision
        self.priceManifestFingerprint = priceManifestFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case apiEquivalentUSD, unpricedModels, missingPriceComponents
        case priceTableUpdated, priceTableRevision, priceManifestFingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiEquivalentUSD = try values.decodeIfPresent(Double.self, forKey: .apiEquivalentUSD)
        unpricedModels = try values.decode([String].self, forKey: .unpricedModels)
        missingPriceComponents = try values.decode([String].self, forKey: .missingPriceComponents)
        priceTableUpdated = try values.decode(String.self, forKey: .priceTableUpdated)
        priceTableRevision = try values.decodeIfPresent(Int.self, forKey: .priceTableRevision) ?? 0
        priceManifestFingerprint = try values.decodeIfPresent(String.self, forKey: .priceManifestFingerprint)
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
    /// Provenance of the ratio, separate from the latest raw quota observation
    /// above. A carried bootstrap can be weeks old even when the latest poll is
    /// fresh, and that distinction must remain visible to callers.
    public let calibrationProvenance: WeeklyQuotaCalibrationProvenance?
    public let calculatedAt: Date
    public let priceTableRevision: Int

    public init(status: TelemetryWeeklyQuotaStatus,
                percentPoints: Double?,
                unavailableReason: String?,
                percentPointsPerAPIDollar: Double?,
                accountScoped: Bool,
                sourceFamily: String?,
                quotaResetAt: Date?,
                quotaObservedAt: Date?,
                quotaPrecision: String?,
                calibrationProvenance: WeeklyQuotaCalibrationProvenance? = nil,
                calculatedAt: Date,
                priceTableRevision: Int) {
        self.status = status
        self.percentPoints = percentPoints
        self.unavailableReason = unavailableReason
        self.percentPointsPerAPIDollar = percentPointsPerAPIDollar
        self.accountScoped = accountScoped
        self.sourceFamily = sourceFamily
        self.quotaResetAt = quotaResetAt
        self.quotaObservedAt = quotaObservedAt
        self.quotaPrecision = quotaPrecision
        self.calibrationProvenance = calibrationProvenance
        self.calculatedAt = calculatedAt
        self.priceTableRevision = priceTableRevision
    }
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
    public static let parserVersion = 5

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

    public var sessionOwnedTopLineTokens: Int? {
        let owned = usageEvents.filter { $0.ownership == .session }
        guard !owned.isEmpty else { return nil }
        return owned.reduce(0) { $0 + $1.topLineTokens }
    }

    public var descendantTopLineTokens: Int? {
        let owned = usageEvents.filter { $0.ownership == .descendant }
        guard !owned.isEmpty else { return nil }
        return owned.reduce(0) { $0 + $1.topLineTokens }
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
