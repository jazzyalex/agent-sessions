import XCTest
@testable import AgentSessions

final class TranscriptTurnsTests: XCTestCase {

    private func blocks(_ specs: [TranscriptTestFixtures.TimedBlockSpec]) -> [SessionTranscriptBuilder.LogicalBlock] {
        TranscriptTestFixtures.makeTimedBlocks(specs).map { block in
            var block = block
            if block.kind == .assistant || block.kind == .user { block.text = "text" }
            return block
        }
    }

    func testAnswerIsLastAgentTextEvenWhenToolsFollow() {
        let b = blocks([.user(0), .assistant(1), .toolCall(2), .toolOut(3), .assistant(4), .toolCall(5)])
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns.count, 1)
        XCTAssertEqual(index.turns[0].answerIndex, 4)
        XCTAssertEqual(index.noteBlockIndices, [1])
        XCTAssertEqual(index.turns[0].agentBlockIndices, [1, 4])
        XCTAssertEqual(Array(index.turns[0].noteIndices), [1])
        XCTAssertEqual(index.turns[0].startIndex, 0)
        XCTAssertEqual(index.turns[0].endIndex, 6)
        XCTAssertFalse(index.turns[0].endsWithInterrupt)
    }

    func testTurnWithoutAgentTextHasNoAnswer() {
        let b = blocks([.user(0), .toolCall(1), .toolOut(2)])
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns.count, 1)
        XCTAssertNil(index.turns[0].answerIndex)
        XCTAssertTrue(index.noteBlockIndices.isEmpty)
    }

    func testBlocksBeforeFirstPromptAreNotNotes() {
        let b = blocks([.assistant(0), .assistant(1), .user(2), .assistant(3)])
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertTrue(index.noteBlockIndices.isEmpty)
        XCTAssertEqual(index.turns.count, 1)
        XCTAssertEqual(index.turns[0].startIndex, 2)
        XCTAssertEqual(index.turns[0].answerIndex, 3)
    }

    func testParentTaskStartsATurn() {
        var b = blocks([.user(0), .assistant(1), .assistant(2)])
        b[0].messageOrigin = .parentTask
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns.count, 1)
        XCTAssertEqual(index.turns[0].answerIndex, 2)
        XCTAssertEqual(index.noteBlockIndices, [1])
    }

    func testAgentTextAfterInterruptIsOutsideAnyTurn() {
        var b = blocks([.user(0), .assistant(1), .user(2), .assistant(3), .assistant(4)])
        b[2].text = "[Request interrupted by user]"
        b[2].messageOrigin = .notification(kind: "interrupt")
        let index = TranscriptTurns.index(blocks: b, source: .claude)
        XCTAssertEqual(index.turns.count, 1)
        XCTAssertEqual(index.turns[0].endIndex, 3)
        XCTAssertTrue(index.noteBlockIndices.isEmpty)
        XCTAssertEqual(index.turns[0].answerIndex, 1)
    }

    func testEndsWithInterruptOnlyWhenClosedByMarker() {
        var b = blocks([.user(0), .assistant(1), .user(2), .user(3), .assistant(4)])
        b[2].text = "[Request interrupted by user]"
        b[2].messageOrigin = .notification(kind: "interrupt")
        let index = TranscriptTurns.index(blocks: b, source: .claude)
        XCTAssertEqual(index.turns.count, 2)
        XCTAssertTrue(index.turns[0].endsWithInterrupt)
        XCTAssertFalse(index.turns[1].endsWithInterrupt)

        // A turn_aborted meta notice also closes the turn as an interrupt.
        var c = blocks([.user(0), .assistant(1), .meta(2), .assistant(3)])
        c[2].text = "tag: turn_aborted"
        XCTAssertTrue(ToolInvocationIndex.isTurnAbortedNotice(c[2].text))
        let aborted = TranscriptTurns.index(blocks: c, source: .codex)
        XCTAssertTrue(aborted.turns[0].endsWithInterrupt)
        XCTAssertEqual(aborted.turns[0].endIndex, 3)
        XCTAssertTrue(aborted.noteBlockIndices.isEmpty)
    }

    func testGuardianVerdictEndingTurnIsTheAnswer() {
        // Real guardian sessions classify their user blocks as approvalRequest/context, so they form no turns; this pins the rule only.
        var b = blocks([.user(0), .assistant(1), .assistant(2)])
        b[2].presentation = MessagePresentation(origin: .approvalVerdict(outcome: "allow"), body: "Allowed", summary: nil)
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns[0].answerIndex, 2)
        XCTAssertEqual(index.noteBlockIndices, [1])
    }

    func testSingleAgentMessageIsAnswerNotNote() {
        let b = blocks([.user(0), .assistant(1)])
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns[0].answerIndex, 1)
        XCTAssertTrue(index.noteBlockIndices.isEmpty)
    }

    func testContextAndPlaceholderBlocksAreNotAgentText() {
        var b = blocks([.user(0), .assistant(1), .assistant(2), .assistant(3)])
        b[1].messageOrigin = .context(kinds: ["test"])
        b[2].messageOrigin = .placeholder
        XCTAssertFalse(TranscriptTurns.isAgentText(b[1], source: .codex))
        XCTAssertFalse(TranscriptTurns.isAgentText(b[2], source: .codex))
        let index = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(index.turns[0].agentBlockIndices, [3])
        XCTAssertTrue(index.noteBlockIndices.isEmpty)
    }

    // MARK: - Turn badge anchor

    private func identityRows(_ b: [SessionTranscriptBuilder.LogicalBlock]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: b.indices.map { ($0, $0) })
    }

    func testChipMovesToAnswerWhenFirstAgentMessageIsHidden() {
        let b = blocks([.user(0), .assistant(1), .toolCall(2), .toolOut(3), .assistant(4)])
        let turnIndex = TranscriptTurns.index(blocks: b, source: .codex)
        let timing = TranscriptTurnTiming.compute(blocks: b, source: .codex).turns
        let anchors = TranscriptTurns.chipAnchors(timing: timing, turnIndex: turnIndex,
                                                  rowIDByBlock: identityRows(b), visibleRowIDs: [0, 4])
        XCTAssertEqual(anchors, [4: timing[1]!])
    }

    func testChipStaysWhenNothingHidden() {
        let b = blocks([.user(0), .assistant(1), .toolCall(2), .toolOut(3), .assistant(4)])
        let turnIndex = TranscriptTurns.index(blocks: b, source: .codex)
        let timing = TranscriptTurnTiming.compute(blocks: b, source: .codex).turns
        let anchors = TranscriptTurns.chipAnchors(timing: timing, turnIndex: turnIndex,
                                                  rowIDByBlock: identityRows(b), visibleRowIDs: [0, 1, 4])
        XCTAssertEqual(anchors, [1: timing[1]!])
    }

    func testNoAgentTextTurnHasNoBadge() {
        let b = blocks([.user(0), .toolCall(1), .toolOut(2)])
        let turnIndex = TranscriptTurns.index(blocks: b, source: .codex)
        let timing = TranscriptTurnTiming.compute(blocks: b, source: .codex).turns
        let anchors = TranscriptTurns.chipAnchors(timing: timing, turnIndex: turnIndex,
                                                  rowIDByBlock: identityRows(b), visibleRowIDs: [0, 1, 2])
        XCTAssertTrue(anchors.isEmpty)
    }

    func testMergedNoteAnswerRowKeepsBadge() {
        // 1 (note) and 2 (answer) share one row whose id is 1.
        let b = blocks([.user(0), .assistant(1), .assistant(2)])
        let turnIndex = TranscriptTurns.index(blocks: b, source: .codex)
        XCTAssertEqual(turnIndex.noteBlockIndices, [1])
        let timing = TranscriptTurnTiming.compute(blocks: b, source: .codex).turns
        let anchors = TranscriptTurns.chipAnchors(timing: timing, turnIndex: turnIndex,
                                                  rowIDByBlock: [0: 0, 1: 1, 2: 1], visibleRowIDs: [0, 1])
        XCTAssertEqual(anchors, [1: timing[1]!])
    }

    func testEmptyIndex() {
        XCTAssertTrue(TranscriptTurnIndex.empty.turns.isEmpty)
        XCTAssertTrue(TranscriptTurnIndex.empty.noteBlockIndices.isEmpty)
    }
}
