import SwiftUI

/// Shows agent usage breakdown with progress bars
struct AgentBreakdownView: View {
    let breakdown: [AnalyticsAgentBreakdown]
    @Binding var metric: AnalyticsAggregationMetric

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("By Agent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Picker("Aggregation", selection: $metric) {
                    ForEach(AnalyticsAggregationMetric.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .help(metric.detailDescription)
            }

            if breakdown.isEmpty {
                emptyState
            } else {
                // Agent rows
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(breakdown) { agent in
                        AgentRow(agent: agent, metric: metric)
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
    let metric: AnalyticsAggregationMetric

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(agent.agent.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(agent.details(for: metric))
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
                        .frame(width: max(0, geometry.size.width * (agent.percentage(for: metric) / 100.0)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: agent.percentage(for: metric))
                }
            }
            .frame(height: 8)
            .frame(maxWidth: .infinity)

            Text("\(Int(agent.percentage(for: metric)))%")
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
            messageCount: 310,
            sessionPercentage: 60,
            messagePercentage: 55,
            durationSeconds: 18720 // 5h 12m
        ),
        AnalyticsAgentBreakdown(
            agent: .claude,
            sessionCount: 35,
            messageCount: 260,
            sessionPercentage: 40,
            messagePercentage: 45,
            durationSeconds: 11460 // 3h 11m
        )
    ], metric: .constant(.sessions))
    .padding()
    .frame(width: 350)
}

#Preview("Agent Breakdown - Empty") {
    AgentBreakdownView(breakdown: [], metric: .constant(.sessions))
        .padding()
        .frame(width: 350)
}
