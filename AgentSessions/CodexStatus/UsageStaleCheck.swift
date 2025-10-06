import Foundation

// MARK: - Constants

enum UsageStaleThresholds {
    static let fiveHour: TimeInterval = 60 * 60 // 1 hour
    static let weekly: TimeInterval = 8 * 60 * 60 // 8 hours
    static let outdatedCopy = "Outdated. Update manually"
}

// MARK: - Stale Check

func isResetInfoStale(kind: String, lastUpdate: Date?, now: Date = Date()) -> Bool {
    guard let lastUpdate = lastUpdate else { return true }

    let threshold = kind == "5h" ? UsageStaleThresholds.fiveHour : UsageStaleThresholds.weekly
    let elapsed = now.timeIntervalSince(lastUpdate)

    return elapsed > threshold
}
