import SwiftUI

// Compact footer usage strip for Claude usage only
struct ClaudeUsageStripView: View {
    @ObservedObject var status: ClaudeUsageModel

    var body: some View {
        HStack(spacing: 16) {
            Text("Claude").font(.footnote).bold().foregroundStyle(.purple)
            UsageMeter(title: "5h", percent: status.sessionPercent, reset: status.sessionResetText)
            UsageMeter(title: "Wk", percent: status.weekAllModelsPercent, reset: status.weekAllModelsResetText)

            Spacer(minLength: 0)

            // Error indicators
            if status.loginRequired {
                Text("Login required - run 'claude' in Terminal").font(.caption).foregroundStyle(.red)
            } else if status.cliUnavailable {
                Text("Claude CLI not found").font(.caption).foregroundStyle(.red)
            } else if status.tmuxUnavailable {
                Text("tmux not found").font(.caption).foregroundStyle(.red)
            } else if let update = status.lastUpdate {
                Text("Updated \(timeAgo(update))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thickMaterial)
        .onAppear { status.setStripVisible(true) }
        .onDisappear { status.setStripVisible(false) }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        return "\(Int(interval/3600))h ago"
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
                .tint(stripMonochrome ? .secondary : .purple)
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
