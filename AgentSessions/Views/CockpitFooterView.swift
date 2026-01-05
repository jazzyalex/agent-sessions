import SwiftUI

private enum CockpitFooterTheme {
    static let height: CGFloat = 26
    static let horizontalPadding: CGFloat = 10

    static let lightBackground = Color(hex: "007acc")
    static let darkBackground = Color(hex: "252526")

    static let topBorder = Color.black.opacity(0.3)

    static func quotaBackgroundOpacity(isDark: Bool) -> Double { isDark ? 0.14 : 0.08 }
    static func quotaBorderOpacity(isDark: Bool) -> Double { isDark ? 0.10 : 0.05 }
    static func barTrackOpacity(isDark: Bool) -> Double { isDark ? 0.25 : 0.20 }
}

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

    func resetDate(kind: String, raw: String) -> Date? {
        UsageResetText.resetDate(kind: kind, source: provider.usageSource, raw: raw)
    }

    func resetDisplayFallback(kind: String, raw: String) -> String {
        UsageResetText.displayText(kind: kind, source: provider.usageSource, raw: raw)
    }

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
    let usageDisplayModeOverride: UsageDisplayMode?

    init(isBusy: Bool,
         statusText: String,
         quotas: [QuotaData],
         sessionCountText: String,
         freshnessText: String? = nil,
         usageDisplayModeOverride: UsageDisplayMode? = nil) {
        self.isBusy = isBusy
        self.statusText = statusText
        self.quotas = quotas
        self.sessionCountText = sessionCountText
        self.freshnessText = freshnessText
        self.usageDisplayModeOverride = usageDisplayModeOverride
    }

    var body: some View {
        HStack(spacing: 10) {
            if isBusy, !statusText.isEmpty {
                IndexingStatusView(isBusy: true, text: statusText)
            }

            HStack(spacing: 10) {
                ForEach(Array(quotas.enumerated()), id: \.offset) { _, q in
                    QuotaWidget(data: q, isDarkMode: colorScheme == .dark, modeOverride: usageDisplayModeOverride)
                }
            }

            Spacer(minLength: 0)

            SessionCountView(text: sessionCountText, freshnessText: freshnessText)
        }
        .padding(.horizontal, CockpitFooterTheme.horizontalPadding)
        .frame(height: CockpitFooterTheme.height)
        .background(colorScheme == .dark ? CockpitFooterTheme.darkBackground : CockpitFooterTheme.lightBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CockpitFooterTheme.topBorder)
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
    let modeOverride: UsageDisplayMode?
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw: String = UsageDisplayMode.left.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: UsageDisplayMode { modeOverride ?? (UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left) }

    private enum BottleneckKind { case fiveHour, week }
    private struct Presentation: Equatable {
        var barFillPercent: Int
        var barFillColor: Color
        var metricForeground: Color

        var bottleneckUsedPercent: Int

        var fiveHourPercentLabelText: String
        var weekPercentLabelText: String
        var fiveHourResetDisplayText: String
        var weekResetDisplayText: String
    }

    private var presentation: Presentation {
        let fiveResetRaw = data.fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let weekResetRaw = data.weekResetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLoaded = !(fiveResetRaw.isEmpty && weekResetRaw.isEmpty)

        let fiveLeft = clampPercent(data.fiveHourRemainingPercent)
        let weekLeft = clampPercent(data.weekRemainingPercent)
        let fiveUsed = clampPercent(100 - fiveLeft)
        let weekUsed = clampPercent(100 - weekLeft)

        let bottleneckKind: BottleneckKind = (fiveUsed >= weekUsed) ? .fiveHour : .week
        let bottleneckUsed = isLoaded ? max(fiveUsed, weekUsed) : 0
        let bottleneckLeft = (bottleneckKind == .fiveHour) ? fiveLeft : weekLeft

        let isCritical: Bool = isLoaded && {
            switch bottleneckKind {
            case .fiveHour: return fiveUsed >= 80
            case .week: return weekUsed >= 90
            }
        }()

        let barFillPercent: Int = isLoaded ? {
            switch mode {
            case .left: return bottleneckLeft
            case .used: return bottleneckUsed
            }
        }() : 0

        let fiveResetDate = data.resetDate(kind: "5h", raw: data.fiveHourResetText)
        let weekResetDate = data.resetDate(kind: "Wk", raw: data.weekResetText)

        let fiveResetDisplayText: String = {
            let rel = formatRelativeTimeUntil(fiveResetDate)
            if rel != "—" { return "↻ \(rel)" }
            let fallback = data.resetDisplayFallback(kind: "5h", raw: data.fiveHourResetText)
            return fallback.isEmpty ? "↻ —" : "↻ \(fallback)"
        }()

        let weekResetDisplayText: String = {
            let s = formatWeeklyReset(weekResetDate)
            if s != "—" { return "↻ \(s)" }
            let fallback = data.resetDisplayFallback(kind: "Wk", raw: data.weekResetText)
            return fallback.isEmpty ? "↻ —" : "↻ \(fallback)"
        }()

        return Presentation(
            barFillPercent: barFillPercent,
            barFillColor: isCritical ? .red : .white,
            metricForeground: isCritical ? .red : (isLoaded ? .white : .white.opacity(0.75)),
            bottleneckUsedPercent: bottleneckUsed,
            fiveHourPercentLabelText: isLoaded ? "\(mode.numericPercent(fromLeft: fiveLeft))%" : "—%",
            weekPercentLabelText: isLoaded ? "\(mode.numericPercent(fromLeft: weekLeft))%" : "—%",
            fiveHourResetDisplayText: fiveResetDisplayText,
            weekResetDisplayText: weekResetDisplayText
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: data.provider)
                .frame(width: 14, height: 14)

            MiniUsageBar(
                percentFill: presentation.barFillPercent,
                percentUsed: presentation.bottleneckUsedPercent,
                tint: presentation.barFillColor,
                isDarkMode: isDarkMode,
                reduceMotion: reduceMotion
            )

            HStack(spacing: 6) {
                Text("5h: \(presentation.fiveHourPercentLabelText)")
                DividerText()
                Text(presentation.fiveHourResetDisplayText)
                DividerText()
                Text("Wk: \(presentation.weekPercentLabelText)")
                DividerText()
                Text(presentation.weekResetDisplayText)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(presentation.metricForeground)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Color.white.opacity(CockpitFooterTheme.quotaBackgroundOpacity(isDark: isDarkMode)))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.white.opacity(CockpitFooterTheme.quotaBorderOpacity(isDark: isDarkMode)), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
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
            .fill(Color.white.opacity(CockpitFooterTheme.barTrackOpacity(isDark: isDarkMode)))
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
    @Environment(\.colorScheme) private var colorScheme

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
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        }
    }
}

