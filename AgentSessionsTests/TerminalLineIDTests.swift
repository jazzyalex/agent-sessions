import XCTest
@testable import AgentSessions

final class TerminalLineIDTests: XCTestCase {
    func testRoundTripGlobalBlockIndex() {
        for block in [0, 1, 7, 42, 1000, 50_000] {
            for ordinal in [0, 1, 5, 99] {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertEqual(TerminalLineID.globalBlockIndex(from: id), block,
                               "id \(id) should decode back to block \(block)")
            }
        }
    }

    func testIDsAreUniqueAcrossBlocksAndOrdinals() {
        var seen = Set<Int>()
        for block in 0..<200 {
            for ordinal in 0..<50 {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertFalse(seen.contains(id), "duplicate id \(id) for block \(block) ordinal \(ordinal)")
                seen.insert(id)
            }
        }
    }

    func testIDsAreMonotonicInRenderOrder() {
        // Render order: block ascending, ordinal ascending within a block.
        var previous = Int.min
        for block in 0..<100 {
            for ordinal in 0..<10 {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertGreaterThan(id, previous,
                                     "id must increase in render order (block \(block) ordinal \(ordinal))")
                previous = id
            }
        }
    }

    func testSyntheticIDsAreNegativeUniqueAndDoNotDecodeToBlock() {
        var seen = Set<Int>()
        for counter in 0..<100 {
            let id = TerminalLineID.makeSyntheticID(syntheticCounter: counter)
            XCTAssertLessThan(id, 0, "synthetic ids are negative")
            XCTAssertFalse(seen.contains(id), "synthetic id \(id) must be unique")
            seen.insert(id)
            XCTAssertNil(TerminalLineID.globalBlockIndex(from: id),
                         "synthetic id \(id) must not decode to a real block index")
        }
    }

    func testRealIDsAreNonNegative() {
        XCTAssertGreaterThanOrEqual(TerminalLineID.makeID(globalBlockIndex: 0, lineOrdinal: 0), 0)
    }
}
