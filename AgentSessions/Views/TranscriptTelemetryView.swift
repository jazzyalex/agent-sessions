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

/// Keeps the expensive full-file telemetry read tied to the inspector's actual
/// visibility. Returning nil while hidden also keeps session-selection churn from
/// restarting the SwiftUI task merely because its underlying session key changed.
enum TranscriptTelemetryLoadRequest {
    static func key(isVisible: Bool, selectionKey: String, refresh: Int) -> String? {
        guard isVisible, selectionKey != "none" else { return nil }
        return "\(selectionKey)|\(refresh)"
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
        if let owned = telemetry.sessionOwnedTopLineTokens { return owned }
        // Some legacy Codex records contain only a total. Claude records with
        // no usage evidence must not become a plausible zero-token session.
        return telemetry.usageSummary?.recordedTotalTokens
    }

    // MARK: - Displayable values

    static func costValue(_ telemetry: SessionTelemetry, locale: Locale = .current) -> Value {
        if let dollars = telemetry.costEstimate?.apiEquivalentUSD {
            return Value(
                text: dollars.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                help: localized(
                    "API-equivalent estimate at published rates: \(dollars.formatted(.number.precision(.fractionLength(4)).locale(locale))) USD. Not a subscription charge.",
                    locale: locale))
        }
        let reasons = (telemetry.costEstimate?.unpricedModels ?? [])
            + (telemetry.costEstimate?.missingPriceComponents ?? [])
        return .absent(reasons.isEmpty
                       ? localized("No priceable usage was recorded in this transcript.", locale: locale)
                       : localized("No price entry for: \(reasons.joined(separator: ", "))", locale: locale))
    }

    static func weeklyValue(_ telemetry: SessionTelemetry, locale: Locale = .current) -> Value {
        if let estimate = telemetry.weeklyQuotaEstimate,
           estimate.status == .estimated, let points = estimate.percentPoints {
            return Value(text: "≈\(points.formatted(.number.precision(.fractionLength(2)).locale(locale)))%",
                         help: localized("Account-calibrated estimate of this session's share of the weekly allowance.", locale: locale))
        }
        return .absent(telemetry.weeklyQuotaEstimate?.unavailableReason
                       ?? localized("No compatible weekly calibration for this account.", locale: locale))
    }

    static func tokensValue(_ telemetry: SessionTelemetry, locale: Locale = .current) -> Value {
        guard let total = tokens(telemetry) else {
            return .absent(localized("This transcript records no usage.", locale: locale))
        }
        return Value(text: total.formatted(.number.locale(locale)),
                     help: localized("Fresh input, cached input, cache writes and output. Reasoning tokens are counted inside output.", locale: locale))
    }

    static func configurationValue(_ value: SessionConfiguration?, locale: Locale = .current) -> Value {
        guard let value, value.model != nil || value.reasoningEffort != nil else {
            return .absent(localized("This transcript records no model or effort setting.", locale: locale))
        }
        return Value(text: configuration(value),
                     help: value.provenance == .inferredFirstObservation
                         ? localized("Inferred from the first record, not a session-start setting.", locale: locale)
                         : localized("Recorded by the provider.", locale: locale))
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
    static func pricingBasis(_ telemetry: SessionTelemetry) -> [TelemetryPricingBasis] {
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
}

private func localizedRequestCount(_ count: Int, locale: Locale = .current) -> String {
    String(localized: "\(count) request",
           locale: locale,
           comment: "Count of requests represented by a Session info summary or pricing row.")
}

struct TranscriptTelemetryView: View {
    let telemetry: SessionTelemetry?
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
                    if let telemetry {
                        summary(telemetry)
                        Divider()
                        facts(telemetry)
                        Divider()
                        history(telemetry)
                        Divider()
                        basis(telemetry)
                    } else if loading {
                        Text("Loading session information…")
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
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Session info").font(.headline)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Hide Session info (⇧⌘I)")
        }
        .padding(LayoutTokens.md)
    }

    private var footer: some View {
        HStack {
            Text("Estimates, not billing")
                .font(SessionInfoType.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh", action: refresh)
                .buttonStyle(.link)
                .font(SessionInfoType.row)
                .disabled(loading)
        }
        .padding(.horizontal, LayoutTokens.md)
        .padding(.vertical, LayoutTokens.sm)
    }

    /// One hero (cost) and one subhero (tokens). Two large numbers read as two
    /// competing answers; the token count explains the cost, so it sits under it.
    private func summary(_ telemetry: SessionTelemetry) -> some View {
        let cost = TranscriptTelemetryPresentation.costValue(telemetry, locale: locale)
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
                    .font(SessionInfoType.caption)
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
                if requests > 0 {
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

    private func facts(_ telemetry: SessionTelemetry) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.xs) {
            SessionInfoRow(label: isSubagent ? "Subagent model" : "Model",
                           value: TranscriptTelemetryPresentation.configurationValue(
                            telemetry.currentConfiguration, locale: locale))
            SessionInfoRow(label: "Weekly quota",
                           value: TranscriptTelemetryPresentation.weeklyValue(telemetry, locale: locale))
            SessionInfoRow(label: "Delegated", value: delegatedValue(telemetry))
        }
    }

    private func delegatedValue(_ telemetry: SessionTelemetry) -> TranscriptTelemetryPresentation.Value {
        guard let descendants = telemetry.descendantTopLineTokens else {
            return .absent(TranscriptTelemetryPresentation.localized(
                "This session recorded no delegated work.", locale: locale))
        }
        let compact = descendants.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        return .init(
            text: TranscriptTelemetryPresentation.delegatedSummary(
                compactTokens: compact, requestCount: delegatedRequestCount, locale: locale),
            help: TranscriptTelemetryPresentation.delegatedHelp(
                tokens: descendants, requestCount: delegatedRequestCount, locale: locale))
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
        DisclosureGroup(isExpanded: $basisExpanded) {
            VStack(alignment: .leading, spacing: LayoutTokens.sm) {
                ForEach(Array(TranscriptTelemetryPresentation.pricingBasis(telemetry).enumerated()),
                        id: \.offset) { _, row in
                    SessionInfoRow(label: "Priced as", value: pricedAsValue(row))
                    SessionInfoRow(label: "Region",
                                   value: row.inferenceGeo.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0, help: "Provider-reported inference region.")
                                   } ?? .absent("The provider did not record an inference region."))
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
                if let weekly = telemetry.weeklyQuotaEstimate {
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
                Text("Cost is computed for each request from its model, speed, region and context size, then summed at published API rates. “Standard” is a pricing assumption, not an observed service tier.")
                    .font(SessionInfoType.caption)
                    .foregroundStyle(.secondary)
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
