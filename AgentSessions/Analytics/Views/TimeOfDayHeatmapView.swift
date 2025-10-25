import SwiftUI

/// Heatmap showing activity patterns by time of day and day of week
struct TimeOfDayHeatmapView: View {
    let cells: [AnalyticsHeatmapCell]
    let mostActive: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Time of Day")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            if cells.isEmpty {
                emptyState
            } else {
                // Heatmap with day labels on the left
                HStack(alignment: .top, spacing: 8) {
                    // Day labels column
                    dayLabelsColumn

                    // Grid (hour labels + cells)
                    gridWithHourLabels
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Most Active label - centered under the grid only
                if let mostActive = mostActive {
                    HStack(spacing: 8) {
                        Spacer()
                            .frame(width: 20)  // Match day label width

                        Text("Most Active: \(mostActive)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
    }

    private var dayLabelsColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Empty space for hour labels row
            Spacer()
                .frame(height: 14)

            // Day labels
            ForEach(0..<7, id: \.self) { day in
                Text(["M", "T", "W", "T", "F", "S", "S"][day])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 20)
    }

    private var gridWithHourLabels: some View {
        GeometryReader { geometry in
            let cellSpacing: CGFloat = 4

            // Calculate cell dimensions
            let totalHorizontalSpacing = cellSpacing * 7 // 7 gaps between 8 columns
            let cellWidth = (geometry.size.width - totalHorizontalSpacing) / 8

            let headerRowHeight: CGFloat = 14
            let totalVerticalSpacing = cellSpacing * 7 // after header + 6 between rows
            let availableHeight = geometry.size.height - headerRowHeight - totalVerticalSpacing
            let cellHeight = availableHeight / 7

            let cellSize = min(cellWidth, cellHeight)

            VStack(spacing: cellSpacing) {
                // Hour labels
                HStack(spacing: cellSpacing) {
                    ForEach(0..<8, id: \.self) { bucket in
                        Text(AnalyticsHeatmapCell.hourLabels[bucket])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: cellSize, height: headerRowHeight)
                    }
                }

                // Cell grid (7 rows x 8 columns)
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: cellSpacing) {
                        ForEach(0..<8, id: \.self) { bucket in
                            if let cell = cells.first(where: { $0.day == day && $0.hourBucket == bucket }) {
                                HeatmapCell(level: cell.activityLevel)
                                    .frame(width: cellSize, height: cellSize)
                            } else {
                                HeatmapCell(level: .none)
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
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
}

/// Individual heatmap cell
private struct HeatmapCell: View {
    let level: ActivityLevel

    var body: some View {
        RoundedRectangle(cornerRadius: AnalyticsDesign.heatmapCellCornerRadius)
            .fill(cellColor)
            .animation(.easeInOut(duration: 0.3), value: level)
    }

    private var cellColor: Color {
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
