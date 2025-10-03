import SwiftUI

// Compact footer usage strip for Codex usage only
struct UsageStripView: View {
    @ObservedObject var codexStatus: CodexUsageModel

    var body: some View {
        HStack(spacing: 16) {
            Text("Codex").font(.footnote).bold().foregroundStyle(.accentColor)
            UsageMeter(title: "5h", percent: codexStatus.fiveHourPercent, reset: codexStatus.fiveHourResetText)
            UsageMeter(title: "Wk", percent: codexStatus.weekPercent, reset: codexStatus.weekResetText)
            Spacer(minLength: 0)
            if let line = codexStatus.usageLine, !line.isEmpty {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial)
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
                Text(reset)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .help(reset.isEmpty ? "" : reset)
    }
}

// Detail popover removed; tooltips provide reset info.
