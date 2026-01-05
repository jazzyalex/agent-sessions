import SwiftUI

struct QuotaData: Equatable {
    enum Provider: Equatable {
        case codex
        case claude

        var tint: Color {
            switch self {
            case .claude: return Color(hex: "d97757")
            case .codex: return .white
            }
        }

        var usageSource: UsageTrackingSource {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            }
        }
    }

    var provider: Provider
    /// Stored as percent remaining (\"left\"), consistent with usage models.
    var fiveHourRemainingPercent: Int
    var fiveHourResetText: String
    /// Stored as percent remaining (\"left\"), consistent with usage models.
    var weekRemainingPercent: Int
    var weekResetText: String

    @MainActor
    static func codex(from model: CodexUsageModel) -> QuotaData {
        QuotaData(
            provider: .codex,
            fiveHourRemainingPercent: model.fiveHourRemainingPercent,
            fiveHourResetText: model.fiveHourResetText,
            weekRemainingPercent: model.weekRemainingPercent,
            weekResetText: model.weekResetText
        )
    }

    @MainActor
    static func claude(from model: ClaudeUsageModel) -> QuotaData {
        QuotaData(
            provider: .claude,
            fiveHourRemainingPercent: model.sessionRemainingPercent,
            fiveHourResetText: model.sessionResetText,
            weekRemainingPercent: model.weekAllModelsRemainingPercent,
            weekResetText: model.weekAllModelsResetText
        )
    }
}

struct CockpitFooterView: View {
    @Environment(\.colorScheme) private var colorScheme

    let isBusy: Bool
    let statusText: String
    let quotas: [QuotaData]
    let sessionCountText: String
    let freshnessText: String?

    init(isBusy: Bool,
         statusText: String,
         quotas: [QuotaData],
         sessionCountText: String,
         freshnessText: String? = nil) {
        self.isBusy = isBusy
        self.statusText = statusText
        self.quotas = quotas
        self.sessionCountText = sessionCountText
        self.freshnessText = freshnessText
    }

    var body: some View {
        HStack(spacing: 10) {
            if isBusy, !statusText.isEmpty {
                IndexingStatusView(isBusy: true, text: statusText)
            }

            HStack(spacing: 10) {
                ForEach(Array(quotas.enumerated()), id: \.offset) { _, q in
                    QuotaWidget(data: q, isDarkMode: colorScheme == .dark)
                }
            }

            Spacer(minLength: 0)

            SessionCountView(text: sessionCountText, freshnessText: freshnessText)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(colorScheme == .dark ? Color(hex: "252526") : Color(hex: "007acc"))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.3))
                .frame(height: 1)
        }
    }
}

