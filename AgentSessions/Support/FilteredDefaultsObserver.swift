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
/// observer.publisher
///     .receive(on: DispatchQueue.main)
///     .sink { [weak self] in self?.recomputeNow() }
///     .store(in: &cancellables)
/// ```
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
    var publisher: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    init(keys: [String], defaults: UserDefaults = .standard) {
        self.keys = keys
        self.defaults = defaults
        self.lastValues = Self.snapshot(keys: keys, defaults: defaults)

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
