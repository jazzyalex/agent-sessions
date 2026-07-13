import SwiftUI

private enum CockpitFooterTheme {
    static let height: CGFloat = 26
    static let horizontalPadding: CGFloat = 10

    /// Neutral status-bar look in both appearances: a system `.bar` material
    /// (see `CockpitFooterView.body`) topped by a standard separator hairline.
    /// The footer whispers until a quota is actually critical.
    static func topBorder(isDark: Bool) -> Color {
        Color(nsColor: .separatorColor)
    }

    static func quotaBackgroundOpacity(isDark: Bool) -> Double { isDark ? 0.06 : 0.05 }
    static func quotaBorderOpacity(isDark: Bool) -> Double { 0.10 }
    static func barTrackColor(isDark: Bool) -> Color {
        Color.primary.opacity(0.12)
    }
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
    var lastUpdate: Date? = nil
    var eventTimestamp: Date? = nil
    var isUpdating: Bool = false
    var fiveHourProjectedRunoutAt: Date? = nil
    var fiveHourProjectionObservedAt: Date? = nil
    /// CLI auth status for this provider; drives the AuthRemediationBanner when alarming.
    var authStatus: UsageAuthStatus? = nil
    /// Calm caption for a transient (non-alarming) usage failure. (P2)
    var transientReason: String? = nil
    /// Current usage data source; drives the "via CLI probe" fallback label. (P4)
    var currentSource: ClaudeUsageSource? = nil
    /// Served data is meaningfully stale (cache aged past freshness / degraded).
    /// Drives an immediate at-a-glance "stale" cue on the menu-bar face, before
    /// the slower 5-minute auth-expiry escalation raises the loud remediation —
    /// so a QM user is never left with a silently-frozen meter.
    var dataIsStale: Bool = false

    var hasUsageData: Bool {
        switch provider {
        case .codex:
            return eventTimestamp != nil || lastUpdate != nil || !fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !weekResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .claude:
            return lastUpdate != nil
        }
    }

    /// A copy scrubbed of usage values so a meter renders as unavailable ("--")
    /// rather than a misleading cached/zero percentage. Used on the menu-bar face
    /// when the provider's auth is alarming: an expired provider has no
    /// trustworthy numbers, and "0%" there reads as "quota exhausted".
    func unavailableForDisplay() -> QuotaData {
        var copy = self
        copy.lastUpdate = nil
        copy.eventTimestamp = nil
        copy.fiveHourResetText = ""
        copy.weekResetText = ""
        return copy
    }

    /// Shared meter state so the footer, menu-bar face, and QM dropdown all speak
    /// the same language:
    /// - `.live` — trustworthy fresh numbers → show the meter.
    /// - `.reconnecting` — no trustworthy data yet, but not a confirmed problem →
    ///   spinning "reconnecting" affordance (actively retrying).
    /// - `.needsAction` — auth is alarming (expired / signed out / no CLI) → show
    ///   what's wrong + how to fix; retrying alone won't recover it.
    /// - `.idle` — signed in, but the saved token lapsed from inactivity → calm
    ///   "no active session" cell; usage resumes with the next Claude session,
    ///   so neither the spinner (not retrying its way out) nor the alarm fits.
    enum PresentationState: Equatable {
        case live
        case reconnecting
        case needsAction(UsageAuthStatus)
        case idle(UsageAuthStatus)
    }

    var presentationState: PresentationState {
        if let auth = authStatus, auth.state.isAlarming { return .needsAction(auth) }
        if let auth = authStatus, auth.state == .idle { return .idle(auth) }
        if !hasUsageData || dataIsStale || transientReason != nil { return .reconnecting }
        return .live
    }

