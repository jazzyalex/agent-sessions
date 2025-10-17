import SwiftUI

/// Design constants for Analytics feature
/// Based on analytics-design-guide.md specifications
enum AnalyticsDesign {
    // MARK: - Window
    static let defaultSize = CGSize(width: 1100, height: 860)
    static let minimumSize = CGSize(width: 1100, height: 860)

    // MARK: - Spacing
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let cardPadding: CGFloat = 16

    // MARK: - Sizes
    static let headerHeight: CGFloat = 60
    static let statsCardHeight: CGFloat = 100
    static let primaryChartHeight: CGFloat = 280
    static let secondaryCardHeight: CGFloat = 300
    static let heatmapGridHeight: CGFloat = 210

    // MARK: - Corner Radius
    static let cardCornerRadius: CGFloat = 10
    static let chartBarCornerRadius: CGFloat = 4
    static let heatmapCellCornerRadius: CGFloat = 3

    // MARK: - Animation
    static let defaultDuration: Double = 0.3
    static let chartDuration: Double = 0.6
    static let hoverDuration: Double = 0.2
    static let refreshSpinDuration: Double = 1.0

    // MARK: - Auto-refresh
    static let refreshInterval: TimeInterval = 300 // 5 minutes
}
