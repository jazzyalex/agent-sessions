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
    private let repository: AnalyticsRepository?

    init(codexIndexer: SessionIndexer,
         claudeIndexer: ClaudeSessionIndexer,
         geminiIndexer: GeminiSessionIndexer) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer
        if let db = try? IndexDB() {
            self.repository = AnalyticsRepository(db: db)
        } else {
            self.repository = nil
        }

        // Observe indexer changes for auto-refresh
        setupObservers()
    }

    /// Calculate analytics for given filters
    func calculate(dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) async {
        isLoading = true
        defer { isLoading = false }

        // Gather all sessions
        var allSessions: [Session] = []
        allSessions.append(contentsOf: codexIndexer.allSessions)
        allSessions.append(contentsOf: claudeIndexer.allSessions)
        allSessions.append(contentsOf: geminiIndexer.allSessions)

        // Apply filters for current period
        let filtered = filterSessions(allSessions, dateRange: dateRange, agentFilter: agentFilter)

        // Calculate metrics (prefer DB-backed where possible)
        let summary = await calculateSummaryFastOrFallback(allSessions: allSessions, dateRange: dateRange, agentFilter: agentFilter)
        let timeSeries = calculateTimeSeries(sessions: filtered, dateRange: dateRange)
        let agentBreakdown = await calculateAgentBreakdownFastOrFallback(dateRange: dateRange, agentFilter: agentFilter, fallbackSessions: filtered)
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
                if !session.events.isEmpty {
                    // Include session if ANY event (or fallback timestamp) is on/after the range start.
                    // This fixes "Today" showing zero when sessions started earlier but had activity today.
                    for ev in session.events {
                        let eDate = ev.timestamp ?? session.endTime ?? session.startTime ?? session.modifiedAt
                        if eDate >= startDate { return true }
                    }
                    return false
                } else {
                    // Lightweight session: fall back to coarse timestamps
                    let coarse = session.endTime ?? session.startTime ?? session.modifiedAt
                    return coarse >= startDate
                }
            }

            return true
        }

        // Apply message count filters (same as Sessions List)
        // Use same defaults as @AppStorage in Sessions List views (both default to true)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true

        if hideZero {
            filtered = filtered.filter { $0.messageCount > 0 }
        }
        if hideLow {
            filtered = filtered.filter { $0.messageCount > 2 }
        }

        return filtered
    }

    // MARK: - Summary Calculations

    private func calculateSummaryFastOrFallback(allSessions: [Session], dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) async -> AnalyticsSummary {
        // Use DB for sessions/messages/duration/avg session length; skip commands for performance
        if let repo = repository, await repo.isReady() {
            let (startDay, endDay) = dayBounds(for: dateRange)
            let sources = sourcesFor(agentFilter)
            let cur = await repo.summary(sources: sources, dayStart: startDay, dayEnd: endDay)
            let curAvgSessionLength = await repo.avgSessionLength(sources: sources, dayStart: startDay, dayEnd: endDay)

            let prevB = previousPeriodBounds(for: dateRange)
            let prevStart = prevB.start.map { dayString($0) }
            let prevEnd = prevB.end.map { dayString($0.addingTimeInterval(-1)) }
            let prev = await repo.summary(sources: sources, dayStart: prevStart, dayEnd: prevEnd)
            let prevAvgSessionLength = await repo.avgSessionLength(sources: sources, dayStart: prevStart, dayEnd: prevEnd)

            let sessionsChange = calculatePercentageChange(current: cur.sessionsDistinct, previous: prev.sessionsDistinct)
            let messagesChange = calculatePercentageChange(current: cur.messages, previous: prev.messages)
            let commandsChange = calculatePercentageChange(current: cur.commands, previous: prev.commands)
            let activeTimeChange = calculatePercentageChange(current: cur.durationSeconds, previous: prev.durationSeconds)
            let avgSessionLengthChange = calculatePercentageChange(current: curAvgSessionLength, previous: prevAvgSessionLength)

            return AnalyticsSummary(
                sessions: cur.sessionsDistinct,
                sessionsChange: sessionsChange,
                messages: cur.messages,
                messagesChange: messagesChange,
                commands: cur.commands,
                commandsChange: commandsChange,
                activeTimeSeconds: cur.durationSeconds,
                activeTimeChange: activeTimeChange,
                avgSessionLengthSeconds: curAvgSessionLength,
                avgSessionLengthChange: avgSessionLengthChange
            )
        }
        return calculateSummaryFallback(allSessions: allSessions, dateRange: dateRange, agentFilter: agentFilter)
    }

    private func calculateSummaryFallback(allSessions: [Session], dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) -> AnalyticsSummary {
        // Skip tool call counting for performance
        let now = Date()
        let currentBounds = dateBounds(for: dateRange, now: now)
        let current = filterSessionsWithinBounds(allSessions, bounds: currentBounds, agentFilter: agentFilter)

        let previousBounds = previousPeriodBounds(for: dateRange, now: now)
        let previous = filterSessionsWithinBounds(allSessions, bounds: previousBounds, agentFilter: agentFilter)

        let sessionCount = current.count
        let messageCount = current.reduce(0) { $0 + $1.messageCount }
        let activeTime = current.reduce(0.0) { total, session in total + clippedDuration(for: session, within: currentBounds) }

        // Calculate average session length (total duration / session count)
        let avgSessionLength = sessionCount > 0 ? activeTime / Double(sessionCount) : 0

        let sessionsChange = calculatePercentageChange(current: sessionCount, previous: previous.count)
        let prevMessageCount = previous.reduce(0) { $0 + $1.messageCount }
        let messagesChange = calculatePercentageChange(current: messageCount, previous: prevMessageCount)
        let prevActiveTime = previous.reduce(0.0) { total, session in total + clippedDuration(for: session, within: previousBounds) }
        let activeTimeChange = calculatePercentageChange(current: activeTime, previous: prevActiveTime)
        let prevAvgSessionLength = previous.count > 0 ? prevActiveTime / Double(previous.count) : 0
        let avgSessionLengthChange = calculatePercentageChange(current: avgSessionLength, previous: prevAvgSessionLength)

        return AnalyticsSummary(
            sessions: sessionCount,
            sessionsChange: sessionsChange,
            messages: messageCount,
            messagesChange: messagesChange,
            commands: 0,
            commandsChange: nil,
            activeTimeSeconds: activeTime,
            activeTimeChange: activeTimeChange,
            avgSessionLengthSeconds: avgSessionLength,
            avgSessionLengthChange: avgSessionLengthChange
        )
    }

    private func getPreviousPeriodSessions(agentFilteredAllSessions: [Session], dateRange: AnalyticsDateRange) -> [Session] {
        // Sessions from the previous period of the same length, event-aware
        guard let startDate = dateRange.startDate() else { return [] }
        let now = Date()
        let periodLength = now.timeIntervalSince(startDate)
        let previousStart = startDate.addingTimeInterval(-periodLength)
        let previousEnd = startDate
        return filterSessionsWithinBounds(agentFilteredAllSessions, bounds: (start: previousStart, end: previousEnd), agentFilter: .all)
    }

    private func calculatePercentageChange(current: Int, previous: Int) -> Double? {
        guard previous > 0 else { return nil }
        return Double(current - previous) / Double(previous) * 100.0
    }

    private func calculatePercentageChange(current: TimeInterval, previous: TimeInterval) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous * 100.0
    }

    // MARK: - Date bounds helpers
    private func dateBounds(for range: AnalyticsDateRange, now: Date = Date()) -> (start: Date?, end: Date?) {
        switch range {
        case .allTime, .custom:
            return (start: range.startDate(relativeTo: now), end: nil)
        default:
            return (start: range.startDate(relativeTo: now), end: now)
        }
    }

    private func previousPeriodBounds(for range: AnalyticsDateRange, now: Date = Date()) -> (start: Date?, end: Date?) {
        guard let start = range.startDate(relativeTo: now) else { return (nil, nil) }
        let length = now.timeIntervalSince(start)
        let prevStart = start.addingTimeInterval(-length)
        let prevEnd = start
        return (start: prevStart, end: prevEnd)
    }

    private func dayBounds(for range: AnalyticsDateRange, now: Date = Date()) -> (String?, String?) {
        let b = dateBounds(for: range, now: now)
        let startDay = b.start.map { dayString($0) }
        // end is exclusive; convert to inclusive day by stepping back 1 second
        let endDay = b.end.map { dayString($0.addingTimeInterval(-1)) }
        return (startDay, endDay)
    }

    private func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func sourcesFor(_ filter: AnalyticsAgentFilter) -> [String] {
        switch filter {
        case .all: return [SessionSource.codex.rawValue, SessionSource.claude.rawValue, SessionSource.gemini.rawValue]
        case .codexOnly: return [SessionSource.codex.rawValue]
        case .claudeOnly: return [SessionSource.claude.rawValue]
        case .geminiOnly: return [SessionSource.gemini.rawValue]
        }
    }

    private func isWithin(_ date: Date, bounds: (start: Date?, end: Date?)) -> Bool {
        if let s = bounds.start, date < s { return false }
        if let e = bounds.end, date >= e { return false } // end exclusive
        return true
    }

    private func filterSessionsWithinBounds(_ sessions: [Session],
                                            bounds: (start: Date?, end: Date?),
                                            agentFilter: AnalyticsAgentFilter) -> [Session] {
        // Apply message count filters (same as Sessions List)
        // Use same defaults as @AppStorage in Sessions List views (both default to true)
        let hideZero = UserDefaults.standard.object(forKey: "HideZeroMessageSessions") as? Bool ?? true
        let hideLow = UserDefaults.standard.object(forKey: "HideLowMessageSessions") as? Bool ?? true

        return sessions.filter { session in
            guard agentFilter.matches(session.source) else { return false }

            // Apply message count filters
            if hideZero && session.messageCount == 0 { return false }
            if hideLow && session.messageCount > 0 && session.messageCount <= 2 { return false }

            // Apply date bounds
            if !session.events.isEmpty {
                for ev in session.events {
                    let d = ev.timestamp ?? session.endTime ?? session.startTime ?? session.modifiedAt
                    if isWithin(d, bounds: bounds) { return true }
                }
                return false
            } else {
                // For lightweight sessions, use modifiedAt (file modification time)
                // This accurately reflects most recent activity (new messages added today)
                let d = session.modifiedAt
                return isWithin(d, bounds: bounds)
            }
        }
    }

    private func clippedDuration(for session: Session, within bounds: (start: Date?, end: Date?)) -> TimeInterval {
        // Establish session start/end from best available data
        var sStart: Date?
        var sEnd: Date?
        if !session.events.isEmpty {
            let times = session.events.compactMap { $0.timestamp }
            if let minT = times.min() { sStart = minT }
            if let maxT = times.max() { sEnd = maxT }
        }
        sStart = sStart ?? session.startTime ?? session.modifiedAt
        sEnd = sEnd ?? session.endTime ?? Date()
        guard let start = sStart, let end = sEnd, end > start else { return 0 }

        let lower = bounds.start ?? .distantPast
        let upper = bounds.end ?? .distantFuture
        let a = max(start, lower)
        let b = min(end, upper)
        if b <= a { return 0 }
        return b.timeIntervalSince(a)
    }

    // MARK: - Time Series

    private func calculateTimeSeries(sessions: [Session], dateRange: AnalyticsDateRange) -> [AnalyticsTimeSeriesPoint] {
        let calendar = Calendar.current
        let granularity = dateRange.aggregationGranularity

        // Group sessions by a single representative date per session (not per-event).
        // Representative date preference:
        // 1) latest event timestamp within bounds, if any
        // 2) else session.endTime, else startTime, else modifiedAt (if within bounds)
        // This avoids inflating counts by the number of events in a session and fixes the 90‑day spike.
        var buckets: [String: [SessionSource: Int]] = [:]
        let bounds = dateBounds(for: dateRange)

        func bucket(_ date: Date) -> Date {
            switch granularity {
            case .day:
                return calendar.startOfDay(for: date)
            case .weekOfYear:
                return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
            case .month:
                return calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            case .hour:
                return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date))!
            default:
                return calendar.startOfDay(for: date)
            }
        }

        for session in sessions {
            var repDate: Date? = nil
            if !session.events.isEmpty {
                // latest event within bounds
                let inRange = session.events.compactMap { $0.timestamp }.filter { isWithin($0, bounds: bounds) }
                repDate = inRange.max()
            }
            if repDate == nil {
                let fallback = session.endTime ?? session.startTime ?? session.modifiedAt
                repDate = isWithin(fallback, bounds: bounds) ? fallback : nil
            }
            guard let date = repDate else { continue }
            let bucketDate = bucket(date)
            let key = bucketDate.ISO8601Format()
            if buckets[key] == nil { buckets[key] = [:] }
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

    /// Count tool_call events for a session within bounds.
    /// Policy: only use the event's own timestamp; if missing, borrow the previous
    /// known timestamp within the same session. Do NOT borrow from future events
    /// (avoids laundering old events into "today").
    private func countToolCalls(in session: Session, within bounds: (start: Date?, end: Date?)) -> Int {
        let events = session.events
        guard !events.isEmpty else { return 0 }

        let n = events.count
        var prevTS = Array<Date?>(repeating: nil, count: n)

        // Left-to-right: previous known timestamp
        var last: Date? = nil
        for i in 0..<n {
            prevTS[i] = last
            if let t = events[i].timestamp { last = t }
        }

        var count = 0
        for i in 0..<n {
            let e = events[i]
            guard e.kind == .tool_call else { continue }
            // Prefer event ts; else previous only (no forward fill)
            let ts = e.timestamp ?? prevTS[i]
            if let ts, isWithin(ts, bounds: bounds) { count += 1 }
        }
        return count
    }

    // MARK: - Agent Breakdown

    private func calculateAgentBreakdown(sessions: [Session], dateRange: AnalyticsDateRange) -> [AnalyticsAgentBreakdown] {
        let totalCount = sessions.count
        guard totalCount > 0 else { return [] }

        // Group by agent
        var byAgent: [SessionSource: (count: Int, duration: TimeInterval)] = [:]

        let bounds = dateBounds(for: dateRange)

        for session in sessions {
            let source = session.source
            let duration: TimeInterval = clippedDuration(for: session, within: bounds)

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

    private func calculateAgentBreakdownFastOrFallback(dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter, fallbackSessions: [Session]) async -> [AnalyticsAgentBreakdown] {
        if let repo = repository, await repo.isReady(), agentFilter == .all {
            let (startDay, endDay) = dayBounds(for: dateRange)
            let slices = await repo.breakdownByAgent(sources: sourcesFor(.all), dayStart: startDay, dayEnd: endDay)
            let total = max(1, slices.reduce(0) { $0 + $1.sessionsDistinct })
            return slices.map { s in
                AnalyticsAgentBreakdown(
                    agent: SessionSource(rawValue: s.source) ?? .codex,
                    sessionCount: s.sessionsDistinct,
                    percentage: (Double(s.sessionsDistinct) / Double(total)) * 100.0,
                    durationSeconds: s.durationSeconds
                )
            }.sorted { $0.sessionCount > $1.sessionCount }
        }
        return calculateAgentBreakdown(sessions: fallbackSessions, dateRange: dateRange)
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
            .sink { _ in
                // Auto-refresh will be triggered by the view when needed
            }
            .store(in: &cancellables)
    }
}
