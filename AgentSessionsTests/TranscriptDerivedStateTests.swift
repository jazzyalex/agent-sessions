import XCTest
@testable import AgentSessions

final class TranscriptDerivedStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    private func fixtureSession() -> Session {
        TranscriptTestFixtures.makeSyntheticSession(eventCount: 300)
    }

    func testSnapshotParityWithTerminalRebuildResult() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let legacy = SessionTerminalView.buildRebuildResult(
            session: session, skipAgentsPreamble: false, enableReviewCards: true)

        XCTAssertEqual(snap.totalBlockCount, blocks.count)

        // Anchor map moved out of RebuildResult into TranscriptDerivedState.
        // Recompute the expected map from the same primitives buildRebuildResult
        // used (verbatim derivation) so this stays a parity oracle for it.
        // skipAgentsPreamble: false → empty preamble set feeds the anchors.
        let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }
        let anchors = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                    preambleUserBlockIndexes: [],
                                                    blockCount: blocks.count)
        var expectedAnchorMap: [String: Int] = [:]
        for (idx, block) in blocks.enumerated() {
            let targetUserBlockOffset: Int? = block.kind == .user ? idx : anchors[idx]
            guard let targetUserBlockOffset, blocks.indices.contains(targetUserBlockOffset) else { continue }
            expectedAnchorMap[block.eventID] = blocks[targetUserBlockOffset].globalBlockIndex
        }
        XCTAssertEqual(snap.eventIDToAnchorBlockIndex, expectedAnchorMap)
        XCTAssertEqual(snap.preambleUserBlockIndexes, legacy.preambleUserBlockIndexes)
        XCTAssertEqual(snap.userBlockIndices,
                       blocks.indices.filter { blocks[$0].kind == .user }.map { blocks[$0].globalBlockIndex })
        XCTAssertEqual(snap.errorBlockIndices,
                       blocks.indices.filter { blocks[$0].kind == .error }.map { blocks[$0].globalBlockIndex })
        XCTAssertFalse(snap.errorBlockIndices.isEmpty,
                       "error-bearing fixture must actually exercise errorBlockIndices")
    }

    func testSnapshotKeyDedupe() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let k1 = TranscriptDerivedState.Key(session: session, settings: settings)
        let k2 = TranscriptDerivedState.Key(session: session, settings: settings)
        XCTAssertEqual(k1, k2)
        let other = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: true,
                                                           reviewCardsEnabled: true)
        XCTAssertNotEqual(k1, TranscriptDerivedState.Key(session: session, settings: other))
    }

    func testFindMatchesWholeSession() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)
        let needle = String(snap.blocks.first(where: { !$0.text.isEmpty })!.text.prefix(6))
        let matches = TranscriptDerivedState.computeFindMatches(blocks: snap.blocks, query: needle)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.map(\.ordinal), Array(0..<matches.count))
        // matches sorted by block, then location
        XCTAssertEqual(matches, matches.sorted {
            ($0.globalBlockIndex, $0.rangeInBlockText.location) < ($1.globalBlockIndex, $1.rangeInBlockText.location)
        })
    }
}
