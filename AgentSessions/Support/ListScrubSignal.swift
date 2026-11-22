import Foundation
import AppKit

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

/// Cross-actor signal that keeps maintenance discovery out of an active
/// transcript scroll. Wheel delivery is main-thread synchronous, while the
/// indexer and Presence engine query this from background tasks, so the small
/// deadline is protected by a lock instead of publishing SwiftUI state.
final class TranscriptScrollSignal: @unchecked Sendable {
    static let shared = TranscriptScrollSignal()

    private let lock = NSLock()
    private let now: () -> ContinuousClock.Instant
    private var deferredUntil: ContinuousClock.Instant?
    private let quietDuration: Duration
    let quietInterval: TimeInterval

    init(quietInterval: TimeInterval = 0.4,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.quietInterval = quietInterval
        self.quietDuration = .nanoseconds(Int64(quietInterval * 1_000_000_000))
        self.now = now
    }

    func noteScroll() {
        lock.lock()
        defer { lock.unlock() }
        let nextDeadline = now().advanced(by: quietDuration)
        if let deferredUntil {
            self.deferredUntil = max(deferredUntil, nextDeadline)
        } else {
            deferredUntil = nextDeadline
        }
    }

    var isScrolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deferredUntil else { return false }
        return now() < deferredUntil
    }

    /// Wait for the user-driven scroll quiet period. The monotonic clock keeps
    /// this reliable across wall-clock corrections and sleep/wake changes.
    @discardableResult
    func waitUntilQuiet() async -> Bool {
        var observedScrolling = false
        while isScrolling, !Task.isCancelled {
            observedScrolling = true
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return observedScrolling
    }

    /// Bounds notifications cover wheel and scrollbar scrolling. Keyboard
    /// handlers stamp separately after verifying that the vertical origin
    /// actually moved, so programmatic jumps do not suppress maintenance work.
    func noteScrollIfUserDriven(event: NSEvent?, scrollView: NSScrollView?) {
        guard let event, let scrollView, event.window === scrollView.window else { return }
        switch event.type {
        case .scrollWheel:
            let location = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(location), abs(event.scrollingDeltaY) > 0 else { return }
            noteScroll()
        case .leftMouseDown, .leftMouseDragged:
            if let scroller = scrollView.verticalScroller {
                let location = scroller.convert(event.locationInWindow, from: nil)
                guard scroller.isHighlighted || scroller.bounds.contains(location) else { return }
                noteScroll()
            }
        default:
            break
        }
    }

    /// Keyboard scrolling is stamped only when a vertical-navigation key
    /// synchronously moved this scroll view. This avoids attributing a later
    /// live-tail or Find jump to an unrelated Left/Right/text key event.
    func noteVerticalKeyScrollIfMoved(event: NSEvent,
                                      originBefore: CGFloat?,
                                      originAfter: CGFloat?) {
        let verticalScrollKeyCodes: Set<UInt16> = [49, 115, 116, 119, 121, 125, 126]
        guard verticalScrollKeyCodes.contains(event.keyCode),
              let originBefore, let originAfter,
              abs(originAfter - originBefore) > 0.5 else { return }
        noteScroll()
    }
}
