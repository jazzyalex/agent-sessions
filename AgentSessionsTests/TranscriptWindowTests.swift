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
}
