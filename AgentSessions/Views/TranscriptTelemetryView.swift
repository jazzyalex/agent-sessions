import SwiftUI

/// Presentation only: never fills missing evidence from Session.model or a parent.
enum TranscriptTelemetryPresentation {
    static let visibilityKey = "ShowSessionInfo"

    static func configuration(_ value: SessionConfiguration?) -> String {
        "\(value?.model ?? "Unavailable (model not recorded)") · \(value?.reasoningEffort ?? "Unavailable (effort not recorded)")"
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

    static func cost(_ telemetry: SessionTelemetry) -> String {
        if let dollars = telemetry.costEstimate?.apiEquivalentUSD {
            return dollars.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))
        }
        let reasons = (telemetry.costEstimate?.unpricedModels ?? [])
            + (telemetry.costEstimate?.missingPriceComponents ?? [])
        return "Unavailable (\(reasons.isEmpty ? "no priceable usage recorded" : reasons.joined(separator: ", ")))"
    }

    static func weekly(_ telemetry: SessionTelemetry) -> String {
        if let estimate = telemetry.weeklyQuotaEstimate,
           estimate.status == .estimated, let points = estimate.percentPoints {
            return "≈\(points.formatted(.number.precision(.fractionLength(2...4))))%"
        }
        return "Unavailable (\(telemetry.weeklyQuotaEstimate?.unavailableReason ?? "no compatible weekly calibration"))"
    }

    /// Both full parsers use SHA256(path)-<one-based reader index>, with
    /// optional Claude content suffixes. Never interpret timestamps as ordering.
    static func recordIndex(eventID: String) -> Int? {
        let parts = eventID.split(separator: "-")
        guard parts.count >= 2, parts[0].count == 64,
              parts[0].allSatisfy({ $0.isHexDigit }), let number = Int(parts[1]), number > 0 else { return nil }
        return number - 1
    }

    static func markers(changes: [ConfigurationChange],
                        blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        let anchors = blocks.filter { $0.kind != .meta }.compactMap { block -> (Int, Int)? in
            guard let index = recordIndex(eventID: block.eventID) else { return nil }
            return (index, block.globalBlockIndex)
        }
        for change in changes {
            guard !anchors.isEmpty else { continue }
            let target = anchors.first(where: { $0.0 >= change.anchorLine }) ?? (change.anchorLine, blocks.count)
            let timestamp = change.observedAt.map { AppDateFormatting.transcriptTimestamp($0) + " · " } ?? ""
            result[target.1, default: []].append(timestamp + Self.change(change))
        }
        return result
    }
}

struct TranscriptTelemetryView: View {
    let telemetry: SessionTelemetry?
    let loading: Bool
    let isSubagent: Bool
    let refresh: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session info").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Hide Session info (⇧⌘I)")
            }
            .padding(LayoutTokens.md)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.md) {
                    if let telemetry {
                        VStack(alignment: .leading, spacing: LayoutTokens.sm) {
                            Text(isSubagent ? "Subagent configuration" : "Configuration").fontWeight(.semibold)
                            Text("Started: \(TranscriptTelemetryPresentation.configuration(telemetry.initialConfiguration))")
                            Text("Current: \(TranscriptTelemetryPresentation.configuration(telemetry.currentConfiguration))")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: LayoutTokens.sm) {
                            Text("Usage").fontWeight(.semibold)
                            Text("Tokens: \(TranscriptTelemetryPresentation.tokens(telemetry).map { $0.formatted() } ?? "Unavailable (tokens not recorded)")")
                            Text("API-equivalent: \(TranscriptTelemetryPresentation.cost(telemetry))")
                            Text("Weekly quota: \(TranscriptTelemetryPresentation.weekly(telemetry))")
                        }
                        DisclosureGroup("Usage details") { details(telemetry) }
                    } else {
                        Text(loading ? "Loading session information…" : "Unavailable (no supported telemetry or transcript could not be read)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
                .padding(LayoutTokens.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button("Refresh session info", action: refresh)
                .disabled(loading)
                .padding(LayoutTokens.md)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func details(_ telemetry: SessionTelemetry) -> some View {
        let owned = telemetry.usageEvents.filter { $0.ownership == .session }
        return VStack(alignment: .leading, spacing: LayoutTokens.sm) {
            Text("This transcript’s own usage. API-equivalent cost is an estimate at published API rates, not a subscription charge. Weekly quota is an account-calibrated estimate.")
            if telemetry.initialConfiguration?.provenance == .inferredFirstObservation {
                Text("Started configuration is inferred from the first observation; it is not a recorded session-start setting.")
            }
            if !owned.isEmpty, telemetry.usageSummary?.hasComponentBreakdown == true {
                Text("Fresh input: \(owned.reduce(0) { $0 + $1.freshInputTokens }.formatted())")
                Text("Cached input: \(owned.reduce(0) { $0 + $1.cacheReadTokens }.formatted())")
                Text("Cache writes (5m / 1h): \(owned.reduce(0) { $0 + $1.cacheWrite5mTokens }.formatted()) / \(owned.reduce(0) { $0 + $1.cacheWrite1hTokens }.formatted())")
                Text("Output: \(owned.reduce(0) { $0 + $1.outputTokens }.formatted())")
                Text("Recorded reasoning: \(owned.reduce(0) { $0 + $1.reasoningOutputTokens }.formatted()) (included in output; zero can mean no separate reasoning detail)")
            } else {
                Text("Token breakdown: Unavailable (components not recorded)")
            }
            if let descendants = telemetry.descendantTopLineTokens {
                Text("Delegated usage recorded here: \(descendants.formatted()) tokens, excluded from this summary. Open each subagent for its own configuration and cost.")
            }
            if let cost = telemetry.costEstimate {
                Text("Price table: \(cost.priceTableUpdated), revision \(cost.priceTableRevision)")
                Text("Manifest: \(cost.priceManifestFingerprint ?? "Unavailable (not recorded)")")
            }
            Text("Pricing uses each request’s model, speed, inference region and context input before summing. Standard-normalized is a pricing assumption, not an observed service tier.")
            ForEach(Array(Set(owned.map { event in
                "\(event.model ?? "Unavailable model") · \(event.speed) · region: \(event.inferenceGeo ?? "not recorded") · context input: \(event.contextInputTokens.map { $0.formatted() } ?? "Unavailable")"
            })).sorted(), id: \.self) { basis in
                Text(basis)
            }
            if let weekly = telemetry.weeklyQuotaEstimate {
                Text("Quota source: \(weekly.sourceFamily ?? "Unavailable") · precision: \(weekly.quotaPrecision ?? "Unavailable")")
                Text("Calculated: \(weekly.calculatedAt.formatted())")
                if let observed = weekly.quotaObservedAt { Text("Quota observed: \(observed.formatted())") }
                if let reset = weekly.quotaResetAt { Text("Quota reset: \(reset.formatted())") }
            }
            if !telemetry.configurationChanges.isEmpty {
                Text("Configuration history").fontWeight(.semibold)
                ForEach(Array(telemetry.configurationChanges.enumerated()), id: \.offset) { _, change in
                    Text("\(change.observedAt.map { $0.formatted() } ?? "Time unavailable") · \(TranscriptTelemetryPresentation.change(change)) · record \(change.anchorLine + 1)")
                }
            }
        }
    }
}