#if DEBUG
private struct CockpitFooterPreviewHost: View {
    let isBusy: Bool
    let isCritical: Bool
    let modeOverride: UsageDisplayMode

    var body: some View {
        CockpitFooterView(
            isBusy: isBusy,
            statusText: isBusy ? "Indexing sessions…" : "",
            quotas: [
                QuotaData(provider: .codex,
                          fiveHourRemainingPercent: isCritical ? 10 : 55,
                          fiveHourResetText: "resets 14:00",
                          weekRemainingPercent: isCritical ? 8 : 45,
                          weekResetText: "resets 2/9/2026, 2:00 PM"),
                QuotaData(provider: .claude,
                          fiveHourRemainingPercent: isCritical ? 15 : 55,
                          fiveHourResetText: "Jan 5 at 2pm",
                          weekRemainingPercent: isCritical ? 9 : 45,
                          weekResetText: "Jan 9 at 2pm"),
            ],
            sessionCountText: "12 / 42 Sessions",
            freshnessText: "Last: 2m ago",
            usageDisplayModeOverride: modeOverride
        )
    }
}

private struct CockpitFooterPreviewMatrix: View {
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                CockpitFooterPreviewHost(isBusy: true, isCritical: false, modeOverride: .left)
                CockpitFooterPreviewHost(isBusy: false, isCritical: false, modeOverride: .left)
                CockpitFooterPreviewHost(isBusy: true, isCritical: true, modeOverride: .left)
            }
            .environment(\.colorScheme, .light)
            .overlay(alignment: .topLeading) {
                Text("Light • Left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }

            VStack(spacing: 6) {
                CockpitFooterPreviewHost(isBusy: true, isCritical: false, modeOverride: .used)
                CockpitFooterPreviewHost(isBusy: false, isCritical: false, modeOverride: .used)
                CockpitFooterPreviewHost(isBusy: true, isCritical: true, modeOverride: .used)
            }
            .environment(\.colorScheme, .light)
            .overlay(alignment: .topLeading) {
                Text("Light • Used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }

            VStack(spacing: 6) {
                CockpitFooterPreviewHost(isBusy: true, isCritical: false, modeOverride: .left)
                CockpitFooterPreviewHost(isBusy: false, isCritical: false, modeOverride: .left)
                CockpitFooterPreviewHost(isBusy: true, isCritical: true, modeOverride: .left)
            }
            .environment(\.colorScheme, .dark)
            .overlay(alignment: .topLeading) {
                Text("Dark • Left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }

            VStack(spacing: 6) {
                CockpitFooterPreviewHost(isBusy: true, isCritical: false, modeOverride: .used)
                CockpitFooterPreviewHost(isBusy: false, isCritical: false, modeOverride: .used)
                CockpitFooterPreviewHost(isBusy: true, isCritical: true, modeOverride: .used)
            }
            .environment(\.colorScheme, .dark)
            .overlay(alignment: .topLeading) {
                Text("Dark • Used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .padding()
    }
}

#Preview("CockpitFooterView") { CockpitFooterPreviewMatrix() }
#endif
