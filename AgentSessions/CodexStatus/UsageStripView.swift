import SwiftUI

// ILLUSTRATIVE: Compact footer usage strip with two meters
struct UsageStripView: View {
    @ObservedObject var status: CodexUsageModel
    @State private var showPopover: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            UsageMeter(title: "5h", percent: status.fiveHourPercent, reset: status.fiveHourResetText)
            UsageMeter(title: "Wk", percent: status.weekPercent, reset: status.weekResetText)
            Spacer(minLength: 0)
            if let line = status.usageLine, !line.isEmpty {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: { showPopover.toggle() }) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                DetailPopover(status: status)
                    .frame(width: 320)
                    .padding(12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial)
        .onAppear { status.setVisible(true) }
        .onDisappear { status.setVisible(false) }
    }
}

private struct UsageMeter: View {
    let title: String
    let percent: Int
    let reset: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.footnote).bold()
            ProgressView(value: Double(percent), total: 100)
                .frame(width: 140)
            Text("\(percent)%").font(.footnote).monospacedDigit()
        }
        .help("Resets: \(reset.isEmpty ? "unknown" : reset)")
    }
}

private struct DetailPopover: View {
    @ObservedObject var status: CodexUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("5h").font(.caption).bold()
                ProgressView(value: Double(status.fiveHourPercent), total: 100)
                Text("\(status.fiveHourPercent)%").font(.caption).monospacedDigit()
            }
            Text("Reset: \(status.fiveHourResetText.isEmpty ? "unknown" : status.fiveHourResetText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 12) {
                Text("Wk").font(.caption).bold()
                ProgressView(value: Double(status.weekPercent), total: 100)
                Text("\(status.weekPercent)%").font(.caption).monospacedDigit()
            }
            Text("Reset: \(status.weekResetText.isEmpty ? "unknown" : status.weekResetText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let model = status.modelLine, !model.isEmpty {
                Divider()
                Text(model).font(.caption)
            }
            if let acct = status.accountLine, !acct.isEmpty {
                Text(acct).font(.caption)
            }
            if let usage = status.usageLine, !usage.isEmpty {
                Text(usage).font(.caption)
            }
        }
    }
}
