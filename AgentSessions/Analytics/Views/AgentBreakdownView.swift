import SwiftUI

/// Shows agent usage breakdown with progress bars
struct AgentBreakdownView: View {
    let breakdown: [AnalyticsAgentBreakdown]
    @Binding var metric: AnalyticsAggregationMetric

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @State private var isFlipped = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Front side - existing progress bars
            frontView
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(isFlipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )

            // Back side - detailed agent stats
            backView
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(isFlipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0)
                )
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.4)) {
                isFlipped.toggle()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
        }
        .accessibilityHint("Tap to flip card and see agent details")
    }

    private var frontView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("By Agent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Metric toggle (no label for cleaner look)
                Picker("", selection: $metric) {
                    ForEach(AnalyticsAggregationMetric.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .help(metric.detailDescription)

                // Flip hint icon
                if !isFlipped {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0.8 : 0.3)
                        .animation(.easeInOut(duration: 0.2), value: isHovered)
                }
            }

            if breakdown.isEmpty {
                emptyState
            } else {
                agentRowsSection
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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

    private var backView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with flip hint
            HStack {
                Text("Agent Details")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 0.8 : 0.3)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
            }

            if breakdown.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Per-agent detailed cards
                        ForEach(breakdown, id: \.id) { agent in
                            agentDetailCard(agent)
                        }

                        Divider().opacity(0.2)

                        // Summary insights
                        VStack(alignment: .leading, spacing: 12) {
                            Text("INSIGHTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(agentInsights, id: \.self) { insight in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color.blue.opacity(0.5))
                                            .frame(width: 4, height: 4)

                                        Text(insight)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var agentRowsSection: some View {
        ViewThatFits(in: .vertical) {
            agentRowsView(style: .regular)
            agentRowsView(style: .compact)
            ScrollView {
                agentRowsView(style: .compact)
                    .padding(.vertical, 4)
            }
        }
    }

    private func agentRowsView(style: AgentRowStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(breakdown.enumerated()), id: \.element.id) { index, agent in
                AgentRow(agent: agent, metric: metric, monochrome: stripMonochrome, style: style)
                    .padding(.vertical, style.rowPadding)

                if index < breakdown.count - 1 {
                    Divider()
                        .opacity(0.3)
                }
            }
        }
    }

    // MARK: - Back View Components

    private func agentDetailCard(_ agent: AnalyticsAgentBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Agent header
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.agentColor(for: agent.agent, monochrome: stripMonochrome))
                    .frame(width: 12, height: 12)

                Text(agent.agent.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Percentage badge
                Text("\(Int(agent.percentage(for: metric)))%")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.agentColor(for: agent.agent, monochrome: stripMonochrome).opacity(0.2))
                    .cornerRadius(6)
            }

            // Metrics grid
            HStack(spacing: 12) {
                metricPill(
                    icon: "square.stack.3d.up.fill",
                    label: "Sessions",
                    value: "\(agent.sessionCount)"
                )

                metricPill(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: "Messages",
                    value: "\(agent.messageCount)"
                )

                metricPill(
                    icon: "clock.fill",
                    label: "Time",
                    value: agent.durationFormatted
                )
            }

            // Efficiency metrics
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Avg Session")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(avgSessionLength(for: agent))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Divider().frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Msgs/Session")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", avgMessagesPerSession(for: agent)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Divider().frame(height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Efficiency")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(efficiencyRating(for: agent))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(efficiencyColor(for: agent))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func metricPill(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .cornerRadius(6)
    }

    // MARK: - Back View Data Computations

    private func avgSessionLength(for agent: AnalyticsAgentBreakdown) -> String {
        guard agent.sessionCount > 0 else { return "N/A" }
        let avgSeconds = agent.durationSeconds / Double(agent.sessionCount)
        return AnalyticsSummary.formatDuration(avgSeconds)
    }

    private func avgMessagesPerSession(for agent: AnalyticsAgentBreakdown) -> Double {
        guard agent.sessionCount > 0 else { return 0 }
        return Double(agent.messageCount) / Double(agent.sessionCount)
    }

    private func efficiencyRating(for agent: AnalyticsAgentBreakdown) -> String {
        let msgsPerSession = avgMessagesPerSession(for: agent)
        if msgsPerSession >= 5 {
            return "High"
        } else if msgsPerSession >= 3 {
            return "Medium"
        } else {
            return "Low"
        }
    }

    private func efficiencyColor(for agent: AnalyticsAgentBreakdown) -> Color {
        let rating = efficiencyRating(for: agent)
        switch rating {
        case "High": return .green
        case "Medium": return .orange
        default: return .secondary
        }
    }

    private var agentInsights: [String] {
        var insights: [String] = []

        guard !breakdown.isEmpty else { return insights }

        // Most productive agent
        if let topAgent = breakdown.max(by: { a, b in
            avgMessagesPerSession(for: a) < avgMessagesPerSession(for: b)
        }) {
            let avg = avgMessagesPerSession(for: topAgent)
            insights.append("\(topAgent.agent.displayName) most productive: \(String(format: "%.1f", avg)) msgs/session")
        }

        // Longest sessions
        if let longestAgent = breakdown.max(by: { a, b in
            (a.durationSeconds / Double(max(a.sessionCount, 1))) < (b.durationSeconds / Double(max(b.sessionCount, 1)))
        }) {
            let avgLength = avgSessionLength(for: longestAgent)
            insights.append("\(longestAgent.agent.displayName) has longest sessions: \(avgLength) avg")
        }

        // Most used agent
        if let mostUsed = breakdown.max(by: { $0.sessionCount < $1.sessionCount }) {
            let percentage = Int(mostUsed.sessionPercentage)
            insights.append("\(mostUsed.agent.displayName) used most: \(percentage)% of all sessions")
        }

        // Agent diversity
        let activeAgents = breakdown.filter { $0.sessionCount > 0 }.count
        if activeAgents > 1 {
            insights.append("Using \(activeAgents) different agents for variety")
        }

        return insights
    }
}