    /// Live within the last 5 minutes. Mirrors the usage strip's freshness gate
    /// for choosing the compact banner (over dimmed meters) vs the full banner
    /// (replacing meters) when auth is alarming.
    var hasLiveData: Bool {
        lastUpdate.map { Date().timeIntervalSince($0) < 300 } ?? false
    }

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
            weekResetText: model.weekResetText,
            lastUpdate: model.lastUpdate,
            eventTimestamp: model.lastEventTimestamp,
            isUpdating: model.isUpdating,
            fiveHourProjectedRunoutAt: model.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: model.fiveHourProjectionObservedAt,
            authStatus: model.authStatus
        )
    }

    @MainActor
    static func claude(from model: ClaudeUsageModel) -> QuotaData {
        QuotaData(
            provider: .claude,
            fiveHourRemainingPercent: model.sessionRemainingPercent,
            fiveHourResetText: model.sessionResetText,
            weekRemainingPercent: model.weekAllModelsRemainingPercent,
            weekResetText: model.weekAllModelsResetText,
            lastUpdate: model.lastUpdate,
            eventTimestamp: nil,
            isUpdating: model.isUpdating,
            fiveHourProjectedRunoutAt: model.fiveHourProjectedRunoutAt,
            fiveHourProjectionObservedAt: model.fiveHourProjectionObservedAt,
            authStatus: model.authStatus,
            transientReason: model.transientReason,
            currentSource: model.currentSource,
            dataIsStale: model.dataIsStale
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
		                    switch q.presentationState {
		                    case .needsAction(let auth):
		                        // Confirmed problem that needs the user: what's wrong + how
		                        // to fix, on one line (e.g. "Claude auth expired · claude
		                        // auth login").
		                        FooterAuthCell(status: auth)
		                    case .idle(let auth):
		                        // Signed in, token lapsed from inactivity: calm cell, no
		                        // spinner (retrying won't recover it), no Fix chip
		                        // (nothing is broken — the next session refreshes it).
		                        FooterIdleChip(provider: q.provider, detail: auth.detail)
		                    case .reconnecting:
		                        // Actively retrying: one compact line with spinning arrows,
		                        // not a broken "-- ↻ Waiting" meter. Escalates to the chip
		                        // above if the retries keep failing.
		                        FooterRetryChip(provider: q.provider)
		                    case .live:
		                        VStack(alignment: .leading, spacing: 1) {
		                            CockpitQuotaWidget(
		                                data: q,
		                                isDarkMode: colorScheme == .dark,
		                                scope: .both,
		                                style: .bars,
		                                modeOverride: usageDisplayModeOverride,
		                                baseForeground: .primary,
		                                showResetIndicators: true,
		                                showPill: true
		                            )
		                            if q.currentSource == .tmuxUsage {
		                                Text("via CLI probe").font(.caption2).foregroundStyle(.secondary)
		                            }
		                        }
		                    }
		                }
		            }

            Spacer(minLength: 0)

            SessionCountView(text: sessionCountText, freshnessText: freshnessText)
        }
        .padding(.horizontal, CockpitFooterTheme.horizontalPadding)
        // Fixed single-row height for the common (signed-in) case; grows only when
        // an alarming AuthRemediationBanner needs an extra line, so the strip never
        // jitters for normal usage.
        .frame(minHeight: CockpitFooterTheme.height)
        // No filled bar background — the meters read as plain text over the window,
        // separated only by the hairline below.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CockpitFooterTheme.topBorder(isDark: colorScheme == .dark))
                .frame(height: 1)
        }
    }
}

enum CockpitQuotaScope: Equatable {
    case fiveHour
    case week
    case both
}

enum CockpitQuotaStyle: Equatable {
    case bars
    case numbers
}

		struct CockpitQuotaWidget: View {
		    let data: QuotaData
		    let isDarkMode: Bool
		    let scope: CockpitQuotaScope
		    let style: CockpitQuotaStyle
		    let modeOverride: UsageDisplayMode?
		    let baseForeground: Color
		    let showResetIndicators: Bool
		    let showPill: Bool

		    var body: some View {
		        QuotaWidget(
		            data: data,
		            isDarkMode: isDarkMode,
		            scope: scope,
		            style: style,
		            modeOverride: modeOverride,
		            baseForeground: baseForeground,
		            showResetIndicators: showResetIndicators,
		            showPill: showPill
		        )
		    }
		}

/// Per-provider auth remediation cell shown in the footer in place of the meter
/// when that provider's CLI auth is alarming. A single quiet chip (short label +
/// remediation control) rather than the loud multi-line banner — the full banner
/// lives on the Agent Cockpit HUD, which has room for it. The chip's width is
/// bounded so the footer's horizontal layout stays tidy alongside the other
/// provider and the session count.
private struct FooterAuthCell: View {
    let status: UsageAuthStatus

    var body: some View {
        AuthRemediationBanner(status: status, chip: true, embedded: true)
            .frame(maxWidth: 360, alignment: .leading)
    }
}

/// Calm one-line "no active session" chip for the idle-token state: the account
/// is signed in but the saved token lapsed from inactivity, and usage resumes
/// with the next session. Deliberately not FooterAuthCell (nothing to fix) and
/// not FooterRetryChip (retrying alone never recovers a lapsed token) — the
/// tooltip carries the full explanation.
private struct FooterIdleChip: View {
    let provider: QuotaData.Provider
    let detail: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(provider == .claude ? "Claude" : "Codex") — no active session")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(detail)
    }
}

