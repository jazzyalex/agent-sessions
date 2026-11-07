import XCTest
@testable import AgentSessions

/// Phase 3 Task 18: `TranscriptTurnTiming.compute` — pure per-turn and
/// per-tool duration computation from `LogicalBlock` timestamps.
///
/// Semantics under test (binding, from the Phase 3 plan / task-18 brief):
/// - A "turn" is a `.user` block plus everything up to (not including) the
///   next `.user` block. Its `TurnTiming` is keyed by the ANCHOR block's
///   `globalBlockIndex` — the first `.assistant` block in the turn, or the
///   `.user` block itself if the turn has no assistant block.
/// - `durationSeconds` = timestamp(last block in turn) − timestamp(user
///   block); nil if either timestamp is nil or the delta is negative.
/// - `toolCallCount` = number of `.toolCall` blocks in the turn.
/// - Tool duration comes from `ToolInvocationIndex` pairing (Task 6): by
///   call id, then FIFO inside the turn, then the stack fallback for an
///   output with no open call in its own turn. Each output is keyed by its
///   `globalBlockIndex`. nil if either timestamp is missing or the delta is
///   negative, or if the output has no call.
final class TranscriptTurnTimingTests: XCTestCase {

    // MARK: - Basic turn + tool timing

    func testSingleTurnWithOneToolPair() {
        // user@0, assistant@2, toolCall@2, toolOut@4 — turn ends there.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(2),
            .toolCall(2),
            .toolOut(4),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        // Anchor = first .assistant block (index 1).
        XCTAssertEqual(result.turns[1], TurnTiming(durationSeconds: 4.0, toolCallCount: 1))
        // No entry keyed by the user block itself.
        XCTAssertNil(result.turns[0])
        // Tool duration keyed by the toolOut's index (3): 4 - 2 = 2.0.
        XCTAssertEqual(result.tools[3], ToolTiming(durationSeconds: 2.0))
    }