/// Individual agent row with progress bar
private struct AgentRow: View {
    let agent: AnalyticsAgentBreakdown
    let metric: AnalyticsAggregationMetric
    let monochrome: Bool
    let style: AgentRowStyle

    var body: some View {
        HStack(spacing: style.rowSpacing) {
            VStack(alignment: .leading, spacing: style.labelSpacing) {
                Text(agent.agent.displayName)
                    .font(.system(size: style.nameSize, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(agent.details(for: metric))
                    .font(.system(size: style.detailSize))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 80, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .systemGray).opacity(0.2))

                    // Foreground bar
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.agentColor(for: agent.agent, monochrome: monochrome))
                        .frame(width: max(0, geometry.size.width * (agent.percentage(for: metric) / 100.0)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: agent.percentage(for: metric))
                }
            }
            .frame(height: style.barHeight)
            .frame(maxWidth: .infinity)

            Text("\(Int(agent.percentage(for: metric)))%")
                .font(.system(size: style.percentSize, weight: .medium))
                .frame(width: style.percentWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.3), value: agent.percentage(for: metric))
        }
    }
}

private struct AgentRowStyle {
    let nameSize: CGFloat
    let detailSize: CGFloat
    let percentSize: CGFloat
    let barHeight: CGFloat
    let rowPadding: CGFloat
    let rowSpacing: CGFloat
    let labelSpacing: CGFloat
    let percentWidth: CGFloat

    static let regular = AgentRowStyle(
        nameSize: 15,
        detailSize: 12,
        percentSize: 14,
        barHeight: 12,
        rowPadding: 9,
        rowSpacing: 16,
        labelSpacing: 6,
        percentWidth: 45
    )

    static let compact = AgentRowStyle(
        nameSize: 13,
        detailSize: 11,
        percentSize: 12,
        barHeight: 10,
        rowPadding: 6,
        rowSpacing: 12,
        labelSpacing: 4,
        percentWidth: 40
    )
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
