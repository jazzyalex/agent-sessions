import Foundation

// MARK: - Constants

enum UsageTrackingSource {
    case codex  // Passive file scanning — staleness tied to event timestamps only
    case claude // Active polling — staleness tied to last poll time
}

enum UsageStaleThresholds {
    // Codex thresholds (event-based)
    static let codexFiveHour: TimeInterval = 30 * 60 // 30 minutes
    static let codexWeekly: TimeInterval = 4 * 60 * 60 // 4 hours

    // Claude thresholds (poll-based)
    static let claudeFiveHour: TimeInterval = 90 * 60 // 90 minutes
    static let claudeWeekly: TimeInterval = 6 * 60 * 60 // 6 hours

    static let outdatedCopy = "Stale data. Check manually"
}

// MARK: - Stale Check

func isResetInfoStale(kind: String, source: UsageTrackingSource, lastUpdate: Date?, eventTimestamp: Date? = nil, now: Date = Date()) -> Bool {
    // Determine which timestamp to check based on source
    let timestamp: Date?
    switch source {
    case .codex:
        // IMPORTANT: For Codex, staleness must reflect the age of the
        // underlying rate-limit data captured in logs (eventTimestamp).
        // Do NOT smooth with UI refresh times; a recent refresh without a new
        // event should still appear stale. If no event timestamp, treat as stale.
        timestamp = eventTimestamp
    case .claude:
        // For Claude, use last poll time (when we got fresh data)
        timestamp = lastUpdate
    }

    guard let timestamp = timestamp else { return true }

    // Select threshold based on source and window type
    let threshold: TimeInterval
    switch (source, kind) {
    case (.codex, "5h"):
        threshold = UsageStaleThresholds.codexFiveHour
    case (.codex, _):
        threshold = UsageStaleThresholds.codexWeekly
    case (.claude, "5h"):
        threshold = UsageStaleThresholds.claudeFiveHour
    case (.claude, _):
        threshold = UsageStaleThresholds.claudeWeekly
    }

    let elapsed = now.timeIntervalSince(timestamp)
    return elapsed > threshold
}
