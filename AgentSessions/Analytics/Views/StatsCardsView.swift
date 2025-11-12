import SwiftUI

/// Displays the 4 summary stat cards at the top of analytics
struct StatsCardsView: View {
    let summary: AnalyticsSummary
    let dateRange: AnalyticsDateRange
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: AnalyticsDesign.metricsCardSpacing),
                           count: 4)

        LazyVGrid(columns: columns,
                  alignment: .leading,
                  spacing: AnalyticsDesign.metricsCardSpacing) {
            StatsCard(
                icon: "square.stack.3d.up.fill",
                label: "Sessions",
                value: AnalyticsSummary.formatNumber(summary.sessions),
                change: AnalyticsSummary.formatChange(summary.sessionsChange)
            )
            .padding(AnalyticsDesign.statsCardPadding)
            .analyticsCard(padding: 0, colorScheme: colorScheme)
            .help(tooltipText(for: "sessions"))

            StatsCard(
                icon: "bubble.left.and.bubble.right.fill",
                label: "Messages",
                value: AnalyticsSummary.formatNumber(summary.messages),
                change: AnalyticsSummary.formatChange(summary.messagesChange)
            )
            .padding(AnalyticsDesign.statsCardPadding)
            .analyticsCard(padding: 0, colorScheme: colorScheme)
            .help(tooltipText(for: "messages"))

            StatsCard(
                icon: "clock.fill",
                label: "Avg Session Length",
                value: summary.avgSessionLengthFormatted,
                change: AnalyticsSummary.formatChange(summary.avgSessionLengthChange)
            )
            .padding(AnalyticsDesign.statsCardPadding)
            .analyticsCard(padding: 0, colorScheme: colorScheme)
            .help(tooltipText(for: "avgLength"))

            StatsCard(
                icon: "timer",
                label: "Total Duration",
                value: summary.activeTimeFormatted,
                change: AnalyticsSummary.formatChange(summary.activeTimeChange)
            )
            .padding(AnalyticsDesign.statsCardPadding)
            .analyticsCard(padding: 0, colorScheme: colorScheme)
            .help(tooltipText(for: "totalDuration"))
        }
        .fixedSize(horizontal: false, vertical: true)  // Grid tells the real height
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tooltipText(for metric: String) -> String {
        let comparisonText: String
        switch dateRange {
        case .today:
            comparisonText = "Change shows vs. yesterday."
        case .last7Days:
            comparisonText = "Change shows vs. previous 7 days."
        case .last30Days:
            comparisonText = "Change shows vs. previous 30 days."
        case .last90Days:
            comparisonText = "Change shows vs. previous 90 days."
        case .allTime:
            comparisonText = "No comparison available for all-time view."
        case .custom:
            comparisonText = "Change shows vs. prior period of equal length."
        }

        switch metric {
        case "sessions":
            return "Unique conversation sessions.\n\(comparisonText)"
        case "messages":
            return "Total messages exchanged.\n\(comparisonText)"
        case "avgLength":
            return "Average session duration (first to last message).\n\(comparisonText)"
        case "totalDuration":
            return "Total active time across all sessions.\n\(comparisonText)"
        default:
            return ""
        }
    }
}

/// Individual stat card component
private struct StatsCard: View {
    let icon: String
    let label: String
    let value: String
    let change: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icon + Label
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }

            // Value (centered vertically)
            Text(value)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.primary)

            // Change indicator (12pt from bottom)
            if let change = change {
                Text(change)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(changeColor(for: change))
            } else {
                // Placeholder to maintain spacing
                Text(" ")
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(change != nil ? ", \(change!)" : "")")
    }

    private func changeColor(for change: String) -> Color {
        if change.contains("+") {
            return .green
        } else if change.contains("-") {
            return .red
        } else {
            return .secondary
        }
    }
}

// MARK: - Previews

#Preview("Stats Cards") {
    StatsCardsView(
        summary: AnalyticsSummary(
            sessions: 87,
            sessionsChange: 12,
            messages: 342,
            messagesChange: 8,
            commands: 198,
            commandsChange: -3,
            activeTimeSeconds: 30180, // 8h 23m
            activeTimeChange: 15,
            avgSessionLengthSeconds: 1260, // 21m average
            avgSessionLengthChange: 5
        ),
        dateRange: .last7Days
    )
    .padding()
    .frame(height: 140)
}
