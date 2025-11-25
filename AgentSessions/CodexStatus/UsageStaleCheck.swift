import Foundation

// MARK: - Constants
//
// Post Nov 24, 2025: Staleness semantics have changed.
// - "Stale" now means "data is OLD" (timestamp-based), not "data is INACCURATE"
// - Server-side changes ensure usage data is always fresh when sessions exist
// - These thresholds serve UI display purposes (age warnings), not accuracy gates

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

    static let outdatedCopy = "Data is old. Check manually for latest"
}

// MARK: - Stale Check

func isResetInfoStale(kind: String, source: UsageTrackingSource, lastUpdate: Date?, eventTimestamp: Date? = nil, now: Date = Date()) -> Bool {
    // Determine which timestamp to check based on source
    let timestamp: Date?
    switch source {
    case .codex:
        // For Codex, staleness reflects the AGE of the underlying rate-limit
        // data captured in logs (eventTimestamp). Post Nov 24 2025, this is
        // about data age for UI display, not accuracy (server data is always
        // fresh when sessions exist). Do NOT smooth with UI refresh times.
        // If no event timestamp, treat as stale (very old).
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
