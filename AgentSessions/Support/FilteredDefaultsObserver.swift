import Foundation
import Combine

/// Wraps `UserDefaults.didChangeNotification` with a tracked-key value diff:
/// emits ONLY when one of the given keys' values actually changed.
///
/// The raw notification fires on *every* defaults write in the process —
/// including AppKit's own bookkeeping (window frame autosave, splitview
/// autosave, etc.) — not just meaningful preference toggles. Five session
/// indexers each subscribed directly to the raw notification and re-ran a
/// full filter+sort recompute on every fire; sampling showed this storming
/// at ~1/sec during idle even with no user interaction, because AppKit's own
/// bookkeeping writes defaults continuously. Filtering to only the keys a
/// subscriber actually cares about — and only emitting when the value for
/// one of those keys actually changed — removes that churn while preserving
/// the exact same behavior for real preference changes.
///
/// Usage:
/// ```swift
/// let observer = FilteredDefaultsObserver(keys: ["ShowSystemProbeSessions"])
/// observer.mainPublisher
///     .sink { [weak self] in self?.recomputeNow() }
///     .store(in: &cancellables)
/// ```
///
/// Use `mainPublisher` for anything touching UI or `@Published` state; the raw
/// `publisher` delivers on whichever thread wrote the defaults.
///
/// Keep any existing per-site debounce downstream — this utility only
/// decides *whether* to emit, not when/how often.
final class FilteredDefaultsObserver {
    private let keys: [String]
    private let defaults: UserDefaults
    private var lastValues: [String: NSObject]
    private var cancellable: AnyCancellable?
    private let subject = PassthroughSubject<Void, Never>()

    /// Emits `Void` only when one of the tracked keys' values actually changed
    /// since the last emission (including the initial snapshot taken at init).
    ///
    /// Delivered on whichever thread performed the defaults write — the
    /// notification is not main-queue-confined. Sinks that touch `@Published`
    /// state or UI must use `mainPublisher`.
    var publisher: AnyPublisher<Void, Never> { storedPublisher }

    /// `publisher`, hopped to the main queue. Prefer this from SwiftUI
    /// `.onReceive`, which offers no thread guarantee of its own.
    var mainPublisher: AnyPublisher<Void, Never> { storedMainPublisher }

    // Erased once, not per access: SwiftUI compares publisher values to decide
    // whether to resubscribe, so a freshly-boxed `AnyPublisher` on every body
    // evaluation would tear down and rebuild the subscription each time.
    private let storedPublisher: AnyPublisher<Void, Never>
    private let storedMainPublisher: AnyPublisher<Void, Never>

    init(keys: [String], defaults: UserDefaults = .standard) {
        self.keys = keys
        self.defaults = defaults
        self.lastValues = Self.snapshot(keys: keys, defaults: defaults)
        let erased = subject.eraseToAnyPublisher()
        self.storedPublisher = erased
        self.storedMainPublisher = erased.receive(on: DispatchQueue.main).eraseToAnyPublisher()

        cancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in
                self?.handleDidChange()
            }
    }

    private func handleDidChange() {
        let current = Self.snapshot(keys: keys, defaults: defaults)
        guard current != lastValues else { return }
        lastValues = current
        subject.send(())
    }

    /// Snapshots the tracked keys' current values as `NSObject`s so they can
    /// be compared with `isEqual`/`==` regardless of underlying type (Bool,
    /// String, Int, Date, etc. all bridge to comparable NSObject subclasses).
    /// Keys with no stored value are omitted, so "absent -> absent" compares
    /// equal (no spurious emission) while "absent -> present" (or vice versa)
    /// is correctly detected as a change.
    private static func snapshot(keys: [String], defaults: UserDefaults) -> [String: NSObject] {
        var out: [String: NSObject] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) as? NSObject {
                out[key] = value
            }
        }
        return out
    }
}
