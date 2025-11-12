import SwiftUI
import Charts

/// Primary chart showing sessions over time, stacked by agent
struct SessionsChartView: View {
    let data: [AnalyticsTimeSeriesPoint]
    let dateRange: AnalyticsDateRange
    @Binding var metric: AnalyticsAggregationMetric

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Sessions Over Time")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Legend
                HStack(spacing: 20) {
                    ForEach(uniqueAgents, id: \.self) { agent in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.agentColor(for: agent))
                                .frame(width: 8, height: 8)

                            Text(agent.displayName)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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
            }

            // Chart
            if data.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
    }

    private var chart: some View {
        Chart(data) { item in
            BarMark(
                x: .value("Date", item.date, unit: dateUnit),
                y: .value(metric.axisLabel, item.value(for: metric)),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Agent", item.agentDisplayName))
            .cornerRadius(AnalyticsDesign.chartBarCornerRadius)
        }
        .chartForegroundStyleScale([
            SessionSource.codex.displayName: Color.agentCodex,
            SessionSource.claude.displayName: Color.agentClaude,
            SessionSource.gemini.displayName: Color.agentGemini
        ])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color("AxisGridline"))
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color("AxisGridline"))
                AxisValueLabel()
            }
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .animation(.easeInOut(duration: AnalyticsDesign.chartDuration), value: data)
        .animation(.easeInOut(duration: AnalyticsDesign.chartDuration), value: metric)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Start coding to see analytics")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var uniqueAgents: [SessionSource] {
        Array(Set(data.map { $0.agent })).sorted { $0.displayName < $1.displayName }
    }

    private var dateUnit: Calendar.Component {
        switch dateRange.aggregationGranularity {
        case .day:
            return .day
        case .weekOfYear:
            return .weekOfYear
        case .month:
            return .month
        case .hour:
            return .hour
        default:
            return .day
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch dateRange {
        case .today:
            return .dateTime.hour()
        case .last7Days:
            return .dateTime.weekday(.abbreviated)
        case .last30Days:
            return .dateTime.day().month(.abbreviated)
        case .last90Days:
            return .dateTime.month(.abbreviated).day()
        case .allTime:
            return .dateTime.month(.abbreviated).year()
        case .custom:
            return .dateTime.day().month(.abbreviated)
        }
    }
}

// MARK: - Previews

#Preview("Sessions Chart") {
    let sampleData: [AnalyticsTimeSeriesPoint] = {
        let calendar = Calendar.current
        var points: [AnalyticsTimeSeriesPoint] = []

        for dayOffset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!

            let codexSessions = Int.random(in: 3...12)
            let claudeSessions = Int.random(in: 2...8)
            let geminiSessions = Int.random(in: 1...5)

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: .codex,
                sessionCount: codexSessions,
                messageCount: codexSessions * Int.random(in: 2...6)
            ))

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: .claude,
                sessionCount: claudeSessions,
                messageCount: claudeSessions * Int.random(in: 3...7)
            ))

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: .gemini,
                sessionCount: geminiSessions,
                messageCount: geminiSessions * Int.random(in: 2...5)
            ))
        }

        return points.sorted { $0.date < $1.date }
    }()

    SessionsChartView(data: sampleData, dateRange: .last7Days, metric: .constant(.sessions))
        .padding()
        .frame(height: 320)
}

#Preview("Sessions Chart - Empty") {
    SessionsChartView(data: [], dateRange: .last7Days, metric: .constant(.sessions))
        .padding()
        .frame(height: 320)
}
