import XCTest
import AppKit
@testable import AgentSessions

@MainActor
final class ListScrubSignalTests: XCTestCase {
    func testQuietByDefault() {
        let sig = ListScrubSignal(now: { Date(timeIntervalSince1970: 1000) })
        XCTAssertFalse(sig.isScrubbing)
    }
    func testScrubbingWithinQuietInterval() {
        var t = Date(timeIntervalSince1970: 1000)
        let sig = ListScrubSignal(now: { t })
        sig.noteSelectionChange()
        t = t.addingTimeInterval(0.10)
        XCTAssertTrue(sig.isScrubbing)   // 100ms after change, interval 150ms
        t = t.addingTimeInterval(0.15)
        XCTAssertFalse(sig.isScrubbing)  // 250ms after change
    }
    func testWaitUntilQuietReturnsImmediatelyWhenQuiet() async {
        let sig = ListScrubSignal(now: { Date(timeIntervalSince1970: 1000) })
        let start = ContinuousClock.now
        await sig.waitUntilQuiet()
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(50))
    }
    func testWaitUntilQuietSuspendsUntilQuiet() async {
        let sig = ListScrubSignal() // real clock
        sig.noteSelectionChange()
        let start = ContinuousClock.now
        await sig.waitUntilQuiet()
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(150))
    }

    func testTranscriptScrollSignalExtendsQuietDeadline() {
        var time = ContinuousClock.now
        let signal = TranscriptScrollSignal(quietInterval: 0.4, now: { time })

        XCTAssertFalse(signal.isScrolling)
        signal.noteScroll()
        time = time.advanced(by: .milliseconds(300))
        XCTAssertTrue(signal.isScrolling)

        signal.noteScroll()
        time = time.advanced(by: .milliseconds(300))
        XCTAssertTrue(signal.isScrolling, "A later wheel event must extend the quiet deadline")
        time = time.advanced(by: .milliseconds(110))
        XCTAssertFalse(signal.isScrolling)
    }

    func testTranscriptScrollSignalWaitsForQuiet() async {
        let signal = TranscriptScrollSignal(quietInterval: 0.08)
        signal.noteScroll()
        let start = ContinuousClock.now
        let observedScrolling = await signal.waitUntilQuiet()
        XCTAssertTrue(observedScrolling)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(75))
    }

    func testTranscriptScrollSignalReportsNoDeferralWhenAlreadyQuiet() async {
        let signal = TranscriptScrollSignal(quietInterval: 0.08)
        let observedScrolling = await signal.waitUntilQuiet()
        XCTAssertFalse(observedScrolling)
    }

    func testTranscriptScrollSignalOnlyAttributesMovedVerticalKeys() throws {
        func keyEvent(_ keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        let horizontal = TranscriptScrollSignal(quietInterval: 0.08)
        horizontal.noteVerticalKeyScrollIfMoved(
            event: try keyEvent(123),
            originBefore: 0,
            originAfter: 20
        )
        XCTAssertFalse(horizontal.isScrolling, "Left must not count as vertical scrolling")

        let unmoved = TranscriptScrollSignal(quietInterval: 0.08)
        unmoved.noteVerticalKeyScrollIfMoved(
            event: try keyEvent(125),
            originBefore: 20,
            originAfter: 20
        )
        XCTAssertFalse(unmoved.isScrolling, "Down at the bottom must not count without movement")

        let moved = TranscriptScrollSignal(quietInterval: 0.08)
        moved.noteVerticalKeyScrollIfMoved(
            event: try keyEvent(125),
            originBefore: 0,
            originAfter: 20
        )
        XCTAssertTrue(moved.isScrolling)
    }

    func testProviderRefreshCoordinatorPreservesQueuedTriggerIntent() async {
        let coordinator = UnifiedSessionIndexer.ProviderRefreshCoordinator(coalesceWindowSeconds: 0)
        let first = await coordinator.request(source: .opencode, trigger: .manual)
        guard case .startNow(let lease) = first else { return XCTFail("Expected immediate lease") }
        let queued = await coordinator.request(source: .opencode, trigger: .monitor)
        XCTAssertEqual(queued, .queued)

        let followUp = await coordinator.finish(source: .opencode, lease: lease)
        guard case .followUp(_, let trigger, _) = followUp else { return XCTFail("Expected follow-up") }
        XCTAssertEqual(trigger, .monitor)
    }

    func testProviderRefreshCoordinatorKeepsCleanupAsStrongestPendingIntent() async {
        let coordinator = UnifiedSessionIndexer.ProviderRefreshCoordinator(coalesceWindowSeconds: 0)
        let first = await coordinator.request(source: .codex, trigger: .monitor)
        guard case .startNow(let lease) = first else { return XCTFail("Expected immediate lease") }
        let replacement = await coordinator.request(source: .codex, trigger: .manual)
        guard case .replaceMonitor(let replacementLease) = replacement else {
            return XCTFail("Expected monitor replacement")
        }
        _ = await coordinator.request(source: .codex, trigger: .cleanup)
        _ = await coordinator.request(source: .codex, trigger: .launch)

        let staleFinish = await coordinator.finish(source: .codex, lease: lease)
        XCTAssertEqual(staleFinish, .stale)
        let replacementFinish = await coordinator.finish(source: .codex, lease: replacementLease)
        guard case .followUp(_, let trigger, _) = replacementFinish else {
            return XCTFail("Expected queued cleanup")
        }
        XCTAssertEqual(trigger, .cleanup)
    }

    func testAbandonedMonitorReservationDoesNotAdvanceCoalescingDeadline() async throws {
        let coordinator = UnifiedSessionIndexer.ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await coordinator.request(source: .codex, trigger: .manual, now: t0)
        guard case .startNow(let firstLease) = first else { return XCTFail("Expected immediate lease") }
        let firstLaunch = await coordinator.beginProviderLaunch(source: .codex, lease: firstLease, now: t0)
        XCTAssertEqual(firstLaunch, .manual)
        let firstFinish = await coordinator.finish(source: .codex, lease: firstLease, now: t0)
        XCTAssertEqual(firstFinish, .idle)

        let reserved = await coordinator.request(
            source: .codex,
            trigger: .monitor,
            now: t0.addingTimeInterval(1)
        )
        guard case .scheduleAfter(let delay, let reservedLease) = reserved else {
            return XCTFail("Expected coalesced reservation")
        }
        XCTAssertEqual(delay, 9, accuracy: 0.001)

        // Scrolling abandons the reservation. The production path queues the same
        // monitor before finishing its current sequence.
        let queued = await coordinator.request(source: .codex, trigger: .monitor, now: t0.addingTimeInterval(2))
        XCTAssertEqual(queued, .queued)
        let retry = await coordinator.finish(source: .codex, lease: reservedLease, now: t0.addingTimeInterval(3))
        guard case .followUp(let retryDelay, let retryTrigger, _) = retry else {
            return XCTFail("Expected monitor retry")
        }
        XCTAssertEqual(retryTrigger, .monitor)
        XCTAssertEqual(retryDelay, 7, accuracy: 0.001)
    }

    func testManualRefreshReplacesLaunchedMonitor() async {
        let coordinator = UnifiedSessionIndexer.ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 2_000)
        let first = await coordinator.request(source: .claude, trigger: .monitor, now: t0)
        guard case .startNow(let monitorLease) = first else { return XCTFail("Expected immediate lease") }
        let launch = await coordinator.beginProviderLaunch(source: .claude, lease: monitorLease, now: t0)
        XCTAssertEqual(launch, .monitor)

        let replacement = await coordinator.request(source: .claude, trigger: .manual, now: t0.addingTimeInterval(1))
        guard case .replaceMonitor(let replacementLease) = replacement else {
            return XCTFail("Expected monitor replacement")
        }
        let staleFinish = await coordinator.finish(source: .claude, lease: monitorLease)
        XCTAssertEqual(staleFinish, .stale)
        let active = await coordinator.activeTrigger(source: .claude, lease: replacementLease)
        XCTAssertEqual(active, .manual)
    }

    func testManualRefreshPromotesUnlaunchedMonitorReservation() async {
        let coordinator = UnifiedSessionIndexer.ProviderRefreshCoordinator(coalesceWindowSeconds: 10)
        let t0 = Date(timeIntervalSince1970: 3_000)
        let first = await coordinator.request(source: .opencode, trigger: .manual, now: t0)
        guard case .startNow(let firstLease) = first else { return XCTFail("Expected immediate lease") }
        let launch = await coordinator.beginProviderLaunch(source: .opencode, lease: firstLease, now: t0)
        XCTAssertEqual(launch, .manual)
        let finish = await coordinator.finish(source: .opencode, lease: firstLease, now: t0)
        XCTAssertEqual(finish, .idle)
        let reserved = await coordinator.request(source: .opencode, trigger: .monitor, now: t0.addingTimeInterval(1))
        guard case .scheduleAfter(let delay, let monitorLease) = reserved else {
            return XCTFail("Expected monitor reservation")
        }
        XCTAssertEqual(delay, 9, accuracy: 0.001)
        let promoted = await coordinator.request(source: .opencode, trigger: .manual, now: t0.addingTimeInterval(2))
        guard case .replaceMonitor(let replacementLease) = promoted else {
            return XCTFail("Expected monitor replacement")
        }
        let staleFinish = await coordinator.finish(source: .opencode, lease: monitorLease)
        XCTAssertEqual(staleFinish, .stale)
        let active = await coordinator.activeTrigger(source: .opencode, lease: replacementLease)
        XCTAssertEqual(active, .manual)
    }
}
