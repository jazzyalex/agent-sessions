import SwiftUI

/// Shows agent usage breakdown with progress bars
struct AgentBreakdownView: View {
    let breakdown: [AnalyticsAgentBreakdown]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("By Agent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            if breakdown.isEmpty {
                emptyState
            } else {
                // Agent rows
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(breakdown) { agent in
                        AgentRow(agent: agent)
                    }
                }
            }

            Spacer()
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No data")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Individual agent row with progress bar
private struct AgentRow: View {
    let agent: AnalyticsAgentBreakdown

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(agent.agent.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(agent.detailsFormatted)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .systemGray).opacity(0.35))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.agentColor(for: agent.agent))
                        .frame(width: max(0, geometry.size.width * (agent.percentage / 100.0)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: agent.percentage)
                }
            }
            .frame(height: 8)
            .frame(maxWidth: .infinity)

            Text("\(Int(agent.percentage))%")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 45, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Agent Breakdown") {
    AgentBreakdownView(breakdown: [
        AnalyticsAgentBreakdown(
            agent: .codex,
            sessionCount: 52,
            percentage: 60,
            durationSeconds: 18720 // 5h 12m
        ),
        AnalyticsAgentBreakdown(
            agent: .claude,
            sessionCount: 35,
            percentage: 40,
            durationSeconds: 11460 // 3h 11m
        )
    ])
    .padding()
    .frame(width: 350)
}

#Preview("Agent Breakdown - Empty") {
    AgentBreakdownView(breakdown: [])
        .padding()
        .frame(width: 350)
}
