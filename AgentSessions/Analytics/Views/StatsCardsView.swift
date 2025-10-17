import SwiftUI

/// Displays the 4 summary stat cards at the top of analytics
struct StatsCardsView: View {
    let summary: AnalyticsSummary

    var body: some View {
        HStack(spacing: AnalyticsDesign.cardSpacing) {
            StatsCard(
                icon: "square.stack.3d.up",
                label: "Sessions",
                value: "\(summary.sessions)",
                change: AnalyticsSummary.formatChange(summary.sessionsChange)
            )

            StatsCard(
                icon: "bubble.left.and.bubble.right",
                label: "Messages",
                value: "\(summary.messages)",
                change: AnalyticsSummary.formatChange(summary.messagesChange)
            )

            StatsCard(
                icon: "terminal",
                label: "Commands",
                value: "\(summary.commands)",
                change: AnalyticsSummary.formatChange(summary.commandsChange)
            )

            StatsCard(
                icon: "clock",
                label: "Session Duration",
                value: summary.activeTimeFormatted,
                change: AnalyticsSummary.formatChange(summary.activeTimeChange)
            )
        }
        .frame(height: AnalyticsDesign.statsCardHeight)
    }
}

/// Individual stat card component
private struct StatsCard: View {
    let icon: String
    let label: String
    let value: String
    let change: String?

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icon + Label
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Value
            Text(value)
                .font(.title)
                .fontWeight(.regular)
                .foregroundStyle(.primary)

            // Change indicator
            if let change = change {
                Text(change)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(changeColor(for: change))
            } else {
                // Placeholder to maintain spacing
                Text(" ")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AnalyticsDesign.cardPadding)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: AnalyticsDesign.hoverDuration), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(change != nil ? ", \(change!)" : "")")
    }

    private func changeColor(for change: String) -> Color {
        if change.contains("+") {
            return .green
        } else {
            return .secondary
        }
    }
}

// MARK: - Previews

#Preview("Stats Cards") {
    StatsCardsView(summary: AnalyticsSummary(
        sessions: 87,
        sessionsChange: 12,
        messages: 342,
        messagesChange: 8,
        commands: 198,
        commandsChange: -3,
        activeTimeSeconds: 30180, // 8h 23m
        activeTimeChange: 15
    ))
    .padding()
    .frame(height: 140)
}
