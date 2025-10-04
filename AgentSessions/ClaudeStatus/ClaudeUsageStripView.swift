import SwiftUI

// Compact footer usage strip for Claude usage only
struct ClaudeUsageStripView: View {
    @ObservedObject var status: ClaudeUsageModel
    // Optional label shown on the left (used in Unified window)
    var label: String? = nil
    var brandColor: Color = Color(red: 204/255, green: 121/255, blue: 90/255)
    var labelWidth: CGFloat? = 56
    var verticalPadding: CGFloat = 6
    var drawBackground: Bool = true
    var collapseTop: Bool = false
    var collapseBottom: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @State private var showTmuxHelp: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if let label {
                Text(label)
                    .font(.footnote).bold()
                    .foregroundStyle(stripMonochrome ? Color.secondary : brandColor)
                    .frame(width: labelWidth, alignment: .leading)
            }
            UsageMeter(title: "5h", percent: status.sessionPercent, reset: status.sessionResetText, tintColor: brandColor, lastUpdate: status.lastUpdate)
            UsageMeter(title: "Wk", percent: status.weekAllModelsPercent, reset: status.weekAllModelsResetText, tintColor: brandColor, lastUpdate: status.lastUpdate)

            Spacer(minLength: 0)

            // Status text (right-aligned): only show problems/warnings
            if status.loginRequired {
                Text("Login required").font(.caption).foregroundStyle(.red)
            } else if status.cliUnavailable {
                Text("CLI not found").font(.caption).foregroundStyle(.red)
            } else if status.tmuxUnavailable {
                Text("tmux not found").font(.caption).foregroundStyle(.red)
            } else if let update = status.lastUpdate {
                // Consider data stale if no update for 15 minutes
                if Date().timeIntervalSince(update) > 15 * 60 {
                    Text("No recent data — \(timeAgo(update))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, collapseTop ? 0 : verticalPadding)
        .padding(.bottom, collapseBottom ? 0 : verticalPadding)
        .background(drawBackground ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear))
        .onTapGesture(count: 2) {
            if status.tmuxUnavailable {
                showTmuxHelp = true
            } else {
                status.refreshNow()
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

    var body: some View {
        let includeReset = showResetTime && !reset.isEmpty
        let stale = isResetInfoStale(kind: title, lastUpdate: lastUpdate)
        let displayText = stale ? UsageStaleThresholds.outdatedCopy : formattedReset(reset)

        HStack(spacing: UsageMeterLayout.itemSpacing) {
            Text(title)
                .font(.footnote).bold()
                .frame(width: UsageMeterLayout.titleWidth, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .tint(stripMonochrome ? .secondary : tintColor)
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