private struct IndexingStatusView: View {
    let isBusy: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            IndexingIndicator(isVisible: isBusy)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

private struct IndexingIndicator: View {
    let isVisible: Bool
    @State private var isAnimating: Bool = false

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.75)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .opacity(isVisible ? 1 : 0)
            .animation(isVisible ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                       value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

private struct QuotaWidget: View {
    let data: QuotaData
    let isDarkMode: Bool
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw: String = UsageDisplayMode.left.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: UsageDisplayMode { UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left }

    private var fiveHourLeftPercent: Int { clampPercent(data.fiveHourRemainingPercent) }
    private var weekLeftPercent: Int { clampPercent(data.weekRemainingPercent) }
    private var fiveHourUsedPercent: Int { clampPercent(100 - fiveHourLeftPercent) }
    private var weekUsedPercent: Int { clampPercent(100 - weekLeftPercent) }
    private var bottleneckUsedPercent: Int { max(fiveHourUsedPercent, weekUsedPercent) }

    private enum BottleneckKind { case fiveHour, week }
    private var bottleneckKind: BottleneckKind { (fiveHourUsedPercent >= weekUsedPercent) ? .fiveHour : .week }
    private var bottleneckLeftPercent: Int {
        switch bottleneckKind {
        case .fiveHour: return fiveHourLeftPercent
        case .week: return weekLeftPercent
        }
    }
    private var bottleneckFillPercent: Int {
        switch mode {
        case .left: return bottleneckLeftPercent
        case .used: return bottleneckUsedPercent
        }
    }
    private var isCritical: Bool {
        switch bottleneckKind {
        case .fiveHour:
            return fiveHourUsedPercent >= 80
        case .week:
            return weekUsedPercent >= 90
        }
    }

    private var fiveHourResetDate: Date? {
        UsageResetText.resetDate(kind: "5h", source: data.provider.usageSource, raw: data.fiveHourResetText)
    }

    private var weekResetDate: Date? {
        UsageResetText.resetDate(kind: "Wk", source: data.provider.usageSource, raw: data.weekResetText)
    }

    private var fiveHourResetDisplayText: String {
        let rel = formatRelativeTimeUntil(fiveHourResetDate)
        if rel != "—" { return "↻5h \(rel)" }
        let fallback = UsageResetText.displayText(kind: "5h", source: data.provider.usageSource, raw: data.fiveHourResetText)
        return fallback.isEmpty ? "↻5h —" : "↻5h \(fallback)"
    }

    private var weekResetDisplayText: String {
        let s = formatWeeklyReset(weekResetDate)
        if s != "—" { return "↻Wk \(s)" }
        let fallback = UsageResetText.displayText(kind: "Wk", source: data.provider.usageSource, raw: data.weekResetText)
        return fallback.isEmpty ? "↻Wk —" : "↻Wk \(fallback)"
    }

    private var fiveHourTimeRemainingText: String {
        formatHoursUntilReset(fiveHourResetDate)
    }

    private var weekPercentLabelText: String {
        let numeric = mode.numericPercent(fromLeft: data.weekRemainingPercent)
        return "Wk: \(numeric)%"
    }

    private var metricForeground: Color {
        isCritical ? .red : .white
    }

    private var barFillColor: Color {
        if isCritical { return .red }
        return .white
    }

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: data.provider)
                .frame(width: 14, height: 14)

            MiniUsageBar(
                percentFill: bottleneckFillPercent,
                percentUsed: bottleneckUsedPercent,
                tint: barFillColor,
                isDarkMode: isDarkMode,
                reduceMotion: reduceMotion
            )

            HStack(spacing: 6) {
                Text("5h: \(fiveHourTimeRemainingText)")
                DividerText()
                Text(weekPercentLabelText)
                DividerText()
                Text(fiveHourResetDisplayText)
                DividerText()
                Text(weekResetDisplayText)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(metricForeground)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color.white.opacity(isDarkMode ? 0.14 : 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(isDarkMode ? 0.10 : 0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    private func formatHoursUntilReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = max(0, date.timeIntervalSince(now))
        if interval < 60 { return "<1m" }
        let totalMinutes = Int(ceil(interval / 60.0))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours <= 0 { return "\(minutes)m" }
        if minutes <= 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private func formatRelativeTimeUntil(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = max(0, date.timeIntervalSince(now))
        if interval < 60 { return "<1m" }
        let totalMinutes = Int(ceil(interval / 60.0))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours <= 0 { return "\(minutes)m" }
        if minutes <= 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private func formatWeeklyReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        if interval >= 0, interval < 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        return AppDateFormatting.weekdayAbbrev(date)
    }
}

private struct DividerText: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("|")
            .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.30 : 0.25))
    }
}

private struct MiniUsageBar: View {
    let percentFill: Int
    let percentUsed: Int
    let tint: Color
    let isDarkMode: Bool
    let reduceMotion: Bool

    @State private var isBlinking: Bool = false

    private var clampedFill: CGFloat { CGFloat(max(0, min(100, percentFill))) / 100.0 }
    private var blinkDuration: Double? {
        if reduceMotion { return nil }
        if percentUsed >= 95 { return 0.35 }
        if percentUsed >= 90 { return 0.55 }
        if percentUsed >= 80 { return 0.9 }
        return nil
    }

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(isDarkMode ? 0.25 : 0.2))
            .frame(width: 24, height: 4)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, 24 * clampedFill), height: 4)
                    .opacity((blinkDuration == nil) ? 1 : (isBlinking ? 0.35 : 1))
                    .task(id: blinkDuration) {
                        guard let d = blinkDuration else {
                            isBlinking = false
                            return
                        }
                        isBlinking = false
                        withAnimation(.easeInOut(duration: d).repeatForever(autoreverses: true)) {
                            isBlinking = true
                        }
                    }
            }
    }
}

private struct SessionCountView: View {
    let text: String
    let freshnessText: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .monospacedDigit()
            if let freshnessText, !freshnessText.isEmpty {
                DividerText()
                Text(freshnessText)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.6))
        .lineLimit(1)
    }
}

private struct ProviderIcon: View {
    let provider: QuotaData.Provider

    @ViewBuilder
    var body: some View {
        if provider == .claude {
            Image("FooterIconClaude")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Image("FooterIconCodex")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.white)
        }
    }
}

#if DEBUG
private struct CockpitFooterPreviewHost: View {
    @State private var isBusy: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            CockpitFooterView(
                isBusy: isBusy,
                statusText: isBusy ? "Indexing sessions…" : "",
                quotas: [
                    QuotaData(provider: .codex, fiveHourRemainingPercent: 20, fiveHourResetText: "resets 14:00", weekRemainingPercent: 8, weekResetText: "resets 2/9/2026, 2:00 PM"),
                    QuotaData(provider: .claude, fiveHourRemainingPercent: 55, fiveHourResetText: "Jan 5 at 2pm", weekRemainingPercent: 45, weekResetText: "Jan 9 at 2pm"),
                ],
                sessionCountText: "42 Sessions"
            )
            .onTapGesture { isBusy.toggle() }
        }
        .frame(width: 1200, height: 140)
    }
}

#Preview("CockpitFooterView") {
    CockpitFooterPreviewHost()
}
#endif
