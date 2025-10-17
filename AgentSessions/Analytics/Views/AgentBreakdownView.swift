import SwiftUI

/// Shows agent usage breakdown with progress bars
struct AgentBreakdownView: View {
    let breakdown: [AnalyticsAgentBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Text("By Agent")
                .font(.headline)
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
        .frame(height: AnalyticsDesign.secondaryCardHeight)
        .padding(AnalyticsDesign.cardPadding)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius))
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
        VStack(alignment: .leading, spacing: 8) {
            // Agent name + percentage
            HStack {
                Text(agent.agent.displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(Int(agent.percentage))%")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(height: 8)

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.agentColor(for: agent.agent))
                        .frame(width: geometry.size.width * (agent.percentage / 100.0), height: 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: agent.percentage)
                }
            }
            .frame(height: 8)

            // Details (sessions • duration)
            Text(agent.detailsFormatted)
                .font(.caption)
                .foregroundStyle(.tertiary)
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
