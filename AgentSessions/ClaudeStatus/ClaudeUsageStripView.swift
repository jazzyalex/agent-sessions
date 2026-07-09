import SwiftUI

// Compact footer usage strip for Claude usage only
struct ClaudeUsageStripView: View {
    @ObservedObject var status: ClaudeUsageModel
    // Optional label shown on the left (used in Unified window)
    var label: String? = nil
    var brandColor: Color = Color.agentClaude
    var labelWidth: CGFloat? = 56
    var verticalPadding: CGFloat = 6
    var drawBackground: Bool = true
    var collapseTop: Bool = false
    var collapseBottom: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @State private var showTmuxHelp: Bool = false

    private var hasLiveData: Bool {
        status.lastUpdate.map { Date().timeIntervalSince($0) < 300 } ?? false
    }

    var body: some View {
        Group {
            if let authStatus = status.authStatus, authStatus.state.isAlarming {
                if hasLiveData {
                    VStack(spacing: 4) {
                        AuthRemediationBanner(status: authStatus, compact: true, embedded: true)
                        metersRow
                            .opacity(0.5)
                    }
                } else {
                    AuthRemediationBanner(status: authStatus, compact: false, embedded: true)
                }
            } else {
                metersRow
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, collapseTop ? 0 : verticalPadding)
        .padding(.bottom, collapseBottom ? 0 : verticalPadding)
        .background(drawBackground ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear))
        .onTapGesture(count: 2) {
            let d = UserDefaults.standard
            let claudeTrackingEnabled = (d.object(forKey: PreferencesKey.Agents.claudeEnabled) as? Bool ?? true)
                && d.bool(forKey: PreferencesKey.claudeUsageEnabled)
            guard claudeTrackingEnabled else { return }
            if status.tmuxUnavailable {
                showTmuxHelp = true
            } else if !status.isUpdating {
                // For Claude, a double-click triggers a hard /usage probe
                // without showing the diagnostics dialog.
                ClaudeUsageModel.shared.hardProbeNowDiagnostics { _ in }
            }
        }
        .help(makeTooltip())
        .onAppear { status.setStripVisible(true) }
        .onDisappear { status.setStripVisible(false) }
        .alert("tmux not found", isPresented: $showTmuxHelp) {
            Button("Copy brew command") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("brew install tmux", forType: .string)
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Claude usage tracking requires tmux to run headlessly. Install via Homebrew:\n\n  brew install tmux\n\nThen enable Usage Tracking again.")
        }
    }

    private var metersRow: some View {
        HStack(spacing: 12) {
            if let label {
                Text(label)
                    .font(.footnote).bold()
                    .foregroundStyle(stripMonochrome ? Color.secondary : brandColor)
                    .frame(width: labelWidth, alignment: .leading)
            }
            UsageMeter(title: "5h", percent: status.sessionRemainingPercent, reset: status.sessionResetText, tintColor: brandColor, lastUpdate: status.lastUpdate)
            UsageMeter(title: "Wk", percent: status.weekAllModelsRemainingPercent, reset: status.weekAllModelsResetText, tintColor: brandColor, lastUpdate: status.lastUpdate)

            Spacer(minLength: 0)

            if status.isUpdating {
                UpdatingBadge()
            }

            // Status text (right-aligned): only show problems/warnings.
            // (loginRequired/setupRequired/cliUnavailable captions retired —
            // superseded by the AuthRemediationBanner above.)
            if status.tmuxUnavailable {
                Text("tmux not found").font(.caption).foregroundStyle(.red)
            } else if status.setupRequired {
                Text("Setup required")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(status.setupHint ?? "Claude Code needs one-time setup. Open Terminal and run: claude")
            } else if let reason = status.transientReason {
                // Calm, non-alarming caption for a transient failure (network / 5xx /
                // 429). Secondary/gray, no icon — auto-clears on the next good fetch.
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if status.lastUpdate == nil, status.unavailableMessage != nil {
                Text("Usage unavailable").font(.caption).foregroundStyle(.orange)
            } else if let update = status.lastUpdate {
                // Show immediately when stale/degraded; otherwise only after 30 minutes
                if status.dataIsStale || Date().timeIntervalSince(update) > 30 * 60 {
                    Text("Updated \(timeAgo(update))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        return "\(Int(interval/3600))h ago"
    }

    private func makeTooltip() -> String {
        var parts: [String] = []

        if let lastUpdate = status.lastUpdate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relativeTime = formatter.localizedString(for: lastUpdate, relativeTo: Date())
            parts.append("Claude: Updated \(relativeTime)")
        } else {
            parts.append("Claude: Not yet updated")
        }

        if status.setupRequired {
            parts.append(status.setupHint ?? "Claude Code needs one-time setup. Open Terminal and run: claude")
        }
        if let reason = status.transientReason {
            parts.append(reason)
        }
        if let unavailable = status.unavailableMessage {
            parts.append(unavailable)
        }
        parts.append("Double-click to refresh now")

        return parts.joined(separator: "\n")
    }
}

private struct UsageMeter: View {
    let title: String
    let percent: Int
    let reset: String
    let tintColor: Color
    let lastUpdate: Date?
    @AppStorage("StripShowResetTime") private var showResetTime: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @AppStorage(PreferencesKey.usageDisplayMode) private var usageDisplayModeRaw: String = UsageDisplayMode.left.rawValue

    var body: some View {
        let hasData = lastUpdate != nil
        let includeReset = showResetTime && hasData && !reset.isEmpty
        // Unified freshness: allow TTL after manual hard probe
        let effectiveEvent = effectiveEventTimestamp(source: .claude, eventTimestamp: nil, lastUpdate: lastUpdate)
        let stale = isResetInfoStale(kind: title, source: .claude, lastUpdate: effectiveEvent)
        let displayText = stale ? UsageStaleThresholds.outdatedCopy : UsageResetText.displayTextWithPrefix(kind: title, source: .claude, raw: reset)

        let mode = UsageDisplayMode(rawValue: usageDisplayModeRaw) ?? .left
        let leftPercent = hasData ? max(0, min(100, percent)) : 0
        let barUsedPercent = mode.barUsedPercent(fromLeft: leftPercent)
        let labelPercent = mode.numericPercent(fromLeft: leftPercent)

        HStack(spacing: UsageMeterLayout.itemSpacing) {
            Text(title)
                .font(.footnote).bold()
                .frame(width: UsageMeterLayout.titleWidth, alignment: .leading)
            // Progress bar shows "used" (filled portion = used) in both modes
            ProgressView(value: Double(barUsedPercent), total: 100)
                .tint(stripMonochrome ? .secondary : tintColor)
                .frame(width: UsageMeterLayout.progressWidth)
            // Label switches between "left" and "used" depending on mode
            Text(hasData ? "\(labelPercent)% \(mode.suffix)" : "--")
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
        .help(hasData && !reset.isEmpty ? UsageResetText.displayTextWithPrefix(kind: title, source: .claude, raw: reset) : "Waiting for Claude usage data")
    }
}

private enum UsageMeterLayout {
    static let itemSpacing: CGFloat = 6
    static let titleWidth: CGFloat = 28
    static let progressWidth: CGFloat = 140
    static let percentWidth: CGFloat = 52  // Wider to fit "XX% left"
    static let resetWidth: CGFloat = 160

    static func totalWidth(includeReset: Bool) -> CGFloat {
        let base = titleWidth + progressWidth + percentWidth
        let spacingCount: CGFloat = includeReset ? 3 : 2
        let resetComponent: CGFloat = includeReset ? resetWidth : 0
        return base + resetComponent + itemSpacing * spacingCount
    }
}
