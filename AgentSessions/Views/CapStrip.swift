import SwiftUI

struct CapStrip: View {
    @EnvironmentObject var cap: CapPressureStore

    var body: some View {
        if cap.state.severity == .none { EmptyView() } else {
            HStack {
                Image(systemName: cap.state.severity == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .imageScale(.medium)
                    .foregroundStyle(.black.opacity(0.85))
                Text(message())
                    .font(.subheadline)
                    .foregroundStyle(.black.opacity(0.85))
                Spacer()
                Button("Open Capacity") { NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.bordered)
                    .tint(.black.opacity(0.2))
                Button("Snooze long jobs") {
                    let key = "SnoozeLongJobsWhileTight"
                    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
                }
                .buttonStyle(.bordered)
                .tint(.black.opacity(0.2))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background((cap.state.severity == .critical ? Color.red : Color.yellow).opacity(0.35))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    private func message() -> String {
        guard let eta = cap.state.eta else { return "" }
        let mins = eta.minutesToCap.map { Int(ceil($0)) } ?? 0
        let which = (eta.window == .secondary) ? "Secondary" : "Primary"
        let resetText: String = {
            guard let mtr = eta.minutesToReset else { return "" }
            let mins = Int(ceil(mtr))
            return " · resets in \(mins)m"
        }()
        switch eta.reason {
        case .capacity, .percentSlope:
            return "\(which) cap in ~\(mins)m at current rate\(resetText)"
        case .fallback429:
            return "Frequent 429s. Cap likely within ~\(mins)m (no telemetry)\(resetText)"
        }
    }
}

