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
        HStack(spacing: 12) {
            if let label {
                Text(label)
                    .font(.footnote).bold()
                    .foregroundStyle(stripMonochrome ? Color.secondary : brandColor)
                    .frame(width: labelWidth, alignment: .leading)
            }
            UsageMeter(title: "5h", percent: codexStatus.fiveHourPercent, reset: codexStatus.fiveHourResetText)
            UsageMeter(title: "Wk", percent: codexStatus.weekPercent, reset: codexStatus.weekResetText)
            Spacer(minLength: 0)
            if let line = codexStatus.usageLine, !line.isEmpty {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, collapseTop ? 0 : verticalPadding)
        .padding(.bottom, collapseBottom ? 0 : verticalPadding)
        .background(drawBackground ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear))
        .onTapGesture {
            codexStatus.refreshNow()
        }
        .onAppear { codexStatus.setStripVisible(true) }
        .onDisappear { codexStatus.setStripVisible(false) }
    }
}

private struct UsageMeter: View {
    let title: String
    let percent: Int
    let reset: String
    @AppStorage("StripShowResetTime") private var showResetTime: Bool = false
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    var body: some View {
        let includeReset = showResetTime && !reset.isEmpty
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
                let text = formattedReset(reset)
                Text(text)
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
