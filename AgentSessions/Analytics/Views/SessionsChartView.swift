import SwiftUI
import Charts

/// Primary chart showing sessions over time, stacked by agent
struct SessionsChartView: View {
    let data: [AnalyticsTimeSeriesPoint]
    let dateRange: AnalyticsDateRange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Sessions Over Time")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                // Legend
                HStack(spacing: 16) {
                    ForEach(uniqueAgents, id: \.self) { agent in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.agentColor(for: agent))
                                .frame(width: 8, height: 8)

                            Text(agent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Chart
            if data.isEmpty {
                emptyState
            } else {
                chart
            }
        }
        .padding(AnalyticsDesign.cardPadding)
        .background(Color("CardBackground"))
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius))
    }

    private var chart: some View {
        Chart(data) { item in
            BarMark(
                x: .value("Date", item.date, unit: dateUnit),
                y: .value("Sessions", item.count),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Agent", item.agent))
            .cornerRadius(AnalyticsDesign.chartBarCornerRadius)
        }
        .chartForegroundStyleScale([
            "Codex CLI": Color.agentCodex,
            "Claude Code": Color.agentClaude,
            "Gemini": Color.agentGemini
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
        .frame(height: AnalyticsDesign.primaryChartHeight - 60) // Subtract header height
        .animation(.easeInOut(duration: AnalyticsDesign.chartDuration), value: data)
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
        .frame(height: AnalyticsDesign.primaryChartHeight - 60)
        .frame(maxWidth: .infinity)
    }

    private var uniqueAgents: [String] {
        Array(Set(data.map { $0.agent })).sorted()
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

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: "Codex CLI",
                count: Int.random(in: 3...12)
            ))

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: "Claude Code",
                count: Int.random(in: 2...8)
            ))

            points.append(AnalyticsTimeSeriesPoint(
                date: date,
                agent: "Gemini",
                count: Int.random(in: 1...5)
            ))
        }

        return points.sorted { $0.date < $1.date }
    }()

    SessionsChartView(data: sampleData, dateRange: .last7Days)
        .padding()
        .frame(height: 320)
}

#Preview("Sessions Chart - Empty") {
    SessionsChartView(data: [], dateRange: .last7Days)
        .padding()
        .frame(height: 320)
}
