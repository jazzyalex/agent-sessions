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
