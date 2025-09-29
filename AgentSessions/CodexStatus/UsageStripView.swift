import SwiftUI

// ILLUSTRATIVE: Compact footer usage strip with two meters
struct UsageStripView: View {
    @ObservedObject var status: CodexUsageModel

    var body: some View {
        HStack(spacing: 16) {
            UsageMeter(title: "5h", percent: status.fiveHourPercent, reset: status.fiveHourResetText)
            UsageMeter(title: "Wk", percent: status.weekPercent, reset: status.weekResetText)
            Spacer(minLength: 0)
            if let line = status.usageLine, !line.isEmpty {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial)
        .onAppear { status.setStripVisible(true) }
        .onDisappear { status.setStripVisible(false) }
    }
}

private struct UsageMeter: View {
    let title: String
    let percent: Int
    let reset: String
    @AppStorage("StripShowResetTime") private var showResetTime: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.footnote).bold()
            ProgressView(value: Double(percent), total: 100)
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
