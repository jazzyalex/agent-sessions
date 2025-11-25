import SwiftUI

// Compact footer usage strip for Codex usage only
struct UsageStripView: View {
    @ObservedObject var codexStatus: CodexUsageModel
    // Optional label shown on the left (used in Unified window)
    var label: String? = nil
    var brandColor: Color = .accentColor
    var labelWidth: CGFloat? = 56
    var verticalPadding: CGFloat = 6
    var drawBackground: Bool = true
    var collapseTop: Bool = false
    var collapseBottom: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if let label {
                    Text(label)
                        .font(.footnote).bold()
                        .foregroundStyle(stripMonochrome ? Color.secondary : brandColor)
                        .frame(width: labelWidth, alignment: .leading)
                }
                UsageMeter(title: "5h", percent: codexStatus.fiveHourRemainingPercent, reset: codexStatus.fiveHourResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)
                UsageMeter(title: "Wk", percent: codexStatus.weekRemainingPercent, reset: codexStatus.weekResetText, lastUpdate: codexStatus.lastUpdate, eventTimestamp: codexStatus.lastEventTimestamp)
                Spacer(minLength: 0)
                if codexStatus.isUpdating {
                    UpdatingBadge()
                } else if let eff = effectiveEventTimestamp(source: .codex, eventTimestamp: codexStatus.lastEventTimestamp, lastUpdate: codexStatus.lastUpdate),
                          Date().timeIntervalSince(eff) > 30 * 60 {
                    Text("Last updated: \(timeAgo(eff))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, collapseTop ? 0 : verticalPadding)
        .padding(.bottom, collapseBottom ? 0 : verticalPadding)
        .background(drawBackground ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear))
        .onTapGesture(count: 2) {
            if !codexStatus.isUpdating {
                codexStatus.refreshNow()
            }
        }
        .help(makeTooltip())
        .onAppear { codexStatus.setStripVisible(true) }
        .onDisappear { codexStatus.setStripVisible(false) }
    }

    private func makeTooltip() -> String {
        var parts: [String] = []

        if let lastUpdate = codexStatus.lastUpdate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relativeTime = formatter.localizedString(for: lastUpdate, relativeTo: Date())
            parts.append("Codex: Updated \(relativeTime)")
        } else {
            parts.append("Codex: Not yet updated")
        }

        // Add token breakdown if available
        if let input = codexStatus.lastInputTokens,
           let cached = codexStatus.lastCachedInputTokens,
           let output = codexStatus.lastOutputTokens {
            let nonCached = max(0, input - cached)
            var tokenLine = "Last turn: \(nonCached) input"
            if cached > 0 {
                tokenLine += " + \(cached) cached"
            }
            tokenLine += " + \(output) output"
            if let reasoning = codexStatus.lastReasoningOutputTokens, reasoning > 0 {
                tokenLine += " + \(reasoning) reasoning"
            }
            parts.append(tokenLine)
            if cached > 0 {
                parts.append("(Cached tokens are reused from conversation history)")
            }
        }

        parts.append("Double-click to refresh now")

        return parts.joined(separator: "\n")
    }
}

struct UpdatingBadge: View {
    @State private var rotate = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: rotate)
                .onAppear { rotate = true }
            Text("Updating")
                .font(.caption)
        }
        .foregroundStyle(.primary)
    }
}

private struct UsageMeter: View {
    let title: String
    let percent: Int
    let reset: String
    let lastUpdate: Date?
    let eventTimestamp: Date?
    @AppStorage("StripShowResetTime") private var showResetTime: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    var body: some View {
        let includeReset = showResetTime
        // Use unified freshness helper to smooth manual refresh TTL.
        let effectiveEvent = effectiveEventTimestamp(source: .codex, eventTimestamp: eventTimestamp, lastUpdate: lastUpdate)
        let stale = isResetInfoStale(kind: title, source: .codex, lastUpdate: lastUpdate, eventTimestamp: effectiveEvent)
        let displayText = (stale || reset.isEmpty)
            ? UsageStaleThresholds.outdatedCopy
            : formattedReset(reset)

        HStack(spacing: UsageMeterLayout.itemSpacing) {
            Text(title)
                .font(.footnote).bold()
                .frame(width: UsageMeterLayout.titleWidth, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .tint(stripMonochrome ? .secondary : .accentColor)
                .frame(width: UsageMeterLayout.progressWidth)
            Text("\(percent)%")
                .font(.footnote)
                .monospacedDigit()
                .frame(width: UsageMeterLayout.percentWidth, alignment: .trailing)
            if includeReset {
                Text(displayText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: UsageMeterLayout.resetWidth, alignment: .leading)
                    .lineLimit(1)
            }
        }
        .frame(width: UsageMeterLayout.totalWidth(includeReset: includeReset), alignment: .leading)
        .help(reset.isEmpty ? "" : reset)
    }

    private func formattedReset(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Strip timezone like "(America/Los_Angeles)"
        if let idx = s.firstIndex(of: "(") { s = String(s[..<idx]).trimmingCharacters(in: .whitespaces) }
        // Ensure prefix
        let lower = s.lowercased()
        if lower.hasPrefix("reset") || lower.hasPrefix("resets") {
            return s
        }
        return "resets " + s
    }
}

// Detail popover removed; tooltips provide reset info.

private func timeAgo(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval/60))m ago" }
    return "\(Int(interval/3600))h ago"
}

private enum UsageMeterLayout {
    static let itemSpacing: CGFloat = 6
    static let titleWidth: CGFloat = 28
    static let progressWidth: CGFloat = 140
    static let percentWidth: CGFloat = 36
    static let resetWidth: CGFloat = 160

    static func totalWidth(includeReset: Bool) -> CGFloat {
        let base = titleWidth + progressWidth + percentWidth
        let spacingCount: CGFloat = includeReset ? 3 : 2
        let resetComponent: CGFloat = includeReset ? resetWidth : 0
        return base + resetComponent + itemSpacing * spacingCount
    }
}
