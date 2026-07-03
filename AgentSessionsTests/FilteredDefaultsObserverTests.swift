import XCTest
import Combine
@testable import AgentSessions

/// Tests for `FilteredDefaultsObserver`, the key-filtered wrapper around
/// `UserDefaults.didChangeNotification` that emits only when a tracked key's
/// value actually changed. See AgentSessions/Support/FilteredDefaultsObserver.swift
/// for the motivating perf bug (five indexers full-recomputing on every
/// process-wide defaults write, including AppKit's own bookkeeping).
final class FilteredDefaultsObserverTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        suiteName = "FilteredDefaultsObserverTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        cancellables.removeAll()
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        super.tearDown()
    }

    /// Posts didChangeNotification the way AppKit/Foundation actually does:
    /// tied to the specific UserDefaults instance that changed.
    private func postDidChange() {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: suite)
    }

    func testTrackedKeyChangeEmitsOnce() {
        suite.set(false, forKey: "TrackedFlag")
        let observer = FilteredDefaultsObserver(keys: ["TrackedFlag"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        suite.set(true, forKey: "TrackedFlag")
        postDidChange()

        XCTAssertEqual(emitCount, 1)
    }

    func testUntrackedKeyWriteEmitsNothing() {
        suite.set(false, forKey: "TrackedFlag")
        let observer = FilteredDefaultsObserver(keys: ["TrackedFlag"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        // Simulates AppKit bookkeeping writes (window frame autosave, splitview
        // autosave, etc.) that fire didChangeNotification but touch keys the
        // subscriber never reads.
        suite.set("someFrameString", forKey: "NSWindow Frame SomeWindow")
        postDidChange()

        XCTAssertEqual(emitCount, 0)
    }

    func testUnchangedValueRewriteEmitsNothing() {
        suite.set(true, forKey: "TrackedFlag")
        let observer = FilteredDefaultsObserver(keys: ["TrackedFlag"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        // Re-set the SAME value — a real-world no-op write.
        suite.set(true, forKey: "TrackedFlag")
        postDidChange()

        XCTAssertEqual(emitCount, 0)
    }

    func testMultipleTrackedKeysEachTriggerEmission() {
        suite.set(false, forKey: "FlagA")
        suite.set(false, forKey: "FlagB")
        let observer = FilteredDefaultsObserver(keys: ["FlagA", "FlagB"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        suite.set(true, forKey: "FlagA")
        postDidChange()
        XCTAssertEqual(emitCount, 1)

        suite.set(true, forKey: "FlagB")
        postDidChange()
        XCTAssertEqual(emitCount, 2)

        // No further change: re-notify without touching either key.
        postDidChange()
        XCTAssertEqual(emitCount, 2)
    }

    func testAbsentToPresentTransitionEmits() {
        // Key has no stored value at all initially.
        let observer = FilteredDefaultsObserver(keys: ["NewlySetFlag"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        suite.set(true, forKey: "NewlySetFlag")
        postDidChange()

        XCTAssertEqual(emitCount, 1)
    }

    func testNotificationForDifferentDefaultsInstanceIsIgnored() {
        suite.set(false, forKey: "TrackedFlag")
        let observer = FilteredDefaultsObserver(keys: ["TrackedFlag"], defaults: suite)

        var emitCount = 0
        observer.publisher.sink { emitCount += 1 }.store(in: &cancellables)

        // A different UserDefaults instance changes and posts its own
        // didChangeNotification — should not affect an observer scoped to `suite`.
        let otherSuiteName = "FilteredDefaultsObserverTests.other.\(UUID().uuidString)"
        let other = UserDefaults(suiteName: otherSuiteName)!
        other.set(true, forKey: "TrackedFlag")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: other)

        XCTAssertEqual(emitCount, 0)
        other.removePersistentDomain(forName: otherSuiteName)
    }
}

/// Regression coverage for T5: per-provider session indexers must track every
/// UserDefaults key their filter pipeline reads inline, not just a subset.
/// `AntigravitySessionIndexer` previously had NO `FilteredDefaultsObserver` at
/// all despite reading `HideZeroMessageSessions`/`HideLowMessageSessions`
/// inline in both its reactive filter pipeline and `recomputeNow()` — toggling
/// either preference silently did nothing until an unrelated input (query,
/// date range, etc.) changed and happened to re-run the pipeline. These tests
/// exercise the indexer against `UserDefaults.standard` (the concrete store
/// every indexer hardcodes) and assert that toggling the preference alone is
/// enough to re-publish `sessions`.
@MainActor
final class SessionIndexerDefaultsObserverRegressionTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var originalHideZero: Any?
    private var originalHideLow: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        originalHideZero = defaults.object(forKey: "HideZeroMessageSessions")
        originalHideLow = defaults.object(forKey: "HideLowMessageSessions")
    }

    override func tearDown() {
        cancellables.removeAll()
        let defaults = UserDefaults.standard
        if let originalHideZero {
            defaults.set(originalHideZero, forKey: "HideZeroMessageSessions")
        } else {
            defaults.removeObject(forKey: "HideZeroMessageSessions")
        }
        if let originalHideLow {
            defaults.set(originalHideLow, forKey: "HideLowMessageSessions")
        } else {
            defaults.removeObject(forKey: "HideLowMessageSessions")
        }
        originalHideZero = nil
        originalHideLow = nil
        super.tearDown()
    }

    /// Toggling `HideZeroMessageSessions` alone — with no other filter input
    /// changing — must cause the indexer to re-publish `sessions`. Before the
    /// fix, `AntigravitySessionIndexer` had no observer wired to this key at
    /// all, so this emission never happened.
    func testHideZeroMessageSessionsChangeTriggersRecomputeOnAntigravityIndexer() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "HideZeroMessageSessions")
        defaults.set(true, forKey: "HideLowMessageSessions")

        let indexer = AntigravitySessionIndexer()

        // Let init-time pipeline emissions (and any didChangeNotification
        // still in flight from the `set` calls above) settle before we start
        // counting, so the assertion below reflects only the deliberate
        // toggle, not setup noise.
        let settleExpectation = expectation(description: "settle after construction")
        var settled = false
        var emitCountAfterSettle = 0
        let cancellable = indexer.$sessions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if settled { emitCountAfterSettle += 1 }
            }
        cancellable.store(in: &cancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled = true
            settleExpectation.fulfill()
        }
        wait(for: [settleExpectation], timeout: 5)

        let toggleExpectation = expectation(description: "sessions re-published after HideZeroMessageSessions toggle")
        toggleExpectation.assertForOverFulfill = false
        defaults.set(false, forKey: "HideZeroMessageSessions")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            toggleExpectation.fulfill()
        }
        wait(for: [toggleExpectation], timeout: 5)

        XCTAssertGreaterThanOrEqual(emitCountAfterSettle, 1, "toggling HideZeroMessageSessions alone should re-run the filter pipeline")
    }

    /// Same regression, but for `OpenClawSessionIndexer`, whose observer
    /// previously tracked only the root-override/include-deleted keys and
    /// omitted HideZero/HideLow/ShowHousekeeping despite reading them inline.
    func testHideZeroMessageSessionsChangeTriggersRecomputeOnOpenClawIndexer() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "HideZeroMessageSessions")
        defaults.set(true, forKey: "HideLowMessageSessions")

        let indexer = OpenClawSessionIndexer()

        let settleExpectation = expectation(description: "settle after construction")
        var settled = false
        var emitCountAfterSettle = 0
        let cancellable = indexer.$sessions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if settled { emitCountAfterSettle += 1 }
            }
        cancellable.store(in: &cancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            settled = true
            settleExpectation.fulfill()
        }
        wait(for: [settleExpectation], timeout: 5)

        let toggleExpectation = expectation(description: "sessions re-published after HideZeroMessageSessions toggle")
        toggleExpectation.assertForOverFulfill = false
        defaults.set(false, forKey: "HideZeroMessageSessions")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            toggleExpectation.fulfill()
        }
        wait(for: [toggleExpectation], timeout: 5)

        XCTAssertGreaterThanOrEqual(emitCountAfterSettle, 1, "toggling HideZeroMessageSessions alone should re-run the filter pipeline")
    }
}
