import XCTest
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
}
