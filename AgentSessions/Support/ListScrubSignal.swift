import Foundation

/// Main-actor signal: is the user actively scrubbing the session list?
/// UnifiedSessionsView (and any future list backend) stamps every selection
/// change; heavy main-actor transcript applies wait for quiet so they never
/// land mid-scrub. A settled selection passes through with zero delay.
@MainActor
final class ListScrubSignal {
    static let shared = ListScrubSignal()
    /// Injectable clock for tests (same seam as PresenceEngine).
    private let now: () -> Date
    private(set) var lastSelectionChangeAt: Date = .distantPast
    let quietInterval: TimeInterval

    // 0.15 aligns with UnifiedSessionsView's 150ms selection-propagation window:
    // a settled click's apply always lands after quiet (zero added latency),
    // while key-repeat scrubbing (30-90ms between changes) still holds the gate.
    init(quietInterval: TimeInterval = 0.15, now: @escaping () -> Date = Date.init) {
        self.quietInterval = quietInterval
        self.now = now
    }

    func noteSelectionChange() { lastSelectionChangeAt = now() }

    var isScrubbing: Bool {
        now().timeIntervalSince(lastSelectionChangeAt) < quietInterval
    }

    /// Suspends until the list has been quiet for `quietInterval`.
    /// Returns immediately when not scrubbing; cancellation-cooperative
    /// (returns early — callers already guard applies on Task.isCancelled).
    func waitUntilQuiet() async {
        while isScrubbing {
            if Task.isCancelled { return }
            let remaining = quietInterval - now().timeIntervalSince(lastSelectionChangeAt)
            try? await Task.sleep(nanoseconds: UInt64(max(remaining, 0.02) * 1_000_000_000))
        }
    }
}
