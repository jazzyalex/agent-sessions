import SwiftUI
import Charts

/// Primary chart showing sessions over time, stacked by agent
struct SessionsChartView: View {
    let data: [AnalyticsTimeSeriesPoint]
    let dateRange: AnalyticsDateRange
    @Binding var metric: AnalyticsAggregationMetric

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("StripMonochromeMeters") private var stripMonochrome: Bool = false
    @State private var isFlipped = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Front side - existing chart view
            frontView
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(isFlipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )

            // Back side - insights view
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
        .accessibilityHint("Tap to flip card and see insights")
    }

    private var frontView: some View {
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
                                .fill(Color.agentColor(for: agent, monochrome: stripMonochrome))
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

                // Flip hint icon
                if !isFlipped {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0.8 : 0.3)
                        .animation(.easeInOut(duration: 0.2), value: isHovered)
                }
            }

            // Chart
            if data.isEmpty {
                emptyState
            } else {
                chart
            }
        }
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
            SessionSource.codex.displayName: Color.agentColor(for: .codex, monochrome: stripMonochrome),
            SessionSource.claude.displayName: Color.agentColor(for: .claude, monochrome: stripMonochrome),
            SessionSource.gemini.displayName: Color.agentColor(for: .gemini, monochrome: stripMonochrome),
            SessionSource.opencode.displayName: Color.agentColor(for: .opencode, monochrome: stripMonochrome),
            SessionSource.copilot.displayName: Color.agentColor(for: .copilot, monochrome: stripMonochrome),
            SessionSource.droid.displayName: Color.agentColor(for: .droid, monochrome: stripMonochrome)
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

    private var backView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with flip back hint
            HStack {
                Text("Insights & Patterns")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 0.8 : 0.3)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
            }

            if data.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Trends Section
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TRENDS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            HStack(spacing: 16) {
                                // Mini sparklines side-by-side
                                trendCard(
                                    label: "Sessions",
                                    data: sessionsSparkline,
                                    change: calculateGrowth(sessionsSparkline),
                                    color: .blue
                                )

                                trendCard(
                                    label: "Messages",
                                    data: messagesSparkline,
                                    change: calculateGrowth(messagesSparkline),
                                    color: .green
                                )

                                if !uniqueAgents.isEmpty {
                                    trendCard(
                                        label: "Activity",
                                        data: activitySparkline,
                                        change: calculateGrowth(activitySparkline),
                                        color: .orange
                                    )
                                }
                            }
                        }

                        Divider().opacity(0.2)

                        // Key Insights Grid
                        VStack(alignment: .leading, spacing: 12) {
                            Text("KEY INSIGHTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                insightCard(
                                    icon: "chart.bar.fill",
                                    label: "Peak Period",
                                    value: peakPeriodText
                                )

                                insightCard(
                                    icon: "flame.fill",
                                    label: "Current Streak",
                                    value: currentStreakText
                                )

                                insightCard(
                                    icon: "chart.line.uptrend.xyaxis",
                                    label: "Avg Quality",
                                    value: averageQualityText
                                )

                                insightCard(
                                    icon: "clock.arrow.circlepath",
                                    label: "Most Active Day",
                                    value: mostActiveDayText
                                )
                            }
                        }

                        Divider().opacity(0.2)

                        // Patterns Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PATTERNS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(patterns, id: \.self) { pattern in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color.blue.opacity(0.5))
                                            .frame(width: 4, height: 4)

                                        Text(pattern)
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

    // MARK: - Back View Components

    private func trendCard(label: String, data: [Double], change: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            MiniSparklineView(values: data, color: color)
                .frame(height: 30)

            HStack(spacing: 4) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9))
                Text(String(format: "%+.0f%%", change))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(change >= 0 ? .green : .red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func insightCard(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Back View Data Computations

    private var sessionsSparkline: [Double] {
        let grouped = Dictionary(grouping: data) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }
        return sorted.map { _, points in
            Double(points.reduce(0) { $0 + $1.sessionCount })
        }
    }

    private var messagesSparkline: [Double] {
        let grouped = Dictionary(grouping: data) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }
        return sorted.map { _, points in
            Double(points.reduce(0) { $0 + $1.messageCount })
        }
    }

    private var activitySparkline: [Double] {
        let grouped = Dictionary(grouping: data) { $0.date }
        let sorted = grouped.sorted { $0.key < $1.key }
        return sorted.map { _, points in
            let sessions = Double(points.reduce(0) { $0 + $1.sessionCount })
            let messages = Double(points.reduce(0) { $0 + $1.messageCount })
            return sessions > 0 ? messages / sessions : 0
        }
    }

    private func calculateGrowth(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let firstHalf = values.prefix(values.count / 2)
        let secondHalf = values.suffix(values.count - values.count / 2)
        let firstAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard firstAvg > 0 else { return secondAvg > 0 ? 100 : 0 }
        return ((secondAvg - firstAvg) / firstAvg) * 100
    }

    private var peakPeriodText: String {
        let grouped = Dictionary(grouping: data) { $0.date }
        guard let peak = grouped.max(by: { a, b in
            let aSum = a.value.reduce(0) { $0 + $1.sessionCount }
            let bSum = b.value.reduce(0) { $0 + $1.sessionCount }
            return aSum < bSum
        }) else { return "N/A" }

        let count = peak.value.reduce(0) { $0 + $1.sessionCount }
        let label = dateRange == .last7Days
            ? AppDateFormatting.weekdayAbbrev(peak.key)
            : AppDateFormatting.monthDayAbbrev(peak.key)
        return "\(label) (\(count))"
    }

    private var currentStreakText: String {
        let grouped = Dictionary(grouping: data) { Calendar.current.startOfDay(for: $0.date) }
        let sortedDates = grouped.keys.sorted()

        var streak = 0
        var lastDate: Date?

        for date in sortedDates.reversed() {
            if let last = lastDate {
                let dayDiff = Calendar.current.dateComponents([.day], from: date, to: last).day ?? 0
                if dayDiff == 1 {
                    streak += 1
                } else {
                    break
                }
            } else {
                // Check if today or yesterday
                let today = Calendar.current.startOfDay(for: Date())
                let dayDiff = Calendar.current.dateComponents([.day], from: date, to: today).day ?? 0
                if dayDiff <= 1 {
                    streak = 1
                } else {
                    break
                }
            }
            lastDate = date
        }

        return streak > 0 ? "\(streak) day\(streak == 1 ? "" : "s")" : "No streak"
    }

    private var averageQualityText: String {
        let totalSessions = data.reduce(0) { $0 + $1.sessionCount }
        let totalMessages = data.reduce(0) { $0 + $1.messageCount }
        guard totalSessions > 0 else { return "N/A" }
        let avg = Double(totalMessages) / Double(totalSessions)
        return String(format: "%.1f msgs/session", avg)
    }

    private var mostActiveDayText: String {
        let grouped = Dictionary(grouping: data) { Calendar.current.component(.weekday, from: $0.date) }
        guard let mostActive = grouped.max(by: { a, b in
            let aCount = a.value.reduce(0) { $0 + $1.sessionCount }
            let bCount = b.value.reduce(0) { $0 + $1.sessionCount }
            return aCount < bCount
        }) else { return "N/A" }

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let dayName = dayNames[(mostActive.key + 6) % 7]  // Adjust for 1=Sunday
        return dayName
    }

    private var patterns: [String] {
        var result: [String] = []

        // Weekend vs weekday pattern
        let weekdayData = data.filter { Calendar.current.component(.weekday, from: $0.date) >= 2 && Calendar.current.component(.weekday, from: $0.date) <= 6 }
        let weekendData = data.filter { Calendar.current.component(.weekday, from: $0.date) == 1 || Calendar.current.component(.weekday, from: $0.date) == 7 }

        let weekdaySessions = weekdayData.reduce(0) { $0 + $1.sessionCount }
        let weekendSessions = weekendData.reduce(0) { $0 + $1.sessionCount }

        if weekendSessions > 0 && weekdaySessions > 0 {
            let ratio = Double(weekdaySessions) / Double(weekendSessions)
            if ratio > 1.5 {
                result.append("Weekdays \(Int((ratio - 1) * 100))% more active than weekends")
            } else if ratio < 0.67 {
                result.append("Weekends \(Int((1/ratio - 1) * 100))% more active than weekdays")
            }
        }

        // Most used agent
        let agentGroups = Dictionary(grouping: data) { $0.agent }
        if let topAgent = agentGroups.max(by: { a, b in
            let aCount = a.value.reduce(0) { $0 + $1.sessionCount }
            let bCount = b.value.reduce(0) { $0 + $1.sessionCount }
            return aCount < bCount
        }) {
            let count = topAgent.value.reduce(0) { $0 + $1.sessionCount }
            let total = data.reduce(0) { $0 + $1.sessionCount }
            let percentage = Int(Double(count) / Double(total) * 100)
            result.append("\(topAgent.key.displayName) used in \(percentage)% of sessions")
        }

        // Growth trend
        let growth = calculateGrowth(sessionsSparkline)
        if abs(growth) > 10 {
            if growth > 0 {
                result.append("Sessions trending up \(Int(growth))%")
            } else {
                result.append("Sessions declining \(Int(abs(growth)))%")
            }
        }

        return result.isEmpty ? ["Not enough data for patterns"] : result
    }

    private var uniqueAgents: [SessionSource] {
        Array(Set(data.map { $0.agent })).sorted { $0.displayName < $1.displayName }
    }
}

// MARK: - Mini Sparkline Component

/// Minimal sparkline chart for back view trends
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

// MARK: - Extension for SessionsChartView continued

extension SessionsChartView {
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
