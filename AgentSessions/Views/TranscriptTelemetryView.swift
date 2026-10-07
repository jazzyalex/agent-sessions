import SwiftUI

/// One row of the "How this was estimated" group: a distinct pricing identity,
/// NOT a request. Context size varies request to request and is summarised as a
/// range — keying on it is what produced one visible row per request.
public struct TelemetryPricingBasis: Equatable {
    public let model: String?
    public let speed: String
    public let inferenceGeo: String?
    public let requestCount: Int
    public let minContextInputTokens: Int?
    public let maxContextInputTokens: Int?
}

/// The three-way split behind the token bar. Cache writes fold into `fresh`
/// because they are input the request paid to write; reasoning is reported
/// separately and never enters `total` — both providers count it inside output.
public struct TelemetryTokenShare: Equatable {
    public let cached: Int
    public let fresh: Int
    public let output: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int

    public var total: Int { cached + fresh + output }
    public var cachedFraction: Double { fraction(cached) }
    public var freshFraction: Double { fraction(fresh) }
    public var outputFraction: Double { fraction(output) }

    private func fraction(_ part: Int) -> Double {
        total > 0 ? Double(part) / Double(total) : 0
    }
}

/// One row of the Session info history timeline. `blockIndex` is the transcript
/// block the inline marker for this change was placed on — the two are resolved
/// by the same anchoring function so a jump can never land somewhere the marker
/// is not.
public struct SessionInfoHistoryRow: Equatable, Identifiable {
    public enum Kind: Equatable { case started, change }
    public let id: Int
    public let kind: Kind
    public let title: String
    public let observedAt: Date?
    /// True only for a started row the transcript never actually stated.
    public let isInferred: Bool
    public let blockIndex: Int?
}

/// A structural identity for the selected telemetry source. Session IDs and
/// paths are external values and may legally contain any delimiter.
struct TranscriptTelemetrySelectionIdentity: Hashable, Sendable {
    let source: SessionSource
    let sessionID: String
    let filePath: String

    init(source: SessionSource, sessionID: String, filePath: String) {
        self.source = source
        self.sessionID = sessionID
        self.filePath = filePath
    }

    init(session: Session) {
        source = session.source
        sessionID = session.id
        filePath = session.filePath
    }
}

/// Keeps the expensive full-file telemetry read tied to the inspector's actual
/// visibility. Returning nil while hidden also keeps session-selection churn from
/// restarting the SwiftUI task merely because its underlying session key changed.
struct TranscriptTelemetryLoadRequest: Equatable {
    let selection: TranscriptTelemetrySelectionIdentity
    let refresh: Int

    static func key(isVisible: Bool,
                    selection: TranscriptTelemetrySelectionIdentity?,
                    refresh: Int) -> TranscriptTelemetryLoadRequest? {
        guard isVisible, let selection else { return nil }
        return TranscriptTelemetryLoadRequest(selection: selection, refresh: refresh)
    }
}

/// Presentation only: never fills missing evidence from Session.model or a parent.
enum TranscriptTelemetryPresentation {
    static let visibilityKey = "ShowSessionInfo"

    static func localized(_ resource: String.LocalizationValue,
                          locale: Locale = .current) -> String {
        String(localized: resource, locale: locale)
    }

    /// A displayable value plus the explanation that belongs in its tooltip.
    /// An absent value is always the em dash — the reason never occupies layout.
    struct Value: Equatable {
        let text: String
        let help: String

        static func absent(_ reason: String) -> Value { Value(text: "—", help: reason) }
    }

    static func configuration(_ value: SessionConfiguration?) -> String {
        "\(value?.model ?? "—") · \(value?.reasoningEffort ?? "—")"
    }

    static func change(_ value: ConfigurationChange, locale: Locale = .current) -> String {
        let old = value.oldValue ?? localized("Unavailable", locale: locale)
        let new = value.newValue ?? localized("Unavailable", locale: locale)
        return value.field == .model
            ? localized("Model changed: \(old) → \(new)", locale: locale)
            : localized("Thinking effort changed: \(old) → \(new)", locale: locale)
    }

    static func tokens(_ telemetry: SessionTelemetry) -> Int? {
        guard telemetry.usageSummary?.unavailableReason == nil else { return nil }
        if telemetry.usageSummary?.hasComponentBreakdown == true,
           let owned = telemetry.sessionOwnedTopLineTokens {
            return owned
        }
        // Some legacy Codex records contain only a total. Claude records with
        // no usage evidence must not become a plausible zero-token session.
        return telemetry.usageSummary?.displayTotalTokens
            ?? telemetry.usageSummary?.recordedTotalTokens
    }

    // MARK: - Session activity

    /// Wall-clock span and turn composition for one transcript.
    ///
    /// Deliberately NOT an "active vs idle" split: neither provider records how
    /// long a request took, so any such figure would be invented. What the
    /// transcript does state is when the first and last priced requests happened
    /// and how the blocks divide up, and that is all this reports.
    struct ActivitySummary: Equatable {
        let span: TimeInterval?
        let firstRequestAt: Date?
        let lastRequestAt: Date?
        let requests: Int
        /// Requests that actually carry a timestamp. `requests` counts every
        /// session-owned event, including ones the provider left unstamped, so it
        /// is the wrong divisor for a span measured only over stamped ones.
        let timedRequests: Int
        let userBlocks: Int
        let assistantBlocks: Int
        let toolBlocks: Int
        let usageUnavailableReason: String?

