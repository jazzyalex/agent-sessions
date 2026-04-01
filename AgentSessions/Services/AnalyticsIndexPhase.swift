import Foundation

// MARK: - Analytics Notifications

extension Notification.Name {
    static let toggleAnalyticsWindow = Notification.Name("ToggleAnalyticsWindow")
    static let requestAnalyticsBuild = Notification.Name("RequestAnalyticsBuild")
}

/// Lifecycle phases for the on-demand analytics backfill.
enum AnalyticsIndexPhase: Equatable, Sendable {
    case idle      // no build requested
    case queued    // build requested, waiting to start
    case building  // build in progress
    case ready     // full backfill complete for all enabled analytics sources
    case failed    // build failed

    /// Bump when rollup semantics change to invalidate stale backfill markers.
    static let backfillVersion: Int = 1
}
