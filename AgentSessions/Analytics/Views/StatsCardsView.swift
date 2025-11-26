import SwiftUI

/// Displays the 4 summary stat cards at the top of analytics
struct StatsCardsView: View {
    let snapshot: AnalyticsSnapshot
    let dateRange: AnalyticsDateRange
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false

    private var summary: AnalyticsSummary { snapshot.summary }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: AnalyticsDesign.metricsCardSpacing),
                           count: 4)

        LazyVGrid(columns: columns,
                  alignment: .leading,
                  spacing: AnalyticsDesign.metricsCardSpacing) {
            // Sessions Card
            FlippableStatsCard(
                front: StatsCard(
                    icon: "square.stack.3d.up.fill",
                    label: "Sessions",
                    value: AnalyticsSummary.formatNumber(summary.sessions),
                    change: AnalyticsSummary.formatChange(summary.sessionsChange)
                ),
                back: CardBackView(
                    sparklineData: sparklineDataFor(sessions: true),
                    agentBreakdown: snapshot.agentBreakdown,
                    metric: .sessions,
                    insight: peakDayFor(sessions: true).map { "Peak: \($0)" },
                    extraInfo: nil,
                    monochrome: stripMonochrome
                )
            )
            .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
            .frame(minHeight: AnalyticsDesign.statsCardHeight)
            .help(tooltipText(for: "sessions"))

            // Messages Card
            FlippableStatsCard(
                front: StatsCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: "Messages",
                    value: AnalyticsSummary.formatNumber(summary.messages),
                    change: AnalyticsSummary.formatChange(summary.messagesChange)
                ),
                back: CardBackView(
                    sparklineData: sparklineDataFor(sessions: false),
                    agentBreakdown: snapshot.agentBreakdown,
                    metric: .messages,
                    insight: peakDayFor(sessions: false).map { "Peak: \($0)" },
                    extraInfo: summary.sessions > 0 ? String(format: "Avg %.1f msgs/session", Double(summary.messages) / Double(summary.sessions)) : nil,
                    monochrome: stripMonochrome
                )
            )
            .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
            .frame(minHeight: AnalyticsDesign.statsCardHeight)
            .help(tooltipText(for: "messages"))

            // Avg Session Length Card
            FlippableStatsCard(
                front: StatsCard(
                    icon: "clock.fill",
                    label: "Avg Session Length",
                    value: summary.avgSessionLengthFormatted,
                    change: AnalyticsSummary.formatChange(summary.avgSessionLengthChange)
                ),
                back: CardBackView(
                    sparklineData: sparklineDataForAvgLength(),
                    agentBreakdown: snapshot.agentBreakdown,
                    metric: .avgDuration,
                    insight: "Trend",
                    extraInfo: "Average session length per agent",
                    monochrome: stripMonochrome
                )
            )
            .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
            .frame(minHeight: AnalyticsDesign.statsCardHeight)
            .help(tooltipText(for: "avgLength"))

            // Total Duration Card
            FlippableStatsCard(
                front: StatsCard(
                    icon: "timer",
                    label: "Total Duration",
                    value: summary.activeTimeFormatted,
                    change: AnalyticsSummary.formatChange(summary.activeTimeChange)
                ),
                back: CardBackView(
                    sparklineData: sparklineDataForDuration(),
                    agentBreakdown: snapshot.agentBreakdown,
                    metric: .duration,
                    insight: "Commands: \(AnalyticsSummary.formatNumber(summary.commands))",
                    extraInfo: summary.commandsChange.map { AnalyticsSummary.formatChange($0) ?? "" },
                    monochrome: stripMonochrome
                )
            )
            .analyticsCard(padding: AnalyticsDesign.statsCardPadding, colorScheme: colorScheme)
            .frame(minHeight: AnalyticsDesign.statsCardHeight)
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

    // MARK: - Sparkline Data Helpers

    private func sparklineDataFor(sessions: Bool) -> [Double] {
        let grouped = Dictionary(grouping: snapshot.timeSeriesData) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }

        return sorted.map { _, points in
            Double(points.reduce(0) { $0 + (sessions ? $1.sessionCount : $1.messageCount) })
        }
    }

    private func sparklineDataForDuration() -> [Double] {
        // Approximate duration from session/message counts (actual duration not in time series)
        let grouped = Dictionary(grouping: snapshot.timeSeriesData) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }

        return sorted.map { _, points in
            Double(points.reduce(0) { $0 + $1.sessionCount }) * (summary.avgSessionLengthSeconds / Double(max(summary.sessions, 1)))
        }
    }

    private func sparklineDataForAvgLength() -> [Double] {
        // Approximate avg session length trend using messages per session as proxy
        let grouped = Dictionary(grouping: snapshot.timeSeriesData) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }

        return sorted.map { _, points in
            let totalSessions = Double(points.reduce(0) { $0 + $1.sessionCount })
            let totalMessages = Double(points.reduce(0) { $0 + $1.messageCount })
            return totalSessions > 0 ? (totalMessages / totalSessions) : 0
        }
    }

    private func peakDayFor(sessions: Bool) -> String? {
        let grouped = Dictionary(grouping: snapshot.timeSeriesData) { $0.date }
        guard let peak = grouped.max(by: { a, b in
            let aSum = a.value.reduce(0) { $0 + (sessions ? $1.sessionCount : $1.messageCount) }
            let bSum = b.value.reduce(0) { $0 + (sessions ? $1.sessionCount : $1.messageCount) }
            return aSum < bSum
        }) else { return nil }

        let count = peak.value.reduce(0) { $0 + (sessions ? $1.sessionCount : $1.messageCount) }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return "\(formatter.string(from: peak.key)) (\(count))"
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

// MARK: - Mini Sparkline

/// Minimal sparkline chart for card backs
private struct MiniSparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                Path { path in
                    let maxValue = values.max() ?? 1
                    let minValue = values.min() ?? 0
                    let range = maxValue - minValue
                    let adjustedRange = range > 0 ? range : 1

                    let stepX = geometry.size.width / CGFloat(values.count - 1)

                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * stepX
                        let normalizedValue = (value - minValue) / adjustedRange
                        let y = geometry.size.height - (CGFloat(normalizedValue) * geometry.size.height)

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Card Back View

/// Metric type for card back display
private enum CardBackMetric {
    case sessions
    case messages
    case duration
    case avgDuration  // Average session length per agent
}

/// Back side of flippable stats card
private struct CardBackView: View {
    let sparklineData: [Double]
    let agentBreakdown: [AnalyticsAgentBreakdown]
    let metric: CardBackMetric
    let insight: String?
    let extraInfo: String?
    let monochrome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sparkline
            if !sparklineData.isEmpty {
                MiniSparklineView(values: sparklineData, color: .blue.opacity(0.7))
                    .frame(height: 24)
            } else {
                Spacer().frame(height: 24)
            }

            Divider().opacity(0.2)

            // Agent breakdown
            if !agentBreakdown.isEmpty {
                Text("BY AGENT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(agentBreakdown.prefix(4), id: \.agent) { agent in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.agentColor(for: agent.agent, monochrome: monochrome))
                                .frame(width: 5, height: 5)
                            Text(agentDisplayText(for: agent))
                                .font(.system(size: 10))
                                .foregroundStyle(.primary)
                            Text("(\(Int(agentPercentage(for: agent)))%)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider().opacity(0.2)

            // Insight/extra info
            VStack(alignment: .leading, spacing: 2) {
                if let insight = insight {
                    Text(insight)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let extraInfo = extraInfo {
                    Text(extraInfo)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func agentDisplayText(for agent: AnalyticsAgentBreakdown) -> String {
        switch metric {
        case .sessions:
            return "\(agent.agent.displayName) \(agent.sessionCount)"
        case .messages:
            return "\(agent.agent.displayName) \(agent.messageCount)"
        case .duration:
            return "\(agent.agent.displayName) \(AnalyticsSummary.formatDuration(agent.durationSeconds))"
        case .avgDuration:
            // Show average session length for this agent
            let avgSeconds = agent.sessionCount > 0 ? agent.durationSeconds / Double(agent.sessionCount) : 0
            return "\(agent.agent.displayName) \(AnalyticsSummary.formatDuration(avgSeconds))"
        }
    }

    private func agentPercentage(for agent: AnalyticsAgentBreakdown) -> Double {
        switch metric {
        case .sessions:
            return agent.sessionPercentage
        case .messages:
            return agent.messagePercentage
        case .duration:
            // Calculate duration percentage from total
            let total = agentBreakdown.reduce(0.0) { $0 + $1.durationSeconds }
            return total > 0 ? (agent.durationSeconds / total * 100.0) : 0
        case .avgDuration:
            // Calculate percentage based on average session length
            let avgSeconds = agent.sessionCount > 0 ? agent.durationSeconds / Double(agent.sessionCount) : 0
            let totalAvg = agentBreakdown.reduce(0.0) { sum, a in
                let agentAvg = a.sessionCount > 0 ? a.durationSeconds / Double(a.sessionCount) : 0
                return sum + agentAvg
            }
            return totalAvg > 0 ? (avgSeconds / totalAvg * 100.0) : 0
        }
    }
}

// MARK: - Flippable Card

/// Wrapper that adds flip interaction to stats cards
private struct FlippableStatsCard: View {
    let front: StatsCard
    let back: CardBackView
    @State private var isFlipped = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Front side
            ZStack(alignment: .topTrailing) {
                front

                // Flip hint icon
                if !isFlipped {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0.8 : 0.3)
                        .padding(8)
                        .animation(.easeInOut(duration: 0.2), value: isHovered)
                }
            }
            .opacity(isFlipped ? 0 : 1)
            .rotation3DEffect(
                .degrees(isFlipped ? 180 : 0),
                axis: (x: 0, y: 1, z: 0)
            )

            // Back side
            back
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(isFlipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0)
                )
        }
        .contentShape(Rectangle()) // Make entire bounds tappable
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
        .accessibilityHint("Tap to flip card and see more details")
    }
}

// MARK: - Previews

#Preview("Stats Cards") {
    let snapshot = AnalyticsSnapshot(
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
        timeSeriesData: [],
        agentBreakdown: [
            AnalyticsAgentBreakdown(agent: .codex, sessionCount: 52, messageCount: 210, sessionPercentage: 60, messagePercentage: 55, durationSeconds: 18720),
            AnalyticsAgentBreakdown(agent: .claude, sessionCount: 35, messageCount: 132, sessionPercentage: 40, messagePercentage: 45, durationSeconds: 11460)
        ],
        heatmapCells: [],
        mostActiveTimeRange: nil,
        lastUpdated: Date()
    )

    StatsCardsView(snapshot: snapshot, dateRange: .last7Days)
        .padding()
        .frame(height: 140)
}