        /// Mean gap between consecutive timed requests. A long session with few
        /// requests was mostly waiting on a person, not on the model.
        var secondsPerRequest: TimeInterval? {
            guard let span, timedRequests > 1, span > 0 else { return nil }
            return span / Double(timedRequests - 1)
        }
    }

    static func activity(_ telemetry: SessionTelemetry,
                         blocks: [SessionTranscriptBuilder.LogicalBlock]) -> ActivitySummary {
        let owned = telemetry.usageEvents.filter { $0.ownership == .session }
        let usageUnavailableReason = telemetry.usageSummary?.unavailableReason
            ?? (telemetry.usageSummary?.hasComponentBreakdown == false
                ? "Request-level usage is unavailable because the provider recorded no complete component breakdown."
                : nil)
        let stamps = usageUnavailableReason == nil
            ? owned.compactMap(\.observedAt).sorted()
            : []
        let first = stamps.first
        let last = stamps.last
        var span: TimeInterval?
        if let first, let last, last > first { span = last.timeIntervalSince(first) }
        var user = 0, assistant = 0, tools = 0
        for block in blocks {
            switch block.kind {
            case .user: user += 1
            case .assistant: assistant += 1
            case .toolCall: tools += 1
            default: break
            }
        }
        return ActivitySummary(span: span, firstRequestAt: first, lastRequestAt: last,
                               requests: usageUnavailableReason == nil ? owned.count : 0,
                               timedRequests: stamps.count,
                               userBlocks: user, assistantBlocks: assistant,
                               toolBlocks: tools,
                               usageUnavailableReason: usageUnavailableReason)
    }