    func testTwoTurnsKeysDoNotBleed() {
        // Turn 1: user@0, assistant@2 (no tools).
        // Turn 2: user@10, assistant@13 (no tools).
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),        // 0
            .assistant(2),   // 1  <- turn 1 anchor
            .user(10),       // 2
            .assistant(13),  // 3  <- turn 2 anchor
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertEqual(result.turns[1], TurnTiming(durationSeconds: 2.0, toolCallCount: 0))
        // Turn 2 duration must use turn 2's OWN user prompt (t=10), not turn 1's
        // (t=0) — i.e. 13 - 10 = 3.0, not 13 - 0 = 13.0.
        XCTAssertEqual(result.turns[3], TurnTiming(durationSeconds: 3.0, toolCallCount: 0))
        XCTAssertNil(result.turns[0])
        XCTAssertNil(result.turns[2])
    }

    // MARK: - Nil / negative-delta handling

    func testNilUserTimestampYieldsNilDurationButStillCountsTools() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(nil),
            .assistant(2),
            .toolCall(2),
            .toolOut(4),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        let timing = result.turns[1]
        XCTAssertNotNil(timing)
        XCTAssertNil(timing?.durationSeconds)
        XCTAssertEqual(timing?.toolCallCount, 1)
    }

    func testNilLastBlockTimestampYieldsNilTurnDuration() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(2),
            .toolCall(2),
            .toolOut(nil),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertNil(result.turns[1]?.durationSeconds)
        XCTAssertEqual(result.turns[1]?.toolCallCount, 1)
        // Tool duration also nil: toolOut has no timestamp.
        XCTAssertNil(result.tools[3]?.durationSeconds)
    }

    func testNegativeDeltaYieldsNilTurnDuration() {
        // Clock skew: last block in the turn timestamped BEFORE the user prompt.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(10),
            .assistant(2), // before the user prompt
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertNil(result.turns[1]?.durationSeconds)
    }

    func testNegativeDeltaYieldsNilToolDuration() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(1),
            .toolCall(10),
            .toolOut(2), // before its toolCall — clock skew
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertNil(result.tools[3]?.durationSeconds)
    }

    // MARK: - Turn with no assistant block

    func testTurnWithNoAssistantBlockAttachesToUserIndex() {
        // user@0, toolCall@1, toolOut@3 — no assistant block at all.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .toolCall(1),
            .toolOut(3),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        // Anchor falls back to the user block (index 0).
        let timing = result.turns[0]
        XCTAssertEqual(timing, TurnTiming(durationSeconds: 3.0, toolCallCount: 1))
        // No entry under any other index.
        XCTAssertNil(result.turns[1])
        XCTAssertNil(result.turns[2])
    }

    // MARK: - Tool matching edge cases

    func testToolOutWithNoPrecedingToolCallHasNilDuration() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(1),
            .toolOut(2), // orphaned — no toolCall precedes it
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertNil(result.tools[2]?.durationSeconds)
        // Still present (not required either way, but must not crash) — accept
        // either "no entry" or "entry with nil duration"; assert the invariant
        // that actually matters: no non-nil duration was fabricated.
    }

    func testToolCallWithNoToolOutProducesNoEntry() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(1),
            .toolCall(2),
            // no matching toolOut
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        // No crash, and no tools entry keyed by the toolCall's own index (2) —
        // tools are keyed by toolOut index, and there is no toolOut here.
        XCTAssertNil(result.tools[2])
        XCTAssertEqual(result.turns[1]?.toolCallCount, 1)
    }

    func testInterleavedToolPairsEachMatchNearestPrecedingUnmatched() {
        // call1@0, out1@1, call2@2, out2@5 — sequential, non-overlapping pairs.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),        // 0
            .assistant(0),   // 1
            .toolCall(0),    // 2  call1
            .toolOut(1),     // 3  out1
            .toolCall(2),    // 4  call2
            .toolOut(5),     // 5  out2
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        // out1 (idx 3) matches call1 (idx 2): 1 - 0 = 1.0.
        XCTAssertEqual(result.tools[3], ToolTiming(durationSeconds: 1.0))
        // out2 (idx 5) matches call2 (idx 4): 5 - 2 = 3.0.
        XCTAssertEqual(result.tools[5], ToolTiming(durationSeconds: 3.0))
        XCTAssertEqual(result.turns[1]?.toolCallCount, 2)
    }

    func testIDlessCallsInOneTurnPairFIFO() {
        // call1@0, call2@1, out@3, out@10 with no call ids — the parallel shape
        // (spec §6.2: parallel calls are far more common than nested ones).
        // Without ids, outputs pair with calls in arrival order inside the turn.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),        // 0
            .assistant(0),   // 1
            .toolCall(0),    // 2  call1
            .toolCall(1),    // 3  call2
            .toolOut(3),     // 4  out1
            .toolOut(10),    // 5  out2
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        // out1 (idx 4) pairs with call1 (idx 2): 3 - 0 = 3.0.
        XCTAssertEqual(result.tools[4], ToolTiming(durationSeconds: 3.0))
        // out2 (idx 5) pairs with call2 (idx 3): 10 - 1 = 9.0.
        XCTAssertEqual(result.tools[5], ToolTiming(durationSeconds: 9.0))
        XCTAssertEqual(result.turns[1]?.toolCallCount, 2)
    }

    func testToolDurationUsesPairing() {
        typealias F = TranscriptTestFixtures
        // c1 c2 o1 o2 with ids: each output pairs with its own call.
        let inOrder = F.sequence([
            F.block(.user, at: 0),                  // 0
            F.block(.assistant, at: 0),             // 1
            F.block(.toolCall, id: "t1", at: 0),    // 2
            F.block(.toolCall, id: "t2", at: 1),    // 3
            F.block(.toolOut, id: "t1", at: 4),     // 4
            F.block(.toolOut, id: "t2", at: 10),    // 5
        ])
        let result = TranscriptTurnTiming.compute(blocks: inOrder, source: .codex)
        XCTAssertEqual(result.tools[4], ToolTiming(durationSeconds: 4.0))
        XCTAssertEqual(result.tools[5], ToolTiming(durationSeconds: 9.0))

        // Ids beat arrival order: o2 lands first. The explicit-index entry point.
        let outOfOrder = F.sequence([
            F.block(.user, at: 0),                  // 0
            F.block(.assistant, at: 0),             // 1
            F.block(.toolCall, id: "t1", at: 0),    // 2
            F.block(.toolCall, id: "t2", at: 1),    // 3
            F.block(.toolOut, id: "t2", at: 4),     // 4  pairs with t2 (idx 3)
            F.block(.toolOut, id: "t1", at: 10),    // 5  pairs with t1 (idx 2)
        ])
        let index = ToolInvocationIndex.build(blocks: outOfOrder, source: .claude)
        let byID = TranscriptTurnTiming.compute(blocks: outOfOrder, index: index)
        XCTAssertEqual(byID.tools[4], ToolTiming(durationSeconds: 3.0))
        XCTAssertEqual(byID.tools[5], ToolTiming(durationSeconds: 10.0))
        XCTAssertEqual(byID.turns[1]?.toolCallCount, 2)
    }

    // MARK: - No crash on fully-nil timestamps

    func testAllNilTimestampsNeverCrashes() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(nil),
            .assistant(nil),
            .toolCall(nil),
            .toolOut(nil),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks, source: .codex)

        XCTAssertNil(result.turns[1]?.durationSeconds)
        XCTAssertNil(result.tools[3]?.durationSeconds)
        XCTAssertEqual(result.turns[1]?.toolCallCount, 1)
    }

    func testEmptyBlocksProducesEmptyMaps() {
        let result = TranscriptTurnTiming.compute(blocks: [], source: .codex)
        XCTAssertTrue(result.turns.isEmpty)
        XCTAssertTrue(result.tools.isEmpty)
    }

    // MARK: - formatDuration (Phase 3 Task 19 static badges)

    func testFormatDurationSubTenSecondsUsesOneDecimal() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(4.8), "4.8s")
    }

    func testFormatDurationZeroIsZeroPointZero() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(0), "0.0s")
    }

    func testFormatDurationTenToFiftyNineIsWholeSeconds() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(42), "42s")
    }

    func testFormatDurationAtSixtyRollsToMinutes() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(60), "1m 0s")
    }

    func testFormatDurationOverSixtyIsMinutesAndSeconds() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(72), "1m 12s")
    }

    /// Pinned rounding boundary (brief explicitly allows either output —
    /// this test IS the pin): 9.95 is not exactly representable as a Double
    /// (its nearest binary value sits fractionally BELOW 9.95), so
    /// `String(format: "%.1f", ...)` — the bucket decision uses the raw
    /// value, which is < 10 either way — renders "9.9s", not "10.0s".
    func testFormatDurationRoundingBoundary() {
        XCTAssertEqual(TranscriptTurnTiming.formatDuration(9.95), "9.9s")
    }

    // MARK: - turnChipText assembly

    func testTurnChipTextWithDurationAndOneCall() {
        XCTAssertEqual(TranscriptTurnTiming.turnChipText(durationSeconds: 4.8, toolCallCount: 1), "4.8s · 1 call")
    }

    func testTurnChipTextWithDurationAndMultipleCalls() {
        XCTAssertEqual(TranscriptTurnTiming.turnChipText(durationSeconds: 4.8, toolCallCount: 3), "4.8s · 3 calls")
    }

    func testTurnChipTextOmitsCallsSuffixWhenZero() {
        XCTAssertEqual(TranscriptTurnTiming.turnChipText(durationSeconds: 4.8, toolCallCount: 0), "4.8s")
    }

    func testTurnChipTextIsEmptyWhenDurationNil() {
        XCTAssertEqual(TranscriptTurnTiming.turnChipText(durationSeconds: nil, toolCallCount: 5), "")
    }
}
