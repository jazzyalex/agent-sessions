import Foundation

// MARK: - Analytics Notifications

extension Notification.Name {
    static let toggleAnalyticsWindow = Notification.Name("ToggleAnalyticsWindow")
    static let requestAnalyticsBuild = Notification.Name("RequestAnalyticsBuild")
    static let cancelAnalyticsBuild = Notification.Name("CancelAnalyticsBuild")
    static let requestAnalyticsUpdate = Notification.Name("RequestAnalyticsUpdate")
}

/// Lifecycle phases for the on-demand analytics backfill.
enum AnalyticsIndexPhase: Equatable, Sendable {
    case idle      // not built yet
    case queued    // build requested, waiting to start
    case building  // build in progress
    case ready     // full backfill complete for all enabled analytics sources
    case failed    // build failed
    case canceled  // build canceled by user

    /// Bump when rollup semantics change to invalidate stale backfill markers.
    static let backfillVersion: Int = 1
}

struct AnalyticsBuildProgress: Equatable, Sendable {
    let processedSessions: Int
    let totalSessions: Int
    let currentSource: String?
    let completedSources: Int
    let totalSources: Int
    let dateStart: String?
    let dateEnd: String?

    static let empty = AnalyticsBuildProgress(
        processedSessions: 0,
        totalSessions: 0,
        currentSource: nil,
        completedSources: 0,
        totalSources: 0,
        dateStart: nil,
        dateEnd: nil
    )

    var percent: Double {
        guard totalSessions > 0 else { return 0 }
        return min(1.0, max(0, Double(processedSessions) / Double(totalSessions)))
    }
}