    /// "4h 12m", "38m", "45s". nil span reads as an em dash at the call site.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(secs)s"
    }

    // MARK: - Displayable values

    static func costValue(_ telemetry: SessionTelemetry,
                          capability: TelemetryCapability? = nil,
                          locale: Locale = .current) -> Value {
        if let reason = telemetry.usageSummary?.unavailableReason {
            return .absent(localized("Usage unavailable: \(reason)", locale: locale))
        }
        if let dollars = telemetry.costEstimate?.apiEquivalentUSD {
            let text: String
            if dollars > 0 && dollars < 0.01 {
                text = dollars.formatted(.currency(code: "USD").precision(.fractionLength(4)).locale(locale))
            } else {
                text = dollars.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
            }
            return Value(
                text: text,
                help: localized(
                    "Estimated API price at published rates: \(dollars.formatted(.number.precision(.fractionLength(4)).locale(locale))) USD. Reference value, not a subscription charge.",
                    locale: locale))
        }
        if case let .unavailable(reason) = capability {
            return .absent(localized("Pricing unavailable: \(reason)", locale: locale))
        }
        let reasons = (telemetry.costEstimate?.unpricedModels ?? [])
            + (telemetry.costEstimate?.missingPriceComponents ?? [])
        return .absent(reasons.isEmpty
                       ? localized("No priceable usage was recorded in this transcript.", locale: locale)
                       : localized("No price entry for: \(reasons.joined(separator: ", "))", locale: locale))
    }

    static func inferenceGeoValue(_ inferenceGeo: String?, locale: Locale = .current) -> Value {
        guard let inferenceGeo else {
            return .absent(localized("The provider did not record an inference region.", locale: locale))
        }
        switch inferenceGeo {
        case "":
            return Value(text: localized("Not provided", locale: locale),
                         help: localized("The provider recorded an empty inference region.", locale: locale))
        case "not_available":
            return Value(text: localized("Not available", locale: locale),
                         help: localized("The provider reported that inference geography was unavailable.", locale: locale))
        default:
            return Value(text: inferenceGeo,
                         help: localized("Provider-reported inference region.", locale: locale))
        }
    }

    static func weeklyValue(_ telemetry: SessionTelemetry, locale: Locale = .current) -> Value {
        if let estimate = telemetry.weeklyQuotaEstimate,
           estimate.status == .estimated, let points = estimate.percentPoints {
            return Value(text: "≈\(points.formatted(.number.precision(.fractionLength(2)).locale(locale)))%",
                         help: localized("Account-calibrated estimate of this session's share of the weekly allowance.", locale: locale))
        }
        // The row keeps its place, but the tooltip states only the reason the
        // value is missing. It must NOT suggest the Quota Meter: the engine
        // fails closed through five distinct gates (SessionTelemetryEngine.swift
        // ~269-311) and the Quota Meter addresses one of them. Unpriceable usage
        // and account-identity mismatches are not calibration problems, so a
        // blanket "calibrate" hint sends the reader somewhere that cannot help.
        return .absent(telemetry.weeklyQuotaEstimate?.unavailableReason
                       ?? localized("No compatible weekly calibration for this account.", locale: locale))
    }

    static func tokensValue(_ telemetry: SessionTelemetry, locale: Locale = .current) -> Value {
        guard let total = tokens(telemetry) else {
            if let reason = telemetry.usageSummary?.unavailableReason {
                return .absent(localized("Usage unavailable: \(reason)", locale: locale))
            }
            return .absent(localized("This transcript records no usage.", locale: locale))
        }
        let help = telemetry.usageSummary?.hasComponentBreakdown == true
            ? localized("Fresh input, cached input, cache writes and output. Reasoning tokens are counted inside output.", locale: locale)
            : localized("The provider recorded a total token count, but the component breakdown is unavailable.", locale: locale)
        return Value(text: total.formatted(.number.locale(locale)), help: help)
    }

    static func modelValue(_ value: SessionConfiguration?, locale: Locale = .current) -> Value {
        guard let model = value?.model else {
            return .absent(localized("This transcript records no model setting.", locale: locale))
        }
        return Value(text: model, help: configurationHelp(
            value?.modelProvenance ?? value?.provenance, locale: locale))
    }

    /// Presents a value that was already available on the indexed Session row.
    /// Quick facts must say where they came from so an immediate value cannot be
    /// mistaken for a transcript-derived observation.
    static func quickFactValue(_ field: SessionInfoField<String>,
                               locale: Locale = .current) -> Value {
        switch field {
        case let .known(value, provenance):
            return Value(
                text: value,
                help: localized(
                    "\(provenance.displayName) from already-loaded Session metadata.",
                    locale: locale))
        case let .unavailable(reason):
            let detail = reason == .notLoaded
                ? " Detailed telemetry may provide more evidence."
                : ""
            return .absent(localized(
                "\(reason.displayName).\(detail)",
                locale: locale))
        }
    }

    static func sourceValue(_ source: SessionSource,
                            locale: Locale = .current) -> Value {
        Value(
            text: source.displayName,
            help: localized("Provider-neutral source from loaded Session metadata.",
                            locale: locale))
    }

    static func titleValue(_ field: SessionInfoField<String>,
                           locale: Locale = .current) -> Value {
        switch field {
        case .known(_, _):
            return quickFactValue(field, locale: locale)
        case let .unavailable(reason):
            let help: String
            if reason == .notLoaded {
                help = localized(
                    "No title is available in already-loaded Session metadata.",
                    locale: locale)
            } else {
                help = localized("\(reason.displayName)", locale: locale)
            }
            return .absent(help)
        }
    }

    /// The first observed model is transcript evidence when the optional
    /// telemetry pass has completed. Before then, the quick-facts field stays
    /// explicitly not loaded rather than guessing from the current model. A
    /// completed failure is kept distinct from that pending state.
    static func firstObservedModelValue(_ facts: SessionInfoQuickFacts,
                                        telemetry: SessionTelemetry?,
                                        telemetryLoadState: SessionInfoTelemetryLoadState = .notStarted,
                                        locale: Locale = .current) -> Value {
        if let configuration = telemetry?.initialConfiguration,
           let model = configuration.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            let modelProvenance = configuration.modelProvenance ?? configuration.provenance
            let help = modelProvenance == .inferredFirstObservation
                ? localized("First observed model inferred from the first transcript record.",
                            locale: locale)
                : localized("First observed model recorded by the provider.",
                            locale: locale)
            return Value(text: model, help: help)
        }

        if telemetry != nil || telemetryLoadState == .loaded {
            return .absent(localized(
                "Not recorded in detailed telemetry.", locale: locale))
        }
        switch telemetryLoadState {
        case .notStarted, .loading:
            return quickFactValue(facts.firstObservedModel, locale: locale)
        case let .unavailable(reason):
            return quickFactValue(.unavailable(reason), locale: locale)
        case .loaded:
            return .absent(localized(
                "Not recorded in detailed telemetry.", locale: locale))
        }
    }

    /// nil means the provider never recorded a thinking setting, so the sidebar
    /// omits the row rather than presenting a permanent absent value.
    static func thinkingValue(_ value: SessionConfiguration?, locale: Locale = .current) -> Value? {
        guard let effort = value?.reasoningEffort else { return nil }
        return Value(text: effort, help: configurationHelp(
            value?.reasoningEffortProvenance ?? value?.provenance, locale: locale))
    }

    static func tokenSharePercent(_ fraction: Double, locale: Locale = .current) -> String {
        guard fraction > 0 else { return fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)) }
        if fraction < 0.01 { return localized("<1%", locale: locale) }
        return fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    static func tokenShareAccessibilityText(_ share: TelemetryTokenShare,
                                            locale: Locale = .current) -> String {
        let cached = tokenSharePercent(share.cachedFraction, locale: locale)
        let fresh = tokenSharePercent(share.freshFraction, locale: locale)
        let output = tokenSharePercent(share.outputFraction, locale: locale)
        return localized(
            "Token share: cached \(cached), fresh \(fresh), output \(output). \(tokenShareHelp(share, locale: locale))",
            locale: locale)
    }

    static func shouldShowHistory(_ telemetry: SessionTelemetry) -> Bool {
        !telemetry.configurationChanges.isEmpty
    }

    private static func configurationHelp(_ provenance: TelemetryProvenance?,
                                          locale: Locale) -> String {
        switch provenance {
        case .inferredFirstObservation:
            return localized("Inferred from the first record, not a session-start setting.", locale: locale)
        case .sessionMetadata:
            return localized("Current value read from provider session metadata.", locale: locale)
        default:
            return localized("Recorded by the provider.", locale: locale)
        }
    }

    static func rowAccessibilityLabel(label: String.LocalizationValue,
                                      value: String,
                                      locale: Locale = .current) -> String {
        let localizedLabel = localized(label, locale: locale)
        if value == "—" {
            return localized("\(localizedLabel): unavailable", locale: locale)
        }
        return localized("\(localizedLabel): \(value)", locale: locale)
    }

    static func tokenShareHelp(_ share: TelemetryTokenShare,
                               locale: Locale = .current) -> String {
        let cached = share.cached.formatted(.number.locale(locale))
        let fresh = share.fresh.formatted(.number.locale(locale))
        let output = share.output.formatted(.number.locale(locale))
        var lines = [localized(
            "Cached input \(cached), fresh input \(fresh), output \(output).",
            locale: locale)]
        if share.cacheWriteTokens > 0 {
            let writes = share.cacheWriteTokens.formatted(.number.locale(locale))
            lines.append(localized("Fresh includes \(writes) cache-write tokens.", locale: locale))
        }
        if share.reasoningTokens > 0 {
            let reasoning = share.reasoningTokens.formatted(.number.locale(locale))
            lines.append(localized("Output includes \(reasoning) reasoning tokens.", locale: locale))
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Grouped evidence

    /// Session-owned requests grouped by pricing identity, in first-seen order.
    /// Delegated work is excluded: it is priced against its own transcript.
    static func pricingBasis(_ telemetry: SessionTelemetry,
                              capability: TelemetryCapability? = nil) -> [TelemetryPricingBasis] {
        if case .unavailable = capability { return [] }
        if telemetry.usageSummary?.unavailableReason != nil { return [] }
        struct Key: Hashable {
            let model: String?
            let speed: String
            let geo: String?
        }
        var order: [Key] = []
        var grouped: [Key: [TelemetryUsageEvent]] = [:]
        for event in telemetry.usageEvents where event.ownership == .session {
            let key = Key(model: event.model, speed: event.speed, geo: event.inferenceGeo)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(event)
        }
        return order.map { key in
            let events = grouped[key] ?? []
            let contexts = events.compactMap(\.contextInputTokens)
            return TelemetryPricingBasis(model: key.model,
                                         speed: key.speed,
                                         inferenceGeo: key.geo,
                                         requestCount: events.count,
                                         minContextInputTokens: contexts.min(),
                                         maxContextInputTokens: contexts.max())
        }
    }

    /// nil when the bar must not be drawn: no session-owned usage, no component
    /// breakdown (legacy total-only logs), or a zero total.
    static func tokenShare(_ telemetry: SessionTelemetry) -> TelemetryTokenShare? {
        guard telemetry.usageSummary?.unavailableReason == nil else { return nil }
        guard telemetry.usageSummary?.hasComponentBreakdown == true else { return nil }
        let owned = telemetry.usageEvents.filter { $0.ownership == .session }
        guard !owned.isEmpty else { return nil }
        let writes = owned.reduce(0) { $0 + $1.cacheWrite5mTokens + $1.cacheWrite1hTokens }
        let share = TelemetryTokenShare(
            cached: owned.reduce(0) { $0 + $1.cacheReadTokens },
            fresh: owned.reduce(0) { $0 + $1.freshInputTokens } + writes,
            output: owned.reduce(0) { $0 + $1.outputTokens },
            cacheWriteTokens: writes,
            reasoningTokens: owned.reduce(0) { $0 + $1.reasoningOutputTokens })
        return share.total > 0 ? share : nil
    }

    /// Both full parsers use SHA256(path)-<one-based reader index>, with
    /// optional Claude content suffixes. Never interpret timestamps as ordering.
    static func recordIndex(eventID: String) -> Int? {
        let parts = eventID.split(separator: "-")
        guard parts.count >= 2, parts[0].count == 64,
              parts[0].allSatisfy({ $0.isHexDigit }), let number = Int(parts[1]), number > 0 else { return nil }
        return number - 1
    }

    /// (record index, block index) pairs for every non-meta block, in block order.
    /// Meta blocks are excluded because a marker attached to one would render
    /// inside chrome rather than beside a message.
    static func anchors(_ blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [(record: Int, block: Int)] {
        blocks.filter { $0.kind != .meta }.compactMap { block -> (record: Int, block: Int)? in
            guard let index = recordIndex(eventID: block.eventID) else { return nil }
            return (index, block.globalBlockIndex)
        }
    }

    /// The block a change's marker belongs on: the first block at or after the
    /// change's record, or a trailing anchor past the end when the change happened
    /// after the final message. Single source of truth for both the inline markers
    /// and the history timeline, so a jump can never land where no marker is.
    static func anchorBlockIndex(change: ConfigurationChange,
                                 anchors: [(record: Int, block: Int)],
                                 blockCount: Int) -> Int? {
        guard !anchors.isEmpty else { return nil }
        return anchors.first(where: { $0.record >= change.anchorLine })?.block ?? blockCount
    }

    static func markers(changes: [ConfigurationChange],
                        blocks: [SessionTranscriptBuilder.LogicalBlock],
                        locale: Locale = .current) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        let anchors = Self.anchors(blocks)
        for change in changes {
            guard let target = anchorBlockIndex(change: change, anchors: anchors,
                                                blockCount: blocks.count) else { continue }
            let timestamp = change.observedAt.map { AppDateFormatting.transcriptTimestamp($0) + " · " } ?? ""
            result[target, default: []].append(timestamp + Self.change(change, locale: locale))
        }
        return result
    }

    /// The started baseline (when one is known) followed by every recorded change,
    /// in transcript order.
    static func historyRows(telemetry: SessionTelemetry,
                            blocks: [SessionTranscriptBuilder.LogicalBlock],
                            locale: Locale = .current) -> [SessionInfoHistoryRow] {
        var rows: [SessionInfoHistoryRow] = []
        let anchors = Self.anchors(blocks)
        if let initial = telemetry.initialConfiguration,
           initial.model != nil || initial.reasoningEffort != nil {
            rows.append(SessionInfoHistoryRow(
                id: 0,
                kind: .started,
                title: localized("Started \(configuration(initial))", locale: locale),
                observedAt: initial.observedAt,
                isInferred: initial.provenance == .inferredFirstObservation,
                blockIndex: anchors.first?.block))
        }
        for (offset, change) in telemetry.configurationChanges.enumerated() {
            let old = change.oldValue ?? "—"
            let new = change.newValue ?? "—"
            let title = change.field == .model
                ? localized("Model \(old) → \(new)", locale: locale)
                : localized("Thinking effort \(old) → \(new)", locale: locale)
            rows.append(SessionInfoHistoryRow(
                id: offset + 1,
                kind: .change,
                title: title,
                observedAt: change.observedAt,
                isInferred: false,
                blockIndex: anchorBlockIndex(change: change, anchors: anchors,
                                             blockCount: blocks.count)))
        }
        return rows
    }

    static func historySubtitle(_ row: SessionInfoHistoryRow,
                                locale: Locale = .current) -> String {
        let time = row.observedAt.map { AppDateFormatting.transcriptTimestamp($0) }
            ?? localized("Time not recorded", locale: locale)
        return row.isInferred
            ? localized("\(time) · inferred", locale: locale)
            : time
    }

    static func pricedOnBasisHelp(_ requestCount: Int,
                                  locale: Locale = .current) -> String {
        localized("\(requestCount) request priced on this basis.", locale: locale)
    }

    static func delegatedSummary(compactTokens: String,
                                 requestCount: Int,
                                 locale: Locale = .current) -> String {
        localized("\(compactTokens) · \(requestCount) requests", locale: locale)
    }

    static func delegatedHelp(tokens: Int,
                              requestCount: Int,
                              locale: Locale = .current) -> String {
        let formattedTokens = tokens.formatted(.number.locale(locale))
        return localized(
            "\(formattedTokens) tokens across \(requestCount) requests, recorded here but excluded from the totals above. The transcript does not identify which subagent each request belongs to — open a subagent session for its own configuration and cost.",
            locale: locale)
    }

    static func turnsSummary(you: Int, agent: Int, tools: Int,
                             locale: Locale = .current) -> String {
        localized("\(you) you \u{00B7} \(agent) agent \u{00B7} \(tools) tools", locale: locale)
    }

    static func turnsHelp(you: Int, agent: Int, tools: Int, requests: Int,
                          usageUnavailableReason: String? = nil,
                          locale: Locale = .current) -> String {
        let requestText = usageUnavailableReason.map {
            "Request total unavailable: \($0)."
        } ?? "The transcript records \(requests) requests — a single turn can span several."
        return localized(
            "Blocks in this transcript: \(you) from you, \(agent) from the agent, \(tools) tool calls. \(requestText)",
            locale: locale)
    }
}

private func localizedRequestCount(_ count: Int, locale: Locale = .current) -> String {
    String(localized: "\(count) request",
           locale: locale,
           comment: "Count of requests represented by a Session info summary or pricing row.")
}

struct TranscriptTelemetryView: View {
    /// Wide enough that the longest routine values — "gpt-5.6-sol · medium",
    /// "$145.54 API-equivalent", the three-part token legend — never wrap or cut.
    static let panelWidth: CGFloat = 300

    let quickFacts: SessionInfoQuickFacts?
    @Binding var quickInfoPaintState: SessionInfoQuickPaintState
    let telemetry: SessionTelemetry?
    let telemetryLoadState: SessionInfoTelemetryLoadState
    let blocks: [SessionTranscriptBuilder.LogicalBlock]
    let loading: Bool
    let isSubagent: Bool
    /// Delegated usage records in this transcript. The telemetry carries no
    /// subagent identity — `ownership` is a boolean split from Claude's
    /// `isSidechain` flag — so this counts REQUESTS, never agents. Correlating
    /// with child sessions in the index would invent a relationship the
    /// transcript does not state.
    let delegatedRequestCount: Int
    /// nil in Terminal and JSON modes, and while the transcript snapshot still
    /// belongs to a previously selected session.
    let jumpToBlock: ((Int) -> Void)?
    let lastUpdatedAt: Date?
    let refresh: () -> Void
    let close: () -> Void

    @AppStorage("SessionInfoBasisExpanded") private var basisExpanded = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.md) {
                    if let quickFacts {
                        quickInfo(quickFacts, telemetry: telemetry)
                        Divider()
                    }
                    if let telemetry {
                        summary(telemetry)
                        Divider()
                        facts(telemetry, quickFacts: quickFacts)
                        Divider()
                        activity(telemetry)
                        if TranscriptTelemetryPresentation.shouldShowHistory(telemetry) {
                            Divider()
                            history(telemetry)
                        }
                        Divider()
                        basis(telemetry)
                    } else if loading {
                        Text("Loading detailed telemetry…")
                            .font(SessionInfoType.row)
                            .foregroundStyle(.secondary)
                    } else if quickFacts != nil {
                        Text("Detailed telemetry is unavailable for this source or transcript.")
                            .font(SessionInfoType.row)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No supported telemetry, or the transcript could not be read.")
                            .font(SessionInfoType.row)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(LayoutTokens.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Surface.chrome)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Session info").font(.headline)
                if let lastUpdatedAt {
                    Text("Updated \(lastUpdatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                        .help("Session info updates only when you select a session or choose Refresh.")
                } else if loading {
                    Text("Updating…")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Refresh", action: refresh)
                .buttonStyle(.link)
                .font(SessionInfoType.row)
                .disabled(loading)
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Hide Session info (⇧⌘I)")
        }
        .padding(LayoutTokens.md)
    }

    /// One hero (cost) and one subhero (tokens). Two large numbers read as two
    /// competing answers; the token count explains the cost, so it sits under it.
    private func summary(_ telemetry: SessionTelemetry) -> some View {
        let cost = TranscriptTelemetryPresentation.costValue(
            telemetry,
            capability: SessionSourceRegistry.descriptor(for: telemetry.source).telemetry.cost,
            locale: locale)
        let tokens = TranscriptTelemetryPresentation.tokensValue(telemetry, locale: locale)
        let share = TranscriptTelemetryPresentation.tokenShare(telemetry)
        let requests = telemetry.usageEvents.filter { $0.ownership == .session }.count
        return VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.sm) {
                Text(verbatim: cost.text)
                    .font(SessionInfoType.hero)
                    .monospacedDigit()
                    .foregroundStyle(cost.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text("API-equivalent")
                    .font(SessionInfoType.row)
                    .foregroundStyle(.secondary)
            }
            .help(cost.help)

            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: LayoutTokens.xs) {
                    Text(verbatim: tokens.text)
                        .font(SessionInfoType.subhero)
                        .monospacedDigit()
                        .foregroundStyle(tokens.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text("tokens")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if requests > 0,
                   telemetry.usageSummary?.unavailableReason == nil,
                   telemetry.usageSummary?.hasComponentBreakdown == true {
                    Text(verbatim: localizedRequestCount(requests, locale: locale))
                        .font(SessionInfoType.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help(tokens.help)

            if let share {
                TokenShareBar(share: share)
            }
        }
    }

    private func quickInfo(_ facts: SessionInfoQuickFacts,
                           telemetry: SessionTelemetry?) -> some View {
        SessionInfoSection(title: "Quick info") {
            VStack(alignment: .leading, spacing: LayoutTokens.xs) {
                SessionInfoRow(label: "Agent",
                               value: TranscriptTelemetryPresentation.sourceValue(
                                facts.source, locale: locale))
                SessionInfoRow(label: "Current model",
                               value: TranscriptTelemetryPresentation.quickFactValue(
                                facts.currentModel, locale: locale))
                    .onAppear {
                        recordModelFirstPaintIfNeeded(facts)
                    }
                    .onChange(of: facts.currentModel) { _, _ in
                        recordModelFirstPaintIfNeeded(facts)
                    }
                SessionInfoRow(label: "First observed model",
                               value: TranscriptTelemetryPresentation.firstObservedModelValue(
                                facts,
                                telemetry: telemetry,
                                telemetryLoadState: telemetryLoadState,
                                locale: locale))
                SessionInfoRow(label: "Thinking",
                               value: TranscriptTelemetryPresentation.quickFactValue(
                                facts.reasoningEffort, locale: locale))
                SessionInfoRow(label: "Title",
                               value: TranscriptTelemetryPresentation.titleValue(
                                facts.title, locale: locale))
            }
        }
        // The parent arms the paint episode from the selection task. Observe
        // that state as well as the facts so a new selection is measured even
        // when the replacement session exposes the same current model and the
        // row therefore has no model-value change to trigger its hook.
        .onChange(of: quickInfoPaintState.identity) { _, _ in
            recordModelFirstPaintIfNeeded(facts)
        }
        .onChange(of: facts.paintIdentity) { _, _ in
            recordModelFirstPaintIfNeeded(facts)
        }
    }

    private func recordModelFirstPaintIfNeeded(_ facts: SessionInfoQuickFacts) {
        guard let duration = quickInfoPaintState.recordModelFirstPaintIfNeeded(
            identity: facts.paintIdentity,
            modelIsKnown: facts.currentModel.value != nil,
            at: Date()) else { return }
        SessionInfoMetrics.shared.recordModelFirstPaint(duration: duration)
    }

    private func facts(_ telemetry: SessionTelemetry,
                       quickFacts: SessionInfoQuickFacts?) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.xs) {
            if let model = telemetry.currentConfiguration?.model,
               !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SessionInfoRow(
                    label: quickFacts == nil
                        ? (isSubagent ? "Subagent model" : "Model")
                        : "Transcript current model",
                    value: TranscriptTelemetryPresentation.modelValue(
                        telemetry.currentConfiguration, locale: locale))
            }
            if let thinking = TranscriptTelemetryPresentation.thinkingValue(
                telemetry.currentConfiguration, locale: locale) {
                SessionInfoRow(
                    label: quickFacts == nil ? "Thinking" : "Transcript thinking",
                    value: thinking)
            }
            // Delegated does NOT keep its row. A permanent em dash teaches the
            // reader to ignore the line, and for a provider that cannot record
            // delegated work the dash is permanent by construction.
            if let delegated = delegatedValue(telemetry) {
                SessionInfoRow(label: "Delegated to subagents", value: delegated)
            }
        }
    }

    /// nil when the row must not be drawn at all — this transcript records no
    /// delegated work, either because the session delegated none or because the
    /// provider cannot express it. Both are the unremarkable default; only the
    /// exception is worth a line.
    private func delegatedValue(_ telemetry: SessionTelemetry) -> TranscriptTelemetryPresentation.Value? {
        guard let descendants = telemetry.descendantTopLineTokens else { return nil }
        let compact = descendants.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        return .init(
            text: TranscriptTelemetryPresentation.delegatedSummary(
                compactTokens: compact, requestCount: delegatedRequestCount, locale: locale),
            help: TranscriptTelemetryPresentation.delegatedHelp(
                tokens: descendants, requestCount: delegatedRequestCount, locale: locale))
    }

    /// What the session spent its time on. Every figure here comes from this
    /// transcript's own records — no cross-session aggregate is involved.
    private func activity(_ telemetry: SessionTelemetry) -> some View {
        let summary = TranscriptTelemetryPresentation.activity(telemetry, blocks: blocks)
        return SessionInfoSection(title: "Activity") {
            VStack(alignment: .leading, spacing: LayoutTokens.xs) {
                SessionInfoRow(label: "Transcript span", value: spanValue(summary))
                SessionInfoRow(label: "Turns", value: turnsValue(summary))
            }
        }
    }

    private func spanValue(_ summary: TranscriptTelemetryPresentation.ActivitySummary)
        -> TranscriptTelemetryPresentation.Value {
        guard let span = summary.span, let first = summary.firstRequestAt,
              let last = summary.lastRequestAt else {
            if let reason = summary.usageUnavailableReason {
                return .absent(TranscriptTelemetryPresentation.localized(
                    "Request timing unavailable: \(reason)", locale: locale))
            }
            return .absent(TranscriptTelemetryPresentation.localized(
                "This transcript records fewer than two timed requests.", locale: locale))
        }
        var help = TranscriptTelemetryPresentation.localized(
            "First request \(first.formatted(date: .omitted, time: .shortened)), last \(last.formatted(date: .omitted, time: .shortened)). Wall clock between them, not time spent computing — neither provider records how long a request took.",
            locale: locale)
        if let pace = summary.secondsPerRequest {
            help += " " + TranscriptTelemetryPresentation.localized(
                "One request every \(TranscriptTelemetryPresentation.durationText(pace)) on average.",
                locale: locale)
        }
        return .init(text: TranscriptTelemetryPresentation.durationText(span), help: help)
    }

    private func turnsValue(_ summary: TranscriptTelemetryPresentation.ActivitySummary)
        -> TranscriptTelemetryPresentation.Value {
        guard summary.userBlocks + summary.assistantBlocks + summary.toolBlocks > 0 else {
            return .absent(TranscriptTelemetryPresentation.localized(
                "The transcript for this session is not loaded.", locale: locale))
        }
        return .init(
            text: TranscriptTelemetryPresentation.turnsSummary(
                you: summary.userBlocks, agent: summary.assistantBlocks,
                tools: summary.toolBlocks, locale: locale),
            help: TranscriptTelemetryPresentation.turnsHelp(
                you: summary.userBlocks, agent: summary.assistantBlocks,
                tools: summary.toolBlocks, requests: summary.requests,
                usageUnavailableReason: summary.usageUnavailableReason, locale: locale))
    }

    private func history(_ telemetry: SessionTelemetry) -> some View {
        SessionInfoSection(title: "History") {
            SessionInfoHistoryList(
                rows: TranscriptTelemetryPresentation.historyRows(
                    telemetry: telemetry, blocks: blocks, locale: locale),
                jump: jumpToBlock)
        }
    }

    private func basis(_ telemetry: SessionTelemetry) -> some View {
        let costCapability = SessionSourceRegistry.descriptor(for: telemetry.source).telemetry.cost
        return DisclosureGroup(isExpanded: $basisExpanded) {
            VStack(alignment: .leading, spacing: LayoutTokens.sm) {
                if case let .unavailable(reason) = costCapability {
                    Text("Pricing unavailable: \(reason)")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(TranscriptTelemetryPresentation.pricingBasis(
                        telemetry, capability: costCapability).enumerated()),
                            id: \.offset) { _, row in
                        SessionInfoRow(label: "Priced as", value: pricedAsValue(row))
                        SessionInfoRow(
                            label: "Region",
                            value: TranscriptTelemetryPresentation.inferenceGeoValue(
                                row.inferenceGeo, locale: locale)
                        )
                        SessionInfoRow(label: "Context in", value: contextValue(row))
                    }
                    if let cost = telemetry.costEstimate {
                        SessionInfoRow(label: "Price table",
                                       value: .init(text: cost.priceTableUpdated,
                                                    help: copy("Date of the price manifest used.")))
                        SessionInfoRow(label: "Revision",
                                       value: .init(text: "r…\(String(String(cost.priceTableRevision).suffix(6)))",
                                                    help: copy("Full revision: \(cost.priceTableRevision)")))
                        SessionInfoRow(label: "Manifest", value: manifestValue(cost))
                    }
                }
                if let weekly = telemetry.weeklyQuotaEstimate, weekly.status == .estimated {
                    // All five calibration fields stay visible: precision and the
                    // observed/reset timestamps are how a reader judges whether the
                    // percentage is worth anything, and a carried bootstrap ratio can
                    // be weeks older than the latest poll.
                    SessionInfoRow(label: "Quota source",
                                   value: weekly.sourceFamily.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0, help: copy("Which account window the calibration came from."))
                                   } ?? .absent(copy("No quota source recorded.")))
                    SessionInfoRow(label: "Precision",
                                   value: weekly.quotaPrecision.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0, help: copy("Granularity of the account quota reading behind this estimate."))
                                   } ?? .absent(copy("No quota precision recorded.")))
                    SessionInfoRow(label: "Calculated",
                                   value: .init(text: weekly.calculatedAt.formatted(date: .abbreviated, time: .shortened),
                                                help: copy("When this estimate was computed.")))
                    SessionInfoRow(label: "Quota observed",
                                   value: weekly.quotaObservedAt.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0.formatted(date: .abbreviated, time: .shortened),
                                           help: copy("When the account quota reading was taken. A carried calibration can be far older than this."))
                                   } ?? .absent(copy("No quota observation recorded.")))
                    SessionInfoRow(label: "Quota resets",
                                   value: weekly.quotaResetAt.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0.formatted(date: .abbreviated, time: .shortened),
                                           help: copy("End of the weekly window this estimate is a share of."))
                                   } ?? .absent(copy("No reset time recorded.")))
                }
                if costCapability.isAvailable {
                    Text("Cost is computed for each request from its model, speed, region and context size, then summed at published API rates. When Claude provides no usable inference geography, the published standard rate is used; an explicit US region receives regional pricing. “Standard” is a pricing assumption, not an observed service tier.")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
                if telemetry.initialConfiguration?.provenance == .inferredFirstObservation {
                    Text("Started configuration is inferred from the first record, not a session-start setting.")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, LayoutTokens.sm)
        } label: {
            Text("How this was estimated")
                .font(SessionInfoType.row)
                .foregroundStyle(.secondary)
        }
    }

    private func pricedAsValue(_ row: TelemetryPricingBasis) -> TranscriptTelemetryPresentation.Value {
        .init(text: "\(row.model ?? "—") · \(row.speed)",
              help: TranscriptTelemetryPresentation.pricedOnBasisHelp(
                row.requestCount, locale: locale))
    }

    private func contextValue(_ row: TelemetryPricingBasis) -> TranscriptTelemetryPresentation.Value {
        guard let low = row.minContextInputTokens, let high = row.maxContextInputTokens else {
            return .absent(copy("No request recorded its context size."))
        }
        let text = low == high
            ? low.formatted(.number.notation(.compactName))
            : "\(low.formatted(.number.notation(.compactName))) – \(high.formatted(.number.notation(.compactName)))"
        return .init(text: text,
                     help: copy("Context presented to each request: \(low.formatted(.number.locale(locale))) to \(high.formatted(.number.locale(locale))) tokens."))
    }

    private func manifestValue(_ cost: TelemetryCostEstimate) -> TranscriptTelemetryPresentation.Value {
        guard let fingerprint = cost.priceManifestFingerprint else {
            return .absent(copy("No manifest fingerprint recorded."))
        }
        let short = fingerprint.count > 16
            ? "\(fingerprint.prefix(8))…\(fingerprint.suffix(5))"
            : fingerprint
        return .init(text: String(short), help: fingerprint)
    }

    private func copy(_ resource: String.LocalizationValue) -> String {
        TranscriptTelemetryPresentation.localized(resource, locale: locale)
    }
}
