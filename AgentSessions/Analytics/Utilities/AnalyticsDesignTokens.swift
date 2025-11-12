import SwiftUI

/// Design constants for Analytics feature
/// Based on analytics-design-guide.md specifications
enum AnalyticsDesign {
    // MARK: - Window
    static let defaultSize = CGSize(width: 1100, height: 860)
    static let minimumSize = CGSize(width: 1100, height: 860)

    // MARK: - Spacing Hierarchy
    /// Universal spacing between all cards and window edges
    static let windowPadding: CGFloat = 15

    /// Unified spacing between major sections (stats, chart, insights)
    static let sectionSpacing: CGFloat = 15

    /// Horizontal spacing between cards in the bottom insights grid
    static let insightsGridSpacing: CGFloat = 15

    /// Internal spacing between individual stats cards in the top grid
    static let metricsCardSpacing: CGFloat = 15

    /// Internal padding for stats cards (match charts/insights)
    static let statsCardPadding: CGFloat = 24

    /// Internal padding for large cards (charts, breakdowns)
    static let cardPadding: CGFloat = 24

    // MARK: - Sizes
    static let headerHeight: CGFloat = 60
    static let statsCardHeight: CGFloat = 100
    static let primaryChartHeight: CGFloat = 260  // Reduced from 280 for better spacing
    static let secondaryCardHeight: CGFloat = 270  // Reduced from 300 for better spacing

    // MARK: - Corner Radius
    static let cardCornerRadius: CGFloat = 8
    static let chartBarCornerRadius: CGFloat = 4
    static let heatmapCellCornerRadius: CGFloat = 4

    // MARK: - Animation
    static let defaultDuration: Double = 0.3
    static let chartDuration: Double = 0.6
    static let hoverDuration: Double = 0.2
    static let refreshSpinDuration: Double = 1.0

    // MARK: - Auto-refresh
    static let refreshInterval: TimeInterval = 300 // 5 minutes
}

// MARK: - View Modifiers

extension View {
    /// Apply Analytics card styling: background, border, shadow, corner radius
    func analyticsCard(padding: CGFloat = AnalyticsDesign.cardPadding, colorScheme: ColorScheme) -> some View {
        self
            // Prevent 3D flips / animations from painting outside the card
            .clipShape(RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius))
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius)
                    .fill(Color("CardBackground"))
                    .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AnalyticsDesign.cardCornerRadius)
                    .stroke(colorScheme == .dark ? Color(hex: "#38383a") : Color(hex: "#e5e5e7"), lineWidth: 1)
            )
    }
}

// MARK: - Analytics Colors

extension Color {
    /// Light gray app background for Analytics context (macOS-safe)
    static let analyticsBackground = Color(nsColor: .underPageBackgroundColor)
    /// Card background (macOS-safe fallback when not using assets)
    static let analyticsCardBackground = Color(nsColor: .textBackgroundColor)
    /// Separator/border color (macOS-safe)
    static let analyticsBorder = Color(nsColor: .separatorColor)
    /// Semantic colors for deltas
    static let analyticsPositive = Color.green
    static let analyticsNegative = Color.red
    /// Brand helpers for legend examples
    static let analyticsBlue = Color.blue
    static let analyticsOrange = Color.orange
}