/// Compact one-line "actively retrying" chip shown while a provider's usage is
/// transiently unavailable — spinning arrows + provider name, no verbose
/// "-- ↻ Waiting" meter or second caption line. If the retries keep failing the
/// auth classifier escalates and `FooterAuthCell` takes over with the actionable
/// fix, so the user is never left staring at an endless "retrying".
private struct FooterRetryChip: View {
    let provider: QuotaData.Provider
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            Text("\(provider == .claude ? "Claude" : "Codex") — reconnecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear { spinning = true }
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
                .foregroundStyle(.secondary)
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
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .opacity(isVisible ? 1 : 0)
            .animation(isVisible ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                       value: isAnimating)
            .drawingGroup()
            .onAppear { isAnimating = true }
    }
}

		private struct QuotaWidget: View {
		    let data: QuotaData
		    let isDarkMode: Bool
		    let scope: CockpitQuotaScope
		    let style: CockpitQuotaStyle
		    let modeOverride: UsageDisplayMode?
		    let baseForeground: Color
		    let showResetIndicators: Bool
		    let showPill: Bool
		    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw: String = UsageDisplayMode.left.rawValue
		    @AppStorage(PreferencesKey.usageLimitCockpitProjectionEnabled) private var projectedRunoutEnabled: Bool = true
		    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: UsageDisplayMode { modeOverride ?? (UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left) }

    private enum BottleneckKind { case fiveHour, week }
	    private struct Presentation: Equatable {
	        var barFillPercent: Int
	        var barFillColor: Color

        var bottleneckUsedPercent: Int

	        var fiveHourPercentLabelText: String
	        var weekPercentLabelText: String
	        var fiveHourResetLabelText: String
	        var weekResetLabelText: String
	        var fiveHourProjectionLabelText: String?
	    }

	    private var presentation: Presentation {
		        let fiveResetRaw = data.fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines)
		        let weekResetRaw = data.weekResetText.trimmingCharacters(in: .whitespacesAndNewlines)
		        let fiveUnavailable = isResetInfoUnavailable(raw: fiveResetRaw)
		        let weekUnavailable = isResetInfoUnavailable(raw: weekResetRaw)
		        let hasUsageData = data.hasUsageData
		        let hasResetInfo = !((fiveResetRaw.isEmpty || fiveUnavailable) && (weekResetRaw.isEmpty || weekUnavailable))

        let fiveLeft = hasUsageData ? clampPercent(data.fiveHourRemainingPercent) : 0
        let weekLeft = hasUsageData ? clampPercent(data.weekRemainingPercent) : 0
        let fiveUsed = clampPercent(100 - fiveLeft)
        let weekUsed = clampPercent(100 - weekLeft)

        let bottleneckKind: BottleneckKind = (fiveUsed >= weekUsed) ? .fiveHour : .week
        let bottleneckUsed = max(fiveUsed, weekUsed)
        let bottleneckLeft = (bottleneckKind == .fiveHour) ? fiveLeft : weekLeft

        let isCritical: Bool = hasResetInfo && {
            switch bottleneckKind {
            case .fiveHour: return fiveUsed >= 80
            case .week: return weekUsed >= 90
            }
        }()

        let barFillPercent: Int = {
            guard hasUsageData else { return 0 }
            switch mode {
            case .left: return bottleneckLeft
            case .used: return bottleneckUsed
            }
        }()

	        let source = data.provider.usageSource
	        let effectiveTimestamp = effectiveEventTimestamp(source: source, eventTimestamp: data.eventTimestamp, lastUpdate: data.lastUpdate)
	        let fiveIsStale: Bool = {
	            switch source {
	            case .codex:
	                return isResetInfoStale(kind: "5h", source: source, lastUpdate: data.lastUpdate, eventTimestamp: effectiveTimestamp)
	            case .claude:
	                return isResetInfoStale(kind: "5h", source: source, lastUpdate: effectiveTimestamp)
	            }
	        }()
	        let weekIsStale: Bool = {
	            switch source {
	            case .codex:
	                return isResetInfoStale(kind: "Wk", source: source, lastUpdate: data.lastUpdate, eventTimestamp: effectiveTimestamp)
	            case .claude:
	                return isResetInfoStale(kind: "Wk", source: source, lastUpdate: effectiveTimestamp)
	            }
	        }()

	        let fiveResetDate = data.resetDate(kind: "5h", raw: data.fiveHourResetText)
	        let weekResetDate = data.resetDate(kind: "Wk", raw: data.weekResetText)

	        let fiveResetDisplayText: String = {
	            if !hasUsageData { return "Waiting" }
	            if fiveUnavailable { return UsageStaleThresholds.unavailableCopy }
	            let rel = formatRelativeTimeUntil(fiveResetDate)
	            if rel != "—" { return rel }
	            if fiveIsStale { return "n/a" }
	            let fallback = data.resetDisplayFallback(kind: "5h", raw: data.fiveHourResetText)
	            return fallback.isEmpty ? "—" : fallback
	        }()

	        let weekResetDisplayText: String = {
	            if !hasUsageData { return "Waiting" }
	            if weekUnavailable { return UsageStaleThresholds.unavailableCopy }
	            let s = formatWeeklyReset(weekResetDate)
	            if s != "—" { return s }
	            if weekIsStale { return "n/a" }
	            let fallback = data.resetDisplayFallback(kind: "Wk", raw: data.weekResetText)
	            return fallback.isEmpty ? "—" : fallback
	        }()

		        return Presentation(
		            barFillPercent: barFillPercent,
		            barFillColor: isCritical ? .red : .secondary,
		            bottleneckUsedPercent: hasResetInfo ? bottleneckUsed : 0,
		            fiveHourPercentLabelText: (!hasUsageData || fiveUnavailable) ? "--" : "\(mode.numericPercent(fromLeft: fiveLeft))%",
		            weekPercentLabelText: (!hasUsageData || weekUnavailable) ? "--" : "\(mode.numericPercent(fromLeft: weekLeft))%",
		            fiveHourResetLabelText: fiveResetDisplayText,
		            weekResetLabelText: weekResetDisplayText,
		            fiveHourProjectionLabelText: projectedRunoutEnabled
		                ? formatUsageProjectionLabel(
		                    runoutAt: data.fiveHourProjectedRunoutAt,
		                    observedAt: data.fiveHourProjectionObservedAt
		                )
		                : nil
		        )
		    }

		    @ViewBuilder
		    private func resetIndicator(labelText: String) -> some View {
		        HStack(spacing: 4) {
		            Text("↻")
		            Text(labelText)
		        }
		    }

            private var projectionColor: Color {
                isDarkMode
                    ? Color(red: 1.0, green: 0.60, blue: 0.12)
                    : Color(red: 0.82, green: 0.30, blue: 0.00)
            }

		    @ViewBuilder
		    private var inner: some View {
		        HStack(spacing: 8) {
	            ProviderIcon(provider: data.provider)
	                .frame(width: 14, height: 14)
	            if data.isUpdating {
	                RefreshSpinner(tint: baseForeground)
	                    .frame(width: 10, height: 10)
	            }

            if style == .bars {
                MiniUsageBar(
                    percentFill: presentation.barFillPercent,
                    percentUsed: presentation.bottleneckUsedPercent,
                    tint: (presentation.barFillColor == .red) ? .red : .secondary,
                    isDarkMode: isDarkMode,
                    reduceMotion: reduceMotion
                )
            }

		            HStack(spacing: 6) {
		                switch scope {
		                case .fiveHour:
			                    HStack(spacing: 4) {
			                        Text("5h: \(presentation.fiveHourPercentLabelText)")
			                        if let projection = presentation.fiveHourProjectionLabelText {
			                            Text(projection)
                                            .fontWeight(.bold)
                                            .foregroundStyle(projectionColor)
			                        }
			                    }
		                    if showResetIndicators {
		                        DividerText(baseForeground: baseForeground)
		                        resetIndicator(labelText: presentation.fiveHourResetLabelText)
		                    }
		                case .week:
		                    Text("Wk: \(presentation.weekPercentLabelText)")
		                    if showResetIndicators {
		                        DividerText(baseForeground: baseForeground)
		                        resetIndicator(labelText: presentation.weekResetLabelText)
		                    }
		                case .both:
			                    HStack(spacing: 4) {
			                        Text("5h: \(presentation.fiveHourPercentLabelText)")
			                        if let projection = presentation.fiveHourProjectionLabelText {
			                            Text(projection)
                                            .fontWeight(.bold)
                                            .foregroundStyle(projectionColor)
			                        }
			                    }
		                    if showResetIndicators {
		                        DividerText(baseForeground: baseForeground)
		                        resetIndicator(labelText: presentation.fiveHourResetLabelText)
		                        DividerText(baseForeground: baseForeground)
		                    } else {
		                        DividerText(baseForeground: baseForeground)
		                    }
		                    Text("Wk: \(presentation.weekPercentLabelText)")
		                    if showResetIndicators {
		                        DividerText(baseForeground: baseForeground)
		                        resetIndicator(labelText: presentation.weekResetLabelText)
		                    }
		                }
		            }
	            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(baseForeground)
            .lineLimit(1)
	        }
	    }

	    var body: some View {
	        if showPill {
	            inner
	                .padding(.horizontal, 8)
	                .frame(height: 20)
	                .background(baseForeground.opacity(CockpitFooterTheme.quotaBackgroundOpacity(isDark: isDarkMode)))
	                .overlay(
	                    RoundedRectangle(cornerRadius: 4, style: .continuous)
	                        .stroke(baseForeground.opacity(CockpitFooterTheme.quotaBorderOpacity(isDark: isDarkMode)), lineWidth: 1)
	                )
	                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
	        } else {
	            inner
	        }
	    }

    private func formatRelativeTimeUntil(_ date: Date?, now: Date = Date()) -> String {
        formatUsageRelativeTimeLabel(date, now: now) ?? "—"
    }

    private func formatWeeklyReset(_ date: Date?, now: Date = Date()) -> String {
        formatUsageWeeklyResetLabel(date, now: now) ?? "—"
    }
	}

