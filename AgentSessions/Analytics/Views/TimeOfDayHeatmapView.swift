import SwiftUI

/// Heatmap showing activity patterns by time of day and day of week
struct TimeOfDayHeatmapView: View {
    let cells: [AnalyticsHeatmapCell]
    let mostActive: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isFlipped = false
    @State private var isHovered = false

    // Grid dimensions
    private let rows = 7  // Mon-Sun
    private let cols = 8  // 12a-9p buckets

    var body: some View {
        ZStack {
            // Front side - existing heatmap
            frontView
                .opacity(isFlipped ? 0 : 1)
                .rotation3DEffect(
                    .degrees(isFlipped ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )

            // Back side - time slot details
            backView
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(
                    .degrees(isFlipped ? 0 : -180),
                    axis: (x: 0, y: 1, z: 0)
                )
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .accessibilityHint("Tap to flip card and see time details")
    }

    private var frontView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Time of Day")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Flip hint icon
                if !isFlipped {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 0.8 : 0.3)
                        .animation(.easeInOut(duration: 0.2), value: isHovered)
                }
            }
            .padding(.bottom, 16)

            if cells.isEmpty {
                emptyState
            } else {
                // Main heatmap content
                VStack(spacing: 0) {
                    // Hour labels row
                    HStack(spacing: 0) {
                        // Empty corner space for day labels column
                        Color.clear
                            .frame(width: 24, height: 20)

                        // Hour labels
                        HStack(spacing: 2) {
                            ForEach(0..<cols, id: \.self) { c in
                                Text(AnalyticsHeatmapCell.hourLabels[c])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 20)
                            }
                        }
                    }

                    // Heatmap grid with day labels
                    HStack(spacing: 0) {
                        // Day labels column
                        VStack(spacing: 2) {
                            ForEach(0..<rows, id: \.self) { r in
                                Text(["M", "T", "W", "T", "F", "S", "S"][r])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                    .frame(maxHeight: .infinity, alignment: .center)
                            }
                        }

                        // Heatmap cells grid
                        VStack(spacing: 2) {
                            ForEach(0..<rows, id: \.self) { row in
                                HStack(spacing: 2) {
                                    ForEach(0..<cols, id: \.self) { col in
                                        let heatCell = cells.first { $0.day == row && $0.hourBucket == col }
                                        let level = heatCell?.activityLevel ?? .none

                                        RoundedRectangle(cornerRadius: AnalyticsDesign.heatmapCellCornerRadius)
                                            .fill(cellColor(for: level))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Most Active footer
                    if let mostActive = mostActive {
                        HStack {
                            Spacer()
                            Text("Most Active: \(mostActive)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var backView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with flip hint
            HStack {
                Text("Time Insights")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 0.8 : 0.3)
                    .animation(.easeInOut(duration: 0.2), value: isHovered)
            }

            if cells.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Top Time Slots
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TOP TIME SLOTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            VStack(spacing: 8) {
                                ForEach(Array(topTimeSlots.prefix(3).enumerated()), id: \.offset) { index, slot in
                                    timeSlotBar(
                                        rank: index + 1,
                                        label: slot.label,
                                        count: slot.count,
                                        percentage: slot.percentage
                                    )
                                }
                            }
                        }

                        Divider().opacity(0.2)

                        // Day Patterns
                        VStack(alignment: .leading, spacing: 12) {
                            Text("DAY PATTERNS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            HStack(spacing: 4) {
                                ForEach(0..<7, id: \.self) { day in
                                    let dayActivity = activityForDay(day)
                                    VStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.blue.opacity(dayActivity.level))
                                            .frame(height: max(20, dayActivity.level * 60))

                                        Text(["M", "T", "W", "T", "F", "S", "S"][day])
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 90)

                            HStack(spacing: 16) {
                                statPill(label: "Weekday Avg", value: weekdayAverage)
                                statPill(label: "Weekend Avg", value: weekendAverage)
                            }
                        }

                        Divider().opacity(0.2)

                        // Time Period Characteristics
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ACTIVITY BY PERIOD")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            VStack(spacing: 8) {
                                periodRow(
                                    icon: "sunrise.fill",
                                    period: "Morning",
                                    hours: "6am - 12pm",
                                    activity: morningActivity,
                                    color: .orange
                                )

                                periodRow(
                                    icon: "sun.max.fill",
                                    period: "Afternoon",
                                    hours: "12pm - 6pm",
                                    activity: afternoonActivity,
                                    color: .yellow
                                )

                                periodRow(
                                    icon: "moon.stars.fill",
                                    period: "Evening",
                                    hours: "6pm - 12am",
                                    activity: eveningActivity,
                                    color: .purple
                                )

                                periodRow(
                                    icon: "moon.fill",
                                    period: "Night",
                                    hours: "12am - 6am",
                                    activity: nightActivity,
                                    color: .blue
                                )
                            }
                        }

                        Divider().opacity(0.2)

                        // Key Insights
                        VStack(alignment: .leading, spacing: 8) {
                            Text("KEY INSIGHTS")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)

                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(timeInsights, id: \.self) { insight in
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

            Spacer()
        }
    }

    // MARK: - Back View Components

    private func timeSlotBar(rank: Int, label: String, count: Int, percentage: Double) -> some View {
        HStack(spacing: 12) {
            // Rank badge
            Text("\(rank)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue.opacity(0.8)))

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .systemGray).opacity(0.2))

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.7))
                            .frame(width: geometry.size.width * (percentage / 100.0))
                    }
                }
                .frame(height: 8)
            }

            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private func periodRow(icon: String, period: String, hours: String, activity: Int, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(period)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text(hours)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < activityLevel(for: activity) ? color : Color(nsColor: .systemGray).opacity(0.2))
                        .frame(width: 6, height: 6)
                }

                Text("\(activity)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .cornerRadius(6)
    }

    // MARK: - Back View Data Computations

    private struct TimeSlotInfo {
        let label: String
        let count: Int
        let percentage: Double
    }

    private var topTimeSlots: [TimeSlotInfo] {
        let counts = Dictionary(grouping: cells) { cell in
            "\(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][cell.day]) \(AnalyticsHeatmapCell.hourLabels[cell.hourBucket])"
        }
        .mapValues { cells in
            cells.map { $0.activityLevel.rawValue }.reduce(0, +)
        }

        let total = counts.values.reduce(0, +)
        let sorted = counts.sorted { $0.value > $1.value }

        return sorted.map { slot in
            TimeSlotInfo(
                label: slot.key,
                count: slot.value,
                percentage: total > 0 ? Double(slot.value) / Double(total) * 100 : 0
            )
        }
    }

    private func activityForDay(_ day: Int) -> (level: Double, count: Int) {
        let dayCells = cells.filter { $0.day == day }
        let count = dayCells.map { $0.activityLevel.rawValue }.reduce(0, +)
        let maxPossible = cols * ActivityLevel.high.rawValue
        let level = maxPossible > 0 ? Double(count) / Double(maxPossible) : 0
        return (max(0.1, level), count)
    }

    private var weekdayAverage: String {
        let weekdayCells = cells.filter { $0.day >= 0 && $0.day <= 4 }
        let total = weekdayCells.map { $0.activityLevel.rawValue }.reduce(0, +)
        let avg = Double(total) / 5.0
        return String(format: "%.1f", avg)
    }

    private var weekendAverage: String {
        let weekendCells = cells.filter { $0.day == 5 || $0.day == 6 }
        let total = weekendCells.map { $0.activityLevel.rawValue }.reduce(0, +)
        let avg = Double(total) / 2.0
        return String(format: "%.1f", avg)
    }

    private var morningActivity: Int {
        cells.filter { $0.hourBucket >= 2 && $0.hourBucket <= 3 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)
    }

    private var afternoonActivity: Int {
        cells.filter { $0.hourBucket >= 4 && $0.hourBucket <= 5 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)
    }

    private var eveningActivity: Int {
        cells.filter { $0.hourBucket >= 6 && $0.hourBucket <= 7 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)
    }

    private var nightActivity: Int {
        cells.filter { $0.hourBucket >= 0 && $0.hourBucket <= 1 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)
    }

    private func activityLevel(for count: Int) -> Int {
        let maxActivity = [morningActivity, afternoonActivity, eveningActivity, nightActivity].max() ?? 1
        if count == 0 { return 0 }
        let percentage = Double(count) / Double(maxActivity)
        if percentage >= 0.8 { return 5 }
        if percentage >= 0.6 { return 4 }
        if percentage >= 0.4 { return 3 }
        if percentage >= 0.2 { return 2 }
        return 1
    }

    private var timeInsights: [String] {
        var insights: [String] = []

        // Most productive period
        let periods = [
            ("Morning", morningActivity),
            ("Afternoon", afternoonActivity),
            ("Evening", eveningActivity),
            ("Night", nightActivity)
        ]
        if let best = periods.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            insights.append("\(best.0) is your most active period")
        }

        // Weekday vs weekend
        let weekdayTotal = cells.filter { $0.day >= 0 && $0.day <= 4 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)
        let weekendTotal = cells.filter { $0.day == 5 || $0.day == 6 }
            .map { $0.activityLevel.rawValue }
            .reduce(0, +)

        if weekdayTotal > 0 && weekendTotal > 0 {
            let ratio = Double(weekdayTotal) / Double(weekendTotal)
            if ratio > 1.5 {
                insights.append("Weekdays \(Int((ratio - 1) * 100))% more active than weekends")
            } else if ratio < 0.67 {
                insights.append("Weekends \(Int((1/ratio - 1) * 100))% more active than weekdays")
            }
        }

        // Most active day
        let dayTotals = (0..<7).map { day in
            (day, cells.filter { $0.day == day }.map { $0.activityLevel.rawValue }.reduce(0, +))
        }
        if let bestDay = dayTotals.max(by: { $0.1 < $1.1 }), bestDay.1 > 0 {
            let dayName = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][bestDay.0]
            insights.append("\(dayName) is your busiest day")
        }

        // Late night coding
        if nightActivity > 0 {
            let nightPercentage = Int(Double(nightActivity) / Double(cells.map { $0.activityLevel.rawValue }.reduce(0, +)) * 100)
            if nightPercentage >= 15 {
                insights.append("Night owl: \(nightPercentage)% of activity after midnight")
            }
        }

        return insights.isEmpty ? ["Start tracking to see patterns"] : insights
    }


    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No data")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cellColor(for level: ActivityLevel) -> Color {
        switch level {
        case .none:
            return Color(nsColor: .underPageBackgroundColor)
        case .low:
            return Color.agentCodex.opacity(0.3)
        case .medium:
            return Color.agentCodex.opacity(0.6)
        case .high:
            return Color.agentCodex.opacity(1.0)
        }
    }
}


// MARK: - Previews

#Preview("Time of Day Heatmap") {
    let sampleCells: [AnalyticsHeatmapCell] = {
        var cells: [AnalyticsHeatmapCell] = []
        for day in 0..<7 {
            for bucket in 0..<8 {
                // Higher activity during work hours (buckets 3-5 = 9a-6p)
                let level: ActivityLevel
                if (3...5).contains(bucket) && day < 5 {
                    level = [.medium, .high].randomElement()!
                } else if (2...6).contains(bucket) {
                    level = [.none, .low, .medium].randomElement()!
                } else {
                    level = [.none, .low].randomElement()!
                }
                cells.append(AnalyticsHeatmapCell(day: day, hourBucket: bucket, activityLevel: level))
            }
        }
        return cells
    }()

    TimeOfDayHeatmapView(cells: sampleCells, mostActive: "9am - 12pm")
        .padding()
        .frame(width: 350)
}

#Preview("Time of Day Heatmap - Empty") {
    TimeOfDayHeatmapView(cells: [], mostActive: nil)
        .padding()
        .frame(width: 350)
}
