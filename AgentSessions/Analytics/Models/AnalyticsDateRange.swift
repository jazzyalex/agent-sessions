import Foundation

/// Date range options for analytics filtering
enum AnalyticsDateRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case last90Days = "Last 90 Days"
    case allTime = "All Time"
    case custom = "Custom..."

    var id: String { rawValue }

    /// Calculate the start date for this range
    func startDate(relativeTo now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last30Days:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .last90Days:
            return calendar.date(byAdding: .day, value: -90, to: now)
        case .allTime:
            return nil // No start date filter
        case .custom:
            return nil // To be set by custom picker
        }
    }

    /// Get aggregation granularity for this range (for charts)
    var aggregationGranularity: Calendar.Component {
        switch self {
        case .today:
            return .hour
        case .last7Days, .last30Days:
            return .day
        case .last90Days:
            return .weekOfYear
        case .allTime:
            return .month
        case .custom:
            return .day // Default, can be adjusted
        }
    }
}

/// Agent filter options for analytics
enum AnalyticsAgentFilter: String, CaseIterable, Identifiable {
    case all = "All Agents"
    case codexOnly = "Codex Only"
    case claudeOnly = "Claude Only"
    case geminiOnly = "Gemini Only"

    var id: String { rawValue }

    /// Check if a session source matches this filter
    func matches(_ source: SessionSource) -> Bool {
        switch self {
        case .all:
            return true
        case .codexOnly:
            return source == .codex
        case .claudeOnly:
            return source == .claude
        case .geminiOnly:
            return source == .gemini
        }
    }
}
