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

/// Presentation only: never fills missing evidence from Session.model or a parent.
enum TranscriptTelemetryPresentation {
    static let visibilityKey = "ShowSessionInfo"

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

    static func change(_ value: ConfigurationChange) -> String {
        let field = value.field == .model ? "Model changed" : "Thinking effort changed"
        return "\(field): \(value.oldValue ?? "Unavailable") → \(value.newValue ?? "Unavailable")"
    }

    static func tokens(_ telemetry: SessionTelemetry) -> Int? {
        if let owned = telemetry.sessionOwnedTopLineTokens { return owned }
        // Some legacy Codex records contain only a total. Claude records with
        // no usage evidence must not become a plausible zero-token session.
        return telemetry.usageSummary?.recordedTotalTokens
    }

    // MARK: - Displayable values

    static func costValue(_ telemetry: SessionTelemetry) -> Value {
        if let dollars = telemetry.costEstimate?.apiEquivalentUSD {
            return Value(
                text: dollars.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                help: "API-equivalent estimate at published rates: "
                    + dollars.formatted(.number.precision(.fractionLength(4)))
                    + " USD. Not a subscription charge.")
        }
        let reasons = (telemetry.costEstimate?.unpricedModels ?? [])
            + (telemetry.costEstimate?.missingPriceComponents ?? [])
        return .absent(reasons.isEmpty
                       ? "No priceable usage was recorded in this transcript."
                       : "No price entry for: " + reasons.joined(separator: ", "))
    }

    static func weeklyValue(_ telemetry: SessionTelemetry) -> Value {
        if let estimate = telemetry.weeklyQuotaEstimate,
           estimate.status == .estimated, let points = estimate.percentPoints {
            return Value(text: "≈\(points.formatted(.number.precision(.fractionLength(2))))%",
                         help: "Account-calibrated estimate of this session's share of the weekly allowance.")
        }
        return .absent(telemetry.weeklyQuotaEstimate?.unavailableReason
                       ?? "No compatible weekly calibration for this account.")
    }

    static func tokensValue(_ telemetry: SessionTelemetry) -> Value {
        guard let total = tokens(telemetry) else {
            return .absent("This transcript records no usage.")
        }
        return Value(text: total.formatted(),
                     help: "Fresh input, cached input, cache writes and output. Reasoning tokens are counted inside output.")
    }

    static func configurationValue(_ value: SessionConfiguration?) -> Value {
        guard let value, value.model != nil || value.reasoningEffort != nil else {
            return .absent("This transcript records no model or effort setting.")
        }
        return Value(text: configuration(value),
                     help: value.provenance == .inferredFirstObservation
                         ? "Inferred from the first record, not a session-start setting."
                         : "Recorded by the provider.")
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
                        blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        let anchors = Self.anchors(blocks)
        for change in changes {
            guard let target = anchorBlockIndex(change: change, anchors: anchors,
                                                blockCount: blocks.count) else { continue }
            let timestamp = change.observedAt.map { AppDateFormatting.transcriptTimestamp($0) + " · " } ?? ""
            result[target, default: []].append(timestamp + Self.change(change))
        }
        return result
    }

