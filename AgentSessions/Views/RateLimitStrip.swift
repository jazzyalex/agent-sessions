import SwiftUI

struct RateLimitStrip: View {
    let remainingSeconds: Int
    let window: TightWindow?
    let resetAt: Date?
    let recent429: Int

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.black.opacity(0.85))
                .imageScale(.medium)
            Text(message())
                .font(.subheadline)
                .foregroundStyle(.black.opacity(0.85))
            Spacer()
            Button("Open Capacity") {
                // Placeholder: deep-link to analytics/capacity view if available
                NSApp.activate(ignoringOtherApps: true)
            }
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
        .background(Color.yellow.opacity(0.35))
        .overlay(Divider(), alignment: .bottom)
    }

    private func message() -> String {
        let minLeft = Int(ceil(Double(remainingSeconds) / 60.0))
        let when: String = {
            guard let resetAt else { return "soon" }
            let df = DateFormatter()
            df.timeStyle = .short
            df.dateStyle = .none
            return df.string(from: resetAt)
        }()
        if recent429 >= 2 && (window == nil || resetAt == nil) {
            return "Frequent 429s. Cooldown ~10m or until next reset."
        }
        let which = (window == .secondary) ? "Secondary" : "Primary"
        return "\(which) rate-limit tight. Safe again at \(when) (in \(minLeft)m)."
    }
}

