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
        VStack(alignment: .leading, spacing: 12) {
            Text("Time of Day")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            if cells.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let pad = CGFloat(0)  // Inner padding already handled by analyticsCard
                    let hoursLabelHeight: CGFloat = 16  // Caption line above grid
                    let daysLabelWidth: CGFloat = 22    // Caption column left of grid
                    let footerHeight: CGFloat = mostActive == nil ? 0 : 24

                    let availW = geo.size.width - pad*2 - daysLabelWidth
                    let availH = geo.size.height - pad*2 - hoursLabelHeight - footerHeight

                    let cellW = floor(availW / CGFloat(cols))
                    let cellH = floor(availH / CGFloat(rows))
                    let cell = max(10, min(cellW, cellH))  // Clamp to something usable

                    let gridW = cell * CGFloat(cols)
                    let gridH = cell * CGFloat(rows)

                    // Center the matrix vertically within the available height
                    let x0 = pad + daysLabelWidth
                    let y0 = pad + hoursLabelHeight + (availH - gridH) / 2

                    ZStack(alignment: .topLeading) {
                        // Hour captions
                        HStack(spacing: 0) {
                            ForEach(0..<cols, id: \.self) { c in
                                Text(AnalyticsHeatmapCell.hourLabels[c])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: cell, height: hoursLabelHeight, alignment: .center)
                            }
                        }
                        .frame(width: gridW)
                        .offset(x: x0, y: pad)

                        // Day captions
                        VStack(spacing: 0) {
                            ForEach(0..<rows, id: \.self) { r in
                                Text(["M", "T", "W", "T", "F", "S", "S"][r])
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: daysLabelWidth, height: cell, alignment: .trailing)
                            }
                        }
                        .offset(x: pad, y: y0)

                        // Cells - draw all grid positions
                        ForEach(0..<(rows * cols), id: \.self) { index in
                            let row = index / cols
                            let col = index % cols
                            let heatCell = cells.first { $0.day == row && $0.hourBucket == col }
                            let level = heatCell?.activityLevel ?? .none

                            RoundedRectangle(cornerRadius: AnalyticsDesign.heatmapCellCornerRadius)
                                .fill(cellColor(for: level))
                                .frame(width: cell - 3, height: cell - 3)
                                .position(x: x0 + cell * (CGFloat(col) + 0.5),
                                         y: y0 + cell * (CGFloat(row) + 0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .analyticsCard(padding: AnalyticsDesign.cardPadding, colorScheme: colorScheme)
        .overlay(alignment: .bottomLeading) {
            if let mostActive = mostActive {
                Text("Most Active: \(mostActive)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(AnalyticsDesign.cardPadding)
            }
        }
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