    /// The started baseline (when one is known) followed by every recorded change,
    /// in transcript order.
    static func historyRows(telemetry: SessionTelemetry,
                            blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [SessionInfoHistoryRow] {
        var rows: [SessionInfoHistoryRow] = []
        let anchors = Self.anchors(blocks)
        if let initial = telemetry.initialConfiguration,
           initial.model != nil || initial.reasoningEffort != nil {
            rows.append(SessionInfoHistoryRow(
                id: 0,
                kind: .started,
                title: "Started " + configuration(initial),
                observedAt: initial.observedAt,
                isInferred: initial.provenance == .inferredFirstObservation,
                blockIndex: anchors.first?.block))
        }
        for (offset, change) in telemetry.configurationChanges.enumerated() {
            let field = change.field == .model ? "Model" : "Thinking effort"
            rows.append(SessionInfoHistoryRow(
                id: offset + 1,
                kind: .change,
                title: "\(field) \(change.oldValue ?? "—") → \(change.newValue ?? "—")",
                observedAt: change.observedAt,
                isInferred: false,
                blockIndex: anchorBlockIndex(change: change, anchors: anchors,
                                             blockCount: blocks.count)))
        }
        return rows
    }
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
                    } else {
                        Text(loading
                             ? "Loading session information…"
                             : "No supported telemetry, or the transcript could not be read.")
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
        let cost = TranscriptTelemetryPresentation.costValue(telemetry)
        let tokens = TranscriptTelemetryPresentation.tokensValue(telemetry)
        let share = TranscriptTelemetryPresentation.tokenShare(telemetry)
        let requests = telemetry.usageEvents.filter { $0.ownership == .session }.count
        return VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.sm) {
                Text(cost.text)
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
                    Text(tokens.text)
                        .font(SessionInfoType.subhero)
                        .monospacedDigit()
                        .foregroundStyle(tokens.text == "—" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text("tokens")
                        .font(SessionInfoType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if requests > 0 {
                    Text("\(requests) request\(requests == 1 ? "" : "s")")
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
                           value: TranscriptTelemetryPresentation.configurationValue(telemetry.currentConfiguration))
            SessionInfoRow(label: "Weekly quota",
                           value: TranscriptTelemetryPresentation.weeklyValue(telemetry))
            SessionInfoRow(label: "Delegated", value: delegatedValue(telemetry))
        }
    }

    private func delegatedValue(_ telemetry: SessionTelemetry) -> TranscriptTelemetryPresentation.Value {
        guard let descendants = telemetry.descendantTopLineTokens else {
            return .absent("This session recorded no delegated work.")
        }
        let compact = descendants.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        let requests = "\(delegatedRequestCount) request\(delegatedRequestCount == 1 ? "" : "s")"
        return .init(text: "\(compact) · \(requests)",
                     help: "\(descendants.formatted()) tokens across \(requests), recorded here but excluded from the totals above. The transcript does not identify which subagent each request belongs to — open a subagent session for its own configuration and cost.")
    }

    private func history(_ telemetry: SessionTelemetry) -> some View {
        SessionInfoSection(title: "History") {
            SessionInfoHistoryList(
                rows: TranscriptTelemetryPresentation.historyRows(telemetry: telemetry, blocks: blocks),
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
                                                help: "Date of the price manifest used."))
                    SessionInfoRow(label: "Revision",
                                   value: .init(text: "r…\(String(String(cost.priceTableRevision).suffix(6)))",
                                                help: "Full revision: \(cost.priceTableRevision)"))
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
                                           text: $0, help: "Which account window the calibration came from.")
                                   } ?? .absent("No quota source recorded."))
                    SessionInfoRow(label: "Precision",
                                   value: weekly.quotaPrecision.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0, help: "Granularity of the account quota reading behind this estimate.")
                                   } ?? .absent("No quota precision recorded."))
                    SessionInfoRow(label: "Calculated",
                                   value: .init(text: weekly.calculatedAt.formatted(date: .abbreviated, time: .shortened),
                                                help: "When this estimate was computed."))
                    SessionInfoRow(label: "Quota observed",
                                   value: weekly.quotaObservedAt.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0.formatted(date: .abbreviated, time: .shortened),
                                           help: "When the account quota reading was taken. A carried calibration can be far older than this.")
                                   } ?? .absent("No quota observation recorded."))
                    SessionInfoRow(label: "Quota resets",
                                   value: weekly.quotaResetAt.map {
                                       TranscriptTelemetryPresentation.Value(
                                           text: $0.formatted(date: .abbreviated, time: .shortened),
                                           help: "End of the weekly window this estimate is a share of.")
                                   } ?? .absent("No reset time recorded."))
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
              help: "\(row.requestCount) request\(row.requestCount == 1 ? "" : "s") priced on this basis.")
    }

    private func contextValue(_ row: TelemetryPricingBasis) -> TranscriptTelemetryPresentation.Value {
        guard let low = row.minContextInputTokens, let high = row.maxContextInputTokens else {
            return .absent("No request recorded its context size.")
        }
        let text = low == high
            ? low.formatted(.number.notation(.compactName))
            : "\(low.formatted(.number.notation(.compactName))) – \(high.formatted(.number.notation(.compactName)))"
        return .init(text: text,
                     help: "Context presented to each request: \(low.formatted()) to \(high.formatted()) tokens.")
    }

    private func manifestValue(_ cost: TelemetryCostEstimate) -> TranscriptTelemetryPresentation.Value {
        guard let fingerprint = cost.priceManifestFingerprint else {
            return .absent("No manifest fingerprint recorded.")
        }
        let short = fingerprint.count > 16
            ? "\(fingerprint.prefix(8))…\(fingerprint.suffix(5))"
            : fingerprint
        return .init(text: String(short), help: fingerprint)
    }
}
