import Foundation
import Combine

/// Service that calculates analytics metrics from session data
@MainActor
final class AnalyticsService: ObservableObject {
    @Published private(set) var snapshot: AnalyticsSnapshot = .empty
    @Published private(set) var isLoading: Bool = false

    // Parsing progress tracking
    @Published private(set) var isParsingSessions: Bool = false
    @Published private(set) var parsingProgress: Double = 0.0  // 0.0 to 1.0
    @Published private(set) var parsingStatus: String = ""

    private let codexIndexer: SessionIndexer
    private let claudeIndexer: ClaudeSessionIndexer
    private let geminiIndexer: GeminiSessionIndexer

    private var cancellables = Set<AnyCancellable>()
    private var parsingTask: Task<Void, Never>?

    init(codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         geminiIndexer: GeminiSessionIndexer) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer

        // Observe indexer changes for auto-refresh
        setupObservers()
    }

    /// Calculate analytics for given filters
    func calculate(dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) {
        isLoading = true
        defer { isLoading = false }

        // Gather all sessions
        var allSessions: [Session] = []
        allSessions.append(contentsOf: codexIndexer.allSessions)
        allSessions.append(contentsOf: claudeIndexer.allSessions)
        allSessions.append(contentsOf: geminiIndexer.allSessions)

        // Apply filters
        let filtered = filterSessions(allSessions, dateRange: dateRange, agentFilter: agentFilter)

        // Calculate metrics
        let summary = calculateSummary(sessions: filtered, dateRange: dateRange)
        let timeSeries = calculateTimeSeries(sessions: filtered, dateRange: dateRange)
        let agentBreakdown = calculateAgentBreakdown(sessions: filtered)
        let heatmap = calculateHeatmap(sessions: filtered)
        let mostActive = calculateMostActiveTime(sessions: filtered)

        snapshot = AnalyticsSnapshot(
            summary: summary,
            timeSeriesData: timeSeries,
            agentBreakdown: agentBreakdown,
            heatmapCells: heatmap,
            mostActiveTimeRange: mostActive,
            lastUpdated: Date()
        )
    }

    /// Ensure all sessions are fully parsed for accurate analytics
    func ensureSessionsFullyParsed() {
        // Cancel any existing parsing task
        parsingTask?.cancel()

        parsingTask = Task { @MainActor in
            isParsingSessions = true
            parsingProgress = 0.0
            parsingStatus = "Preparing to analyze sessions..."

            defer {
                isParsingSessions = false
                parsingStatus = ""
            }

            // Count total lightweight sessions
            let codexLightweight = codexIndexer.allSessions.filter { $0.events.isEmpty }.count
            let claudeLightweight = claudeIndexer.allSessions.filter { $0.events.isEmpty }.count
            let geminiLightweight = geminiIndexer.allSessions.filter { $0.events.isEmpty }.count
            let totalLightweight = codexLightweight + claudeLightweight + geminiLightweight

            guard totalLightweight > 0 else {
                print("ℹ️ All sessions already fully parsed")
                return
            }

            print("📊 Analytics: Parsing \(totalLightweight) lightweight sessions")
            var completedCount = 0

            // Parse Codex sessions
            if codexLightweight > 0 {
                parsingStatus = "Analyzing \(codexLightweight) Codex sessions..."
                await codexIndexer.parseAllSessionsFull { current, total in
                    completedCount = current
                    self.parsingProgress = Double(completedCount) / Double(totalLightweight)
                    self.parsingStatus = "Analyzing Codex sessions (\(current)/\(total))..."
                }
            }

            // Parse Claude sessions
            if claudeLightweight > 0 {
                let claudeOffset = codexLightweight
                parsingStatus = "Analyzing \(claudeLightweight) Claude sessions..."
                await claudeIndexer.parseAllSessionsFull { current, total in
                    completedCount = claudeOffset + current
                    self.parsingProgress = Double(completedCount) / Double(totalLightweight)
                    self.parsingStatus = "Analyzing Claude sessions (\(current)/\(total))..."
                }
            }

            // Parse Gemini sessions
            if geminiLightweight > 0 {
                let geminiOffset = codexLightweight + claudeLightweight
                parsingStatus = "Analyzing \(geminiLightweight) Gemini sessions..."
                await geminiIndexer.parseAllSessionsFull { current, total in
                    completedCount = geminiOffset + current
                    self.parsingProgress = Double(completedCount) / Double(totalLightweight)
                    self.parsingStatus = "Analyzing Gemini sessions (\(current)/\(total))..."
                }
            }

            parsingProgress = 1.0
            parsingStatus = "Analysis complete!"
            print("✅ Analytics: Parsing complete")

            // Small delay before hiding status
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
    }

    /// Cancel any ongoing parsing
    func cancelParsing() {
        parsingTask?.cancel()
        isParsingSessions = false
        parsingStatus = ""
    }

    // MARK: - Filtering

    private func filterSessions(_ sessions: [Session],
                                dateRange: AnalyticsDateRange,
                                agentFilter: AnalyticsAgentFilter) -> [Session] {
        var filtered = sessions.filter { session in
            // Agent filter
            guard agentFilter.matches(session.source) else { return false }

            // Date range filter
            if let startDate = dateRange.startDate() {
                // Use session start time, or end time, or modified time
                let sessionDate = session.startTime ?? session.endTime ?? session.modifiedAt
                return sessionDate >= startDate
            }

            return true
        }

        // Apply message count filters (same as Sessions List)
        let hideZero = UserDefaults.standard.bool(forKey: "HideZeroMessageSessions")
        let hideLow = UserDefaults.standard.bool(forKey: "HideLowMessageSessions")

        if hideZero {
            filtered = filtered.filter { $0.messageCount > 0 }
        }
        if hideLow {
            filtered = filtered.filter { $0.messageCount > 2 }
        }

        return filtered
    }

    // MARK: - Summary Calculations

    private func calculateSummary(sessions: [Session], dateRange: AnalyticsDateRange) -> AnalyticsSummary {
        let sessionCount = sessions.count

        // Calculate message count (sum of messageCount from each session)
        let messageCount = sessions.reduce(0) { $0 + $1.messageCount }

        // Calculate command/tool count (count tool_call events)
        let commandCount = sessions.reduce(0) { total, session in
            total + session.events.filter { $0.kind == .tool_call }.count
        }

        // Calculate active time (sum of session durations)
        let activeTime = sessions.reduce(0.0) { total, session in
            guard let start = session.startTime, let end = session.endTime else { return total }
            return total + end.timeIntervalSince(start)
        }

        // Calculate changes vs previous period
        let previousSessions = getPreviousPeriodSessions(sessions: sessions, dateRange: dateRange)
        let sessionsChange = calculatePercentageChange(current: sessionCount, previous: previousSessions.count)

        let prevMessageCount = previousSessions.reduce(0) { $0 + $1.messageCount }
        let messagesChange = calculatePercentageChange(current: messageCount, previous: prevMessageCount)

        let prevCommandCount = previousSessions.reduce(0) { total, session in
            total + session.events.filter { $0.kind == .tool_call }.count
        }
        let commandsChange = calculatePercentageChange(current: commandCount, previous: prevCommandCount)

        let prevActiveTime = previousSessions.reduce(0.0) { total, session in
            guard let start = session.startTime, let end = session.endTime else { return total }
            return total + end.timeIntervalSince(start)
        }
        let activeTimeChange = calculatePercentageChange(current: activeTime, previous: prevActiveTime)

        return AnalyticsSummary(
            sessions: sessionCount,
            sessionsChange: sessionsChange,
            messages: messageCount,
            messagesChange: messagesChange,
            commands: commandCount,
            commandsChange: commandsChange,
            activeTimeSeconds: activeTime,
            activeTimeChange: activeTimeChange
        )
    }

    private func getPreviousPeriodSessions(sessions: [Session], dateRange: AnalyticsDateRange) -> [Session] {
        // Get sessions from the previous period of the same length
        guard let startDate = dateRange.startDate() else { return [] }

        let now = Date()
        let periodLength = now.timeIntervalSince(startDate)
        let previousStart = startDate.addingTimeInterval(-periodLength)
        let previousEnd = startDate

        // Get all sessions and filter to previous period
        var allSessions: [Session] = []
        allSessions.append(contentsOf: codexIndexer.allSessions)
        allSessions.append(contentsOf: claudeIndexer.allSessions)
        allSessions.append(contentsOf: geminiIndexer.allSessions)

        return allSessions.filter { session in
            let sessionDate = session.startTime ?? session.endTime ?? session.modifiedAt
            return sessionDate >= previousStart && sessionDate < previousEnd
        }
    }

    private func calculatePercentageChange(current: Int, previous: Int) -> Double? {
        guard previous > 0 else { return nil }
        return Double(current - previous) / Double(previous) * 100.0
    }

    private func calculatePercentageChange(current: TimeInterval, previous: TimeInterval) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous * 100.0
    }

    // MARK: - Time Series

    private func calculateTimeSeries(sessions: [Session], dateRange: AnalyticsDateRange) -> [AnalyticsTimeSeriesPoint] {
        let calendar = Calendar.current
        let granularity = dateRange.aggregationGranularity

        // Group sessions by date bucket and agent
        var buckets: [String: [SessionSource: Int]] = [:]

        for session in sessions {
            let sessionDate = session.startTime ?? session.endTime ?? session.modifiedAt

            // Truncate to granularity
            let bucketDate: Date
            switch granularity {
            case .day:
                bucketDate = calendar.startOfDay(for: sessionDate)
            case .weekOfYear:
                let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: sessionDate))!
                bucketDate = weekStart
            case .month:
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: sessionDate))!
                bucketDate = monthStart
            default:
                bucketDate = calendar.startOfDay(for: sessionDate)
            }

            let key = bucketDate.ISO8601Format()
            if buckets[key] == nil {
                buckets[key] = [:]
            }
            buckets[key]?[session.source, default: 0] += 1
        }

        // Convert to time series points
        var points: [AnalyticsTimeSeriesPoint] = []
        for (dateKey, agentCounts) in buckets {
            guard let date = ISO8601DateFormatter().date(from: dateKey) else { continue }

            for (source, count) in agentCounts {
                points.append(AnalyticsTimeSeriesPoint(
                    date: date,
                    agent: source.displayName,
                    count: count
                ))
            }
        }

        return points.sorted { $0.date < $1.date }
    }

    // MARK: - Agent Breakdown

    private func calculateAgentBreakdown(sessions: [Session]) -> [AnalyticsAgentBreakdown] {
        let totalCount = sessions.count
        guard totalCount > 0 else { return [] }

        // Group by agent
        var byAgent: [SessionSource: (count: Int, duration: TimeInterval)] = [:]

        for session in sessions {
            let source = session.source
            let duration: TimeInterval
            if let start = session.startTime, let end = session.endTime {
                duration = end.timeIntervalSince(start)
            } else {
                duration = 0
            }

            if byAgent[source] == nil {
                byAgent[source] = (count: 0, duration: 0)
            }
            byAgent[source]?.count += 1
            byAgent[source]?.duration += duration
        }

        // Convert to breakdown objects
        var breakdowns: [AnalyticsAgentBreakdown] = []
        for (source, data) in byAgent {
            let percentage = Double(data.count) / Double(totalCount) * 100.0
            breakdowns.append(AnalyticsAgentBreakdown(
                agent: source,
                sessionCount: data.count,
                percentage: percentage,
                durationSeconds: data.duration
            ))
        }

        // Sort by count descending
        return breakdowns.sorted { $0.sessionCount > $1.sessionCount }
    }

    // MARK: - Heatmap

    private func calculateHeatmap(sessions: [Session]) -> [AnalyticsHeatmapCell] {
        let calendar = Calendar.current

        // Count sessions in each (day, hourBucket) cell
        var counts: [String: Int] = [:]

        for session in sessions {
            let sessionDate = session.startTime ?? session.endTime ?? session.modifiedAt

            // Get day of week (0=Monday, 6=Sunday)
            let weekday = calendar.component(.weekday, from: sessionDate)
            let day = (weekday + 5) % 7 // Convert Sunday=1 to Monday=0

            // Get hour bucket (0=12a-3a, 1=3a-6a, ..., 7=9p-12a)
            let hour = calendar.component(.hour, from: sessionDate)
            let hourBucket = hour / 3

            let key = "\(day)-\(hourBucket)"
            counts[key, default: 0] += 1
        }

        // Find max count for normalization
        let maxCount = counts.values.max() ?? 1

        // Generate all cells (7 days × 8 hour buckets)
        var cells: [AnalyticsHeatmapCell] = []
        for day in 0..<7 {
            for bucket in 0..<8 {
                let key = "\(day)-\(bucket)"
                let count = counts[key] ?? 0

                // Normalize to activity level based on max
                let normalized = Double(count) / Double(maxCount)
                let level: ActivityLevel
                if count == 0 {
                    level = .none
                } else if normalized < 0.33 {
                    level = .low
                } else if normalized < 0.67 {
                    level = .medium
                } else {
                    level = .high
                }

                cells.append(AnalyticsHeatmapCell(
                    day: day,
                    hourBucket: bucket,
                    activityLevel: level
                ))
            }
        }

        return cells
    }

    private func calculateMostActiveTime(sessions: [Session]) -> String? {
        guard !sessions.isEmpty else { return nil }

        let calendar = Calendar.current

        // Count by hour bucket
        var hourCounts: [Int: Int] = [:]

        for session in sessions {
            let sessionDate = session.startTime ?? session.endTime ?? session.modifiedAt
            let hour = calendar.component(.hour, from: sessionDate)
            let bucket = hour / 3 // 3-hour buckets
            hourCounts[bucket, default: 0] += 1
        }

        // Find most active bucket
        guard let maxBucket = hourCounts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        // Format as time range
        let startHour = maxBucket * 3
        let endHour = (maxBucket + 1) * 3

        let formatter = DateFormatter()
        formatter.dateFormat = "ha"

        guard let startDate = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: Date()),
              let endDate = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: Date()) else {
            // Fallback: return hour range as string without formatting
            return "\(startHour):00 - \(endHour):00"
        }

        let startStr = formatter.string(from: startDate).lowercased()
        let endStr = formatter.string(from: endDate).lowercased()

        return "\(startStr) - \(endStr)"
    }

    // MARK: - Observers

    private func setupObservers() {
        // Observe when session data changes (for auto-refresh when window visible)
        codexIndexer.$allSessions
            .combineLatest(claudeIndexer.$allSessions, geminiIndexer.$allSessions)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                // Auto-refresh will be triggered by the view when needed
            }
            .store(in: &cancellables)
    }
}
