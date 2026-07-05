import XCTest
@testable import AgentSessions

final class TranscriptWindowTests: XCTestCase {

    func testLastWindowFewerBlocksThanTargetCoversAll() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 10, blockTarget: 400)
        XCTAssertEqual(w.lowerBlock, 0)
        XCTAssertEqual(w.upperBlock, 9)
        XCTAssertEqual(w.blockCount, 10)
        XCTAssertTrue(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 10))
        XCTAssertFalse(w.isEmpty)
    }

    func testLastWindowMoreBlocksThanTargetTakesTail() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(w.lowerBlock, 600)
        XCTAssertEqual(w.upperBlock, 999)
        XCTAssertEqual(w.blockCount, 400)
        XCTAssertFalse(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 1000))
    }

    func testLastWindowZeroBlocksIsEmpty() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 0, blockTarget: 400)
        XCTAssertTrue(w.isEmpty)
        XCTAssertEqual(w.blockCount, 0)
        XCTAssertTrue(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 0))
    }

    func testExpandedOlderExtendsLowerClampedAtZero() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 1000, blockTarget: 400) // 600...999
        let older = w.expandedOlder(blockTarget: 400)
        XCTAssertEqual(older.lowerBlock, 200)
        XCTAssertEqual(older.upperBlock, 999)
        let older2 = older.expandedOlder(blockTarget: 400)
        XCTAssertEqual(older2.lowerBlock, 0) // clamped, not -200
        XCTAssertTrue(older2.coversTop)
    }

    func testExpandedNewerExtendsUpperClampedAtTotal() {
        let w = TranscriptWindow(lowerBlock: 0, upperBlock: 399)
        let newer = w.expandedNewer(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(newer.lowerBlock, 0)
        XCTAssertEqual(newer.upperBlock, 799)
        let newerToEnd = newer.expandedNewer(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(newerToEnd.upperBlock, 999) // clamped at totalBlocks-1
        XCTAssertTrue(newerToEnd.coversBottom(totalBlocks: 1000))
    }

    // MARK: widenedLowerBound — shared widen-for-jump formula (was duplicated
    // inline in TranscriptBlockListView.widen(toIncludeBlock:) and
    // SessionTerminalView.widenWindowForJump; both now call this).

    func testWidenedLowerBoundSubtractsBlockTargetFromTarget() {
        // Plain case: target well below upper, target - blockTarget stays positive.
        XCTAssertEqual(TranscriptWindow.widenedLowerBound(target: 500, upperBound: 999, blockTarget: 400), 100)
    }

    func testWidenedLowerBoundClampsAtZero() {
        // target - blockTarget would go negative ⇒ clamp to 0.
        XCTAssertEqual(TranscriptWindow.widenedLowerBound(target: 100, upperBound: 999, blockTarget: 400), 0)
    }

    func testWidenedLowerBoundUsesUpperWhenTargetExceedsIt() {
        // target > upperBound ⇒ min(target, upperBound) pins to upperBound first.
        XCTAssertEqual(TranscriptWindow.widenedLowerBound(target: 2000, upperBound: 999, blockTarget: 400), 599)
    }

    func testWidenedLowerBoundGuaranteesTargetInsideResultingWindow() {
        // The documented invariant: for ANY target below the window, a single
        // call's lower bound is at most blockTarget above target (or 0), so
        // lower...upper always contains target.
        let upper = 999
        let blockTarget = 400
        for target in stride(from: 0, through: upper, by: 137) {
            let lower = TranscriptWindow.widenedLowerBound(target: target, upperBound: upper, blockTarget: blockTarget)
            XCTAssertLessThanOrEqual(lower, target, "target \(target) must be >= lower \(lower)")
            XCTAssertLessThanOrEqual(target, upper, "target \(target) must be <= upper \(upper)")
        }
    }
}
