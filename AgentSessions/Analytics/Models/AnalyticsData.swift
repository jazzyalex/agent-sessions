import Foundation

/// Summary statistics for the stats cards
struct AnalyticsSummary: Equatable {
    /// Total number of sessions
    let sessions: Int
    /// Change vs previous period (percentage)
    let sessionsChange: Double?

    /// Total messages across all sessions
    let messages: Int
    /// Change vs previous period
    let messagesChange: Double?

    /// Total tool/command executions
    let commands: Int
    /// Change vs previous period
    let commandsChange: Double?

    /// Total active time (seconds)
    let activeTimeSeconds: TimeInterval
    /// Change vs previous period
    let activeTimeChange: Double?

    /// Formatted active time string with intelligent unit selection
    /// Examples: "42m", "8h 23m", "2d 5h", "3mo 12d", "1y 2mo"
    var activeTimeFormatted: String {
        Self.formatDuration(activeTimeSeconds)
    }

    /// Smart duration formatter with year/month/day/hour/minute support
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)

        let years = totalSeconds / 31_536_000  // 365 days
        let months = (totalSeconds % 31_536_000) / 2_592_000  // 30 days
        let days = (totalSeconds % 2_592_000) / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        // >= 365 days: "1y 2mo" (omit days)
        if years > 0 {
            if months > 0 {
                return "\(years)y \(months)mo"
            }
            return "\(years)y"
        }

        // >= 30 days: "2mo 5d" (omit hours)
        if months > 0 {
            if days > 0 {
                return "\(months)mo \(days)d"
            }
            return "\(months)mo"
        }

        // >= 48 hours: "3d 12h" (omit minutes)
        if days >= 2 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        // >= 24 hours: "1d 5h" (show day + hours)
        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        // >= 1 hour: "8h 23m"
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        // < 1 hour: "42m"
        return "\(minutes)m"
    }

    /// Format a percentage change for display
    static func formatChange(_ change: Double?) -> String? {
        guard let change = change else { return nil }

        let sign = change >= 0 ? "+" : ""
        let arrow = change >= 0 ? "↗" : "↘"
        return "\(sign)\(Int(change))% \(arrow)"
    }

    /// Format integer with locale-appropriate thousands separator
    /// Examples: "1,234" (US), "1.234" (DE), "1 234" (FR)
    static func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

/// A single data point in the time series chart
struct AnalyticsTimeSeriesPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let agent: String // "Codex", "Claude", "Gemini"
    let count: Int
}

/// Agent breakdown data for the progress bar card
struct AnalyticsAgentBreakdown: Identifiable, Equatable {
    let agent: SessionSource
    let sessionCount: Int
    let percentage: Double
    let durationSeconds: TimeInterval

    var id: String { agent.rawValue }

    /// Formatted duration string with intelligent unit selection
    var durationFormatted: String {
        AnalyticsSummary.formatDuration(durationSeconds)
    }

    /// Secondary info string (e.g., "52 sessions • 5h 12m")
    var detailsFormatted: String {
        "\(sessionCount) session\(sessionCount == 1 ? "" : "s") • \(durationFormatted)"
    }
}

/// Activity level for a time-of-day heatmap cell
enum ActivityLevel: Int, Comparable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    static func < (lhs: ActivityLevel, rhs: ActivityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Get activity level from session count
    /// Thresholds can be adjusted based on user patterns
    static func from(count: Int) -> ActivityLevel {
        switch count {
        case 0:
            return .none
        case 1...2:
            return .low
        case 3...5:
            return .medium
        default:
            return .high
        }
    }
}

/// A cell in the time-of-day heatmap
struct AnalyticsHeatmapCell: Identifiable, Equatable {
    let day: Int // 0=Monday, 6=Sunday
    let hourBucket: Int // 0=12a-3a, 1=3a-6a, ..., 7=9p-12a
    let activityLevel: ActivityLevel

    var id: String { "\(day)-\(hourBucket)" }

    /// Day name abbreviation (M, T, W, T, F, S, S)
    var dayLabel: String {
        ["M", "T", "W", "T", "F", "S", "S"][day]
    }

    /// Hour bucket label (12a, 3a, 6a, 9a, 12p, 3p, 6p, 9p)
    static let hourLabels = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]

    var hourLabel: String {
        Self.hourLabels[hourBucket]
    }
}

/// Complete analytics data for a given filter state
struct AnalyticsSnapshot: Equatable {
    let summary: AnalyticsSummary
    let timeSeriesData: [AnalyticsTimeSeriesPoint]
    let agentBreakdown: [AnalyticsAgentBreakdown]
    let heatmapCells: [AnalyticsHeatmapCell]
    let mostActiveTimeRange: String? // e.g., "9am - 11am"
    let lastUpdated: Date

    /// Empty state for initial load
    static let empty = AnalyticsSnapshot(
        summary: AnalyticsSummary(
            sessions: 0, sessionsChange: nil,
            messages: 0, messagesChange: nil,
            commands: 0, commandsChange: nil,
            activeTimeSeconds: 0, activeTimeChange: nil
        ),
        timeSeriesData: [],
        agentBreakdown: [],
        heatmapCells: [],
        mostActiveTimeRange: nil,
        lastUpdated: Date()
    )
}
