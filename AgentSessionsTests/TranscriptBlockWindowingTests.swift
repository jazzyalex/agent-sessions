import XCTest
@testable import AgentSessions

/// Pure-logic coverage for Task 7's load-older prepend diff and the live-append
/// window-extension math. These functions are the tricky, edge-case-laden
/// primitives behind scroll-driven windowing; the AppKit splicing that consumes
/// them is verified by owner QA, but the boundary reasoning lives here.
final class TranscriptBlockWindowingTests: XCTestCase {

    // MARK: Fixtures

    private func block(_ index: Int,
                       kind: SessionTranscriptBuilder.LogicalBlock.Kind) -> SessionTranscriptBuilder.LogicalBlock {
        var b = SessionTranscriptBuilder.LogicalBlock(
            kind: kind, text: "b\(index)", timestamp: nil, messageID: nil,
            toolName: kind == .toolCall || kind == .toolOut ? "shell" : nil,
            isDelta: false, toolInput: nil, isErrorOutput: false,
            eventID: "e\(index)", rawJSON: "")
        b.globalBlockIndex = index
        return b
    }

    private func messageRow(_ index: Int,
                            kind: SessionTranscriptBuilder.LogicalBlock.Kind = .user) -> BlockRowModel {
        BlockRowModel(id: index, content: .message(block(index, kind: kind)))
    }

    private func groupRow(_ indices: [Int]) -> BlockRowModel {
        let blocks = indices.map { block($0, kind: .toolCall) }
        return BlockRowModel(id: indices.first ?? 0, content: .toolGroup(blocks))
    }

    // MARK: prependDiff — clean prepend (no boundary re-key)

    func testPrependCleanInsertNoBoundaryChange() {
        // Old window: rows for blocks 5,6,7 (all plain messages).
        let old = [messageRow(5), messageRow(6), messageRow(7)]
        // Extend down: blocks 2,3,4 prepended; 5,6,7 unchanged.
        let new = [messageRow(2), messageRow(3), messageRow(4),
                   messageRow(5), messageRow(6), messageRow(7)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        XCTAssertTrue(diff.canSplice)
        XCTAssertEqual(diff.insertedCount, 3)
        XCTAssertFalse(diff.reloadBoundaryRow)
        XCTAssertTrue(diff.droppedRowIDs.isEmpty)
    }

    // MARK: prependDiff — boundary row re-keyed by a tool-run merge across the edge

    func testPrependBoundaryToolMergeDropsOldLoneRow() {
        // Old window top was a LONE tool card at block 5 (run length 1 at the
        // old edge), followed by user 6, user 7.
        let old = [messageRow(5, kind: .toolCall), messageRow(6), messageRow(7)]
        // After extending down, block 4 is ALSO a tool call → blocks 4,5 now
        // merge into a single .toolGroup keyed by 4. The old lone row id 5 is
        // gone; the boundary row is the group at index 1 (after inserted 2,3).
        let new = [messageRow(2), messageRow(3),
                   groupRow([4, 5]),
                   messageRow(6), messageRow(7)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        // A boundary MERGE removes the old lone row (id 5) and replaces it with a
        // group — that's a remove+insert, which a pure top-insert can't express,
        // so the caller must reloadData. The dropped id is still reported so the
        // controller prunes stale expansion state and re-anchors the viewport.
        XCTAssertFalse(diff.canSplice)
        XCTAssertEqual(diff.droppedRowIDs, [5])
    }

    // MARK: prependDiff — single old row (interior anchor unavailable)

    func testPrependSingleOldRowAnchorsOnItself() {
        let old = [messageRow(9)]
        let new = [messageRow(6), messageRow(7), messageRow(8), messageRow(9)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        XCTAssertTrue(diff.canSplice)
        XCTAssertEqual(diff.insertedCount, 3)
        XCTAssertFalse(diff.reloadBoundaryRow)
        XCTAssertTrue(diff.droppedRowIDs.isEmpty)
    }

    // MARK: prependDiff — empty old rows

    func testPrependFromEmptyIsAllInserted() {
        let old: [BlockRowModel] = []
        let new = [messageRow(0), messageRow(1)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        XCTAssertTrue(diff.canSplice)
        XCTAssertEqual(diff.insertedCount, 2)
    }

    // MARK: prependDiff — not a prepend shape ⇒ fall back to reload

    func testPrependRejectsNonPrependShape() {
        // Old tail suffix not present in new (tail row 7 replaced) ⇒ not a clean
        // prepend; caller must reloadData.
        let old = [messageRow(5), messageRow(6), messageRow(7)]
        let new = [messageRow(2), messageRow(5), messageRow(6), messageRow(99)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        XCTAssertFalse(diff.canSplice)
    }

    func testPrependRejectsShrunkRows() {
        let old = [messageRow(5), messageRow(6), messageRow(7)]
        let new = [messageRow(6), messageRow(7)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        XCTAssertFalse(diff.canSplice)
    }

    // MARK: extendedTailRange — live-append window maintenance

    func testExtendedTailRangePreservesWidenedLowerBound() {
        // User scroll-widened to load older content: window is 100...499.
        // A live append grows total to 520 → keep lower 100, extend upper to 519.
        let extended = BlockTableController.extendedTailRange(existing: 100...499, totalBlocks: 520)
        XCTAssertEqual(extended, 100...519)
    }

    func testExtendedTailRangeNilSeedsFromTail() {
        let extended = BlockTableController.extendedTailRange(existing: nil, totalBlocks: 1000)
        // Tail window of 400: last 400 blocks = 600...999.
        XCTAssertEqual(extended, 600...999)
    }

    func testExtendedTailRangeEmptyIsNil() {
        XCTAssertNil(BlockTableController.extendedTailRange(existing: 0...0, totalBlocks: 0))
    }

    func testExtendedTailRangeClampsUpperToLastBlock() {
        // Defensive: an existing upper already at/above the last block stays clamped.
        let extended = BlockTableController.extendedTailRange(existing: 10...50, totalBlocks: 40)
        XCTAssertEqual(extended, 10...39)
    }

    // MARK: firstPromptBlockIndex — Task 8 first-prompt jump resolution

    func testFirstPromptBlockIndexSkipsPreambleEntries() {
        // Blocks 0 and 2 are preamble user turns; block 5 is the first "real" prompt.
        let index = BlockTableController.firstPromptBlockIndex(
            userBlockIndices: [0, 2, 5, 9],
            preambleUserBlockIndexes: [0, 2])
        XCTAssertEqual(index, 5)
    }

    func testFirstPromptBlockIndexFallsBackToFirstWhenAllPreamble() {
        // Mirrors SessionTerminalView's userPromptLineID(.firstUserPrompt) fallback:
        // an all-preamble session still lands on the first user block overall,
        // not nil and not "block 0 of everything".
        let index = BlockTableController.firstPromptBlockIndex(
            userBlockIndices: [1, 3, 4],
            preambleUserBlockIndexes: [1, 3, 4])
        XCTAssertEqual(index, 1)
    }

    func testFirstPromptBlockIndexNilWhenNoUserBlocks() {
        let index = BlockTableController.firstPromptBlockIndex(
            userBlockIndices: [],
            preambleUserBlockIndexes: [])
        XCTAssertNil(index)
    }

    func testFirstPromptBlockIndexNoPreambleReturnsFirstUserBlock() {
        let index = BlockTableController.firstPromptBlockIndex(
            userBlockIndices: [3, 7, 12],
            preambleUserBlockIndexes: [])
        XCTAssertEqual(index, 3)
    }
}
