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

    // MARK: prependDiff — degenerate boundaryNewIndex < 0 (defensive gap)

    func testPrependAnchorAtNewStartFallsBackToReload() {
        // old.count >= 2, so anchorOldIndex = 1 (old[1].id is the anchor). If the
        // anchor is somehow found at new[0] (boundaryNewIndex = anchorNewIndex - 1
        // = -1), there's no boundary row to inspect. This shape isn't reachable via
        // the current sole caller (the anchor-suffix match above would fail first
        // in practice), but the function must still degrade safely rather than
        // falling through with a bogus canSplice: true. Construct it directly by
        // making new == old[1...] (old[1] anchors at new[0], and the anchor-suffix
        // match trivially holds).
        let old = [messageRow(5), messageRow(6), messageRow(7)]
        let new = [messageRow(6), messageRow(7), messageRow(8)]
        let diff = BlockTableController.prependDiff(old: old, new: new)
        // Safe shape: not spliceable, no phantom inserts/reload, caller reloads.
        XCTAssertFalse(diff.canSplice)
        XCTAssertEqual(diff.insertedCount, 0)
        XCTAssertFalse(diff.reloadBoundaryRow)
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

    // MARK: shouldInvalidateForWidth — heightCache width-bucket invalidation gate

    func testShouldInvalidateForWidthSameBucketNoInvalidation() {
        // Sub-pixel churn that rounds to the same 1pt bucket must NOT invalidate
        // (heightCache entries keyed by that bucket are still valid).
        XCTAssertFalse(BlockTableController.shouldInvalidateForWidth(oldBucket: 400, newBucket: 400))
    }

    func testShouldInvalidateForWidthDifferentBucketInvalidates() {
        XCTAssertTrue(BlockTableController.shouldInvalidateForWidth(oldBucket: 400, newBucket: 401))
    }

    func testShouldInvalidateForWidthNilOldBucketAlwaysInvalidates() {
        // No prior measurement yet (first layout pass) must always invalidate so
        // the cache gets seeded rather than comparing against a bogus sentinel.
        XCTAssertTrue(BlockTableController.shouldInvalidateForWidth(oldBucket: nil, newBucket: 400))
    }

    // MARK: Role filter (Session-view parity with Terminal's role toggles)

    func testRoleFilterGoverningMapsEveryKind() {
        XCTAssertEqual(TranscriptRoleFilter.governing(.user), .user)
        XCTAssertEqual(TranscriptRoleFilter.governing(.assistant), .assistant)
        XCTAssertEqual(TranscriptRoleFilter.governing(.toolCall), .tools)
        XCTAssertEqual(TranscriptRoleFilter.governing(.toolOut), .tools)
        XCTAssertEqual(TranscriptRoleFilter.governing(.error), .errors)
        // Meta is never filterable — always visible.
        XCTAssertNil(TranscriptRoleFilter.governing(.meta))
    }

    private func mixedBlocks() -> [SessionTranscriptBuilder.LogicalBlock] {
        [block(0, kind: .user),
         block(1, kind: .assistant),
         block(2, kind: .toolCall),
         block(3, kind: .toolOut),
         block(4, kind: .error),
         block(5, kind: .meta)]
    }

    func testRoleFilterAllActiveReturnsEverythingUnfiltered() {
        let blocks = mixedBlocks()
        let out = BlockTableController.applyingRoleFilter(blocks[...],
                                                          activeRoles: Set(TranscriptRoleFilter.allCases))
        XCTAssertEqual(out.map(\.globalBlockIndex), [0, 1, 2, 3, 4, 5])
    }

    func testRoleFilterEmptySetTreatedAsNoFilter() {
        // Empty set means "no filter" (matches Terminal) — unchecking every chip
        // must never blank the transcript.
        let blocks = mixedBlocks()
        let out = BlockTableController.applyingRoleFilter(blocks[...], activeRoles: [])
        XCTAssertEqual(out.map(\.globalBlockIndex), [0, 1, 2, 3, 4, 5])
    }

    func testRoleFilterToolsOnlyKeepsToolAndMetaBlocks() {
        let blocks = mixedBlocks()
        let out = BlockTableController.applyingRoleFilter(blocks[...], activeRoles: [.tools])
        // toolCall(2), toolOut(3) kept; meta(5) always kept; user/assistant/error dropped.
        XCTAssertEqual(out.map(\.globalBlockIndex), [2, 3, 5])
    }

    func testRoleFilterErrorsOnlyKeepsErrorAndMeta() {
        let blocks = mixedBlocks()
        let out = BlockTableController.applyingRoleFilter(blocks[...], activeRoles: [.errors])
        XCTAssertEqual(out.map(\.globalBlockIndex), [4, 5])
    }

    func testRoleFilterPreservesGlobalIndexOnSurvivors() {
        // Filtering drops whole blocks but must NEVER renumber survivors — the
        // row ids the find/anchor maps key on are globalBlockIndex.
        let blocks = mixedBlocks()
        let out = BlockTableController.applyingRoleFilter(blocks[...], activeRoles: [.user, .assistant])
        XCTAssertEqual(out.map(\.globalBlockIndex), [0, 1, 5]) // user, assistant, meta
        XCTAssertEqual(out.map(\.kind), [.user, .assistant, .meta])
    }

    // MARK: Role jump-navigation (▲▼ next/prev occurrence, wrapping)

    func testRoleJumpNextPicksFirstIndexStrictlyAfterTop() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: 5, direction: 1), 9)
    }

    func testRoleJumpPrevPicksLastIndexStrictlyBeforeTop() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: 5, direction: -1), 2)
    }

    func testRoleJumpNextWrapsPastLastToFirst() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: 9, direction: 1), 2)
    }

    func testRoleJumpPrevWrapsBeforeFirstToLast() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: 2, direction: -1), 9)
    }

    func testRoleJumpNoViewportNextIsFirstPrevIsLast() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: nil, direction: 1), 2)
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [2, 5, 9], currentTop: nil, direction: -1), 9)
    }

    func testRoleJumpEmptyIndicesReturnsNil() {
        XCTAssertNil(BlockTableController.roleJumpTarget(indices: [], currentTop: 3, direction: 1))
    }

    func testRoleJumpSingleOccurrenceWrapsToItself() {
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [7], currentTop: 7, direction: 1), 7)
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [7], currentTop: 7, direction: -1), 7)
    }

    func testRoleJumpUnsortedIndicesHandled() {
        // Indices are derived by enumeration so they're ascending in practice,
        // but the helper sorts defensively.
        XCTAssertEqual(BlockTableController.roleJumpTarget(indices: [9, 2, 5], currentTop: 3, direction: 1), 5)
    }
}
