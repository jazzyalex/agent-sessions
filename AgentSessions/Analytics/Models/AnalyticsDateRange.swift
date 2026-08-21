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
    case antigravityOnly = "Antigravity Only"
    case opencodeOnly = "OpenCode Only"
    case hermesOnly = "Hermes Only"
    case copilotOnly = "Copilot Only"
    case droidOnly = "Droid Only"
    case openclawOnly = "OpenClaw Only"
    case cursorOnly = "Cursor Only"
    case piOnly = "Pi Only"
    case kimiOnly = "Kimi Only"
    case grokOnly = "Grok Only"
    case qwenOnly = "Qwen Only"
    case fxOnly = "fx Only"

    var id: String { rawValue }

    /// The single-agent filter that isolates `source`, derived from `matches` rather
    /// than a second hand-written mapping.
    ///
    /// The Analytics picker builds its options through this, so a source with no
    /// dedicated case cannot silently vanish from the menu: it fails
    /// `testEveryAnalyticsSupportedSourceHasADedicatedAgentFilter` first. The picker
    /// previously kept its own list of `if enabled { append }` lines that stopped at
    /// Kimi, which is how Grok, Cursor and OpenClaw ended up unreachable in the UI
    /// while their enum cases existed and their tests passed.
    static func dedicated(for source: SessionSource) -> AnalyticsAgentFilter? {
        allCases.first { $0 != .all && $0.matches(source) }
    }

    /// Check if a session source matches this filter
    func matches(_ source: SessionSource) -> Bool {
        switch self {
        case .all:
            return true
        case .codexOnly:
            return source == .codex
        case .claudeOnly:
            return source == .claude
        case .antigravityOnly:
            return source == .antigravity
        case .opencodeOnly:
            return source == .opencode
        case .hermesOnly:
            return source == .hermes
        case .copilotOnly:
            return source == .copilot
        case .droidOnly:
            return source == .droid
        case .openclawOnly:
            return source == .openclaw
        case .cursorOnly:
            return source == .cursor
        case .piOnly:
            return source == .pi
        case .kimiOnly:
            return source == .kimi
        case .grokOnly:
            return source == .grok
        case .qwenOnly:
            return source == .qwen
        case .fxOnly:
            return source == .fx
        }
    }
}

/// Project filter options for analytics
enum AnalyticsProjectFilter: Equatable, Hashable {
    case all
    case specific(String) // repo name

    var displayName: String {
        switch self {
        case .all:
            return "All Projects"
        case .specific(let name):
            return name
        }
    }

    /// Check if a session's repo matches this filter
    func matches(_ repoName: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .specific(let name):
            return repoName == name
        }
    }
}
