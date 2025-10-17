import SwiftUI

/// Heatmap showing activity patterns by time of day and day of week
struct TimeOfDayHeatmapView: View {
    let cells: [AnalyticsHeatmapCell]
    let mostActive: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                Text("Time of Day")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if cells.isEmpty {
                    emptyState
                } else {
                    heatmap
                }
            }

            Spacer()

            // Most Active label at bottom
            if !cells.isEmpty, let mostActive = mostActive {
                Text("Most Active: \(mostActive)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: AnalyticsDesign.secondaryCardHeight)
        .padding(AnalyticsDesign.cardPadding)
        .background(Color(nsColor: .quaternarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius))
    }

    private var heatmap: some View {
        GeometryReader { geometry in
            let dayLabelWidth: CGFloat = 24
            let cellSpacing: CGFloat = 3
            let totalSpacing = cellSpacing * 7 // 7 gaps between 8 columns
            let availableWidth = geometry.size.width - dayLabelWidth - totalSpacing
            let cellWidth = availableWidth / 8

            VStack(spacing: cellSpacing) {
                // Hour labels
                HStack(spacing: cellSpacing) {
                    // Empty corner for day labels
                    Text("")
                        .font(.caption2)
                        .frame(width: dayLabelWidth)

                    // Hour labels
                    ForEach(0..<8, id: \.self) { bucket in
                        Text(AnalyticsHeatmapCell.hourLabels[bucket])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: cellWidth)
                    }
                }

                // Grid
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: cellSpacing) {
                        // Day label
                        Text(["M", "T", "W", "T", "F", "S", "S"][day])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: dayLabelWidth)

                        // Hour cells for this day
                        ForEach(0..<8, id: \.self) { bucket in
                            if let cell = cells.first(where: { $0.day == day && $0.hourBucket == bucket }) {
                                HeatmapCell(level: cell.activityLevel)
                                    .frame(width: cellWidth, height: cellWidth)
                            } else {
                                HeatmapCell(level: .none)
                                    .frame(width: cellWidth, height: cellWidth)
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
            return Color(nsColor: .quaternaryLabelColor)
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
