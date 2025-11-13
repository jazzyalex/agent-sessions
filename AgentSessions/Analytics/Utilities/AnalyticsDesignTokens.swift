import SwiftUI

/// Design constants for Analytics feature
/// Based on analytics-design-guide.md specifications
enum AnalyticsDesign {
    // MARK: - Window
    static let defaultSize = CGSize(width: 1100, height: 900)
    static let minimumSize = CGSize(width: 1100, height: 900)

    // MARK: - Spacing Hierarchy
    /// Edge padding for the entire window content (reduced from 24 → 16 for space savings)
    static let windowPadding: CGFloat = 16

    /// Spacing between stats cards and primary chart - compact, related content (reduced from 20 → 13)
    static let statsToChartSpacing: CGFloat = 13

    /// Spacing between primary chart and secondary insights - major section break (reduced from 32 → 20)
    static let chartToInsightsSpacing: CGFloat = 20

    /// Horizontal spacing between cards in the bottom insights grid (reduced from 20 → 13)
    static let insightsGridSpacing: CGFloat = 13

    /// Internal spacing between individual stats cards in the top grid (reduced from 16 → 10)
    static let metricsCardSpacing: CGFloat = 10

    /// Internal padding for stats cards (reduced from 20 → 14)
    static let statsCardPadding: CGFloat = 14

    /// Internal padding for large cards - charts, breakdowns (reduced from 24 → 16)
    static let cardPadding: CGFloat = 16

    // MARK: - Sizes
    static let headerHeight: CGFloat = 60
    static let statsCardHeight: CGFloat = 100
    static let primaryChartHeight: CGFloat = 260  // Reduced from 280 for better spacing
    /// Height for the bottom insights row ("By Agent" + "Time of Day")
    /// tuned for a 1100×900 Analytics window so that the cards
    /// fit fully with roughly symmetric top/bottom padding.
    ///
    /// This value was eyeballed against the production layout
    /// rather than derived purely from token math, to avoid
    /// truncation on macOS while still giving the bottom cards
    /// more presence than the original 270pt design.
    static let secondaryCardHeight: CGFloat = 360

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
