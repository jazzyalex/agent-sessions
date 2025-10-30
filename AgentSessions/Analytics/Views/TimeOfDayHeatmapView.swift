import SwiftUI

/// Heatmap showing activity patterns by time of day and day of week
struct TimeOfDayHeatmapView: View {
    let cells: [AnalyticsHeatmapCell]
    let mostActive: String?

    @Environment(\.colorScheme) private var colorScheme

    // Grid dimensions
    private let rows = 7  // Mon-Sun
    private let cols = 8  // 12a-9p buckets

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Time of Day")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
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
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