private struct RefreshSpinner: View {
    let tint: Color
    @State private var rotate: Bool = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .foregroundStyle(tint)
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: rotate)
            .drawingGroup()
            .onAppear { rotate = true }
    }
}

private struct DividerText: View {
    @Environment(\.colorScheme) private var colorScheme
    let baseForeground: Color

    var body: some View {
        Text("|")
            .foregroundStyle(baseForeground.opacity(colorScheme == .dark ? 0.30 : 0.25))
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
            .fill(CockpitFooterTheme.barTrackColor(isDark: isDarkMode))
            .frame(width: 24, height: 4)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, 24 * clampedFill), height: 4)
                    .drawingGroup()
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
                DividerText(baseForeground: .secondary)
                Text(freshnessText)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
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
                          weekResetText: "resets 2/9/2026, 2:00 PM",
                          lastUpdate: Date(),
                          eventTimestamp: Date()),
                QuotaData(provider: .claude,
                          fiveHourRemainingPercent: isCritical ? 15 : 55,
                          fiveHourResetText: "Jan 5 at 2pm",
                          weekRemainingPercent: isCritical ? 9 : 45,
                          weekResetText: "Jan 9 at 2pm",
                          lastUpdate: Date(),
                          eventTimestamp: nil),
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

private struct CockpitFooterAuthPreviewMatrix: View {
    var body: some View {
        VStack(spacing: 12) {
            // Signed out with NO live data → full banner replaces the meter.
            CockpitFooterView(
                isBusy: false,
                statusText: "",
                quotas: [
                    QuotaData(provider: .codex,
                              fiveHourRemainingPercent: 55,
                              fiveHourResetText: "resets 14:00",
                              weekRemainingPercent: 45,
                              weekResetText: "resets 2/9/2026, 2:00 PM",
                              lastUpdate: Date(),
                              eventTimestamp: Date()),
                    QuotaData(provider: .claude,
                              fiveHourRemainingPercent: 0,
                              fiveHourResetText: "",
                              weekRemainingPercent: 0,
                              weekResetText: "",
                              lastUpdate: nil,
                              eventTimestamp: nil,
                              authStatus: .make(provider: .claude, state: .signedOut)),
                ],
                sessionCountText: "12 / 42 Sessions",
                freshnessText: "Last: 2m ago"
            )

            // Expired but WITH live data → compact banner over dimmed meters.
            CockpitFooterView(
                isBusy: false,
                statusText: "",
                quotas: [
                    QuotaData(provider: .codex,
                              fiveHourRemainingPercent: 40,
                              fiveHourResetText: "resets 14:00",
                              weekRemainingPercent: 30,
                              weekResetText: "resets 2/9/2026, 2:00 PM",
                              lastUpdate: Date(),
                              eventTimestamp: Date(),
                              authStatus: .make(provider: .codex, state: .expired)),
                ],
                sessionCountText: "12 / 42 Sessions",
                freshnessText: "Last: 1m ago"
            )
        }
        .padding()
        .frame(width: 720)
    }
}

#Preview("CockpitFooterView • Auth") { CockpitFooterAuthPreviewMatrix() }
#endif
