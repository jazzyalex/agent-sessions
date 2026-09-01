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

/// What this session would have cost at published API rates.
///
/// Deliberately NOT actual spend: Codex and Claude subscription sessions are not
/// API invoices. Fails closed — a session with any unpriceable contributing slice
/// reports no dollar figure and names the cause, because a partial sum silently
/// understates and a session total exists to be compared against other sessions.
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

    public init(apiEquivalentUSD: Double?,
                unpricedModels: [String],
                missingPriceComponents: [String],
                priceTableUpdated: String) {
        self.apiEquivalentUSD = apiEquivalentUSD
        self.unpricedModels = unpricedModels
        self.missingPriceComponents = missingPriceComponents
        self.priceTableUpdated = priceTableUpdated
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
    public static let parserVersion = 1

    public let source: SessionSource
    public let initialConfiguration: SessionConfiguration?
    public let currentConfiguration: SessionConfiguration?
    public let configurationChanges: [ConfigurationChange]
    public let usageSlices: [TelemetryUsageSlice]
    public let usageSummary: TelemetryUsageSummary?
    public let costEstimate: TelemetryCostEstimate?
    public let parserVersion: Int

    public init(source: SessionSource,
                initialConfiguration: SessionConfiguration?,
                currentConfiguration: SessionConfiguration?,
                configurationChanges: [ConfigurationChange],
                usageSlices: [TelemetryUsageSlice],
                usageSummary: TelemetryUsageSummary?,
                costEstimate: TelemetryCostEstimate?,
                parserVersion: Int = SessionTelemetry.parserVersion) {
        self.source = source
        self.initialConfiguration = initialConfiguration
        self.currentConfiguration = currentConfiguration
        self.configurationChanges = configurationChanges
        self.usageSlices = usageSlices
        self.usageSummary = usageSummary
        self.costEstimate = costEstimate
        self.parserVersion = parserVersion
    }
}
