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
        HStack(spacing: 16) {
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
        HStack(spacing: 8) {
            Text(title).font(.footnote).bold()
            ProgressView(value: Double(percent), total: 100)
                .tint(stripMonochrome ? .secondary : .accentColor)
                .frame(width: 140)
            Text("\(percent)%").font(.footnote).monospacedDigit()
            if showResetTime, !reset.isEmpty {
                let text = formattedReset(reset)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
