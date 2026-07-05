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
/// - Tool duration is computed session-wide (not turn-scoped): each
///   `.toolOut` is matched to the NEAREST PRECEDING UNMATCHED `.toolCall`
///   (stack/LIFO discipline — see the interleaved/nested tests below), and
///   keyed by the toolOut's `globalBlockIndex`. nil if either timestamp is
///   missing or the delta is negative, or if there's no unmatched toolCall
///   to match.
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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

        XCTAssertNil(result.turns[1]?.durationSeconds)
    }

    func testNegativeDeltaYieldsNilToolDuration() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),
            .assistant(1),
            .toolCall(10),
            .toolOut(2), // before its toolCall — clock skew
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

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
        let result = TranscriptTurnTiming.compute(blocks: blocks)

        // out1 (idx 3) matches call1 (idx 2): 1 - 0 = 1.0.
        XCTAssertEqual(result.tools[3], ToolTiming(durationSeconds: 1.0))
        // out2 (idx 5) matches call2 (idx 4): 5 - 2 = 3.0.
        XCTAssertEqual(result.tools[5], ToolTiming(durationSeconds: 3.0))
        XCTAssertEqual(result.turns[1]?.toolCallCount, 2)
    }

    func testNestedToolPairsMatchLIFONearestPrecedingUnmatched() {
        // call1@0, call2@1, out2@3, out1@10 — nested/LIFO: out2 closes the
        // INNER call (call2, the nearer preceding unmatched one), out1 closes
        // the outer call (call1). This is the documented, tested decision:
        // "nearest preceding unmatched" is a stack/LIFO match, not FIFO —
        // out1 must NOT match call1 by simple output-order pairing if that
        // would skip over call2's still-unmatched status.
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(0),        // 0
            .assistant(0),   // 1
            .toolCall(0),    // 2  call1 (outer)
            .toolCall(1),    // 3  call2 (inner)
            .toolOut(3),     // 4  out2
            .toolOut(10),    // 5  out1
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks)

        // out2 (idx 4) matches the NEAREST preceding unmatched toolCall, which
        // is call2 (idx 3): 3 - 1 = 2.0. (NOT call1 — call1 is further away.)
        XCTAssertEqual(result.tools[4], ToolTiming(durationSeconds: 2.0))
        // out1 (idx 5) then matches the next-nearest preceding unmatched
        // toolCall, call1 (idx 2), since call2 was already consumed by out2:
        // 10 - 0 = 10.0.
        XCTAssertEqual(result.tools[5], ToolTiming(durationSeconds: 10.0))
        XCTAssertEqual(result.turns[1]?.toolCallCount, 2)
    }

    // MARK: - No crash on fully-nil timestamps

    func testAllNilTimestampsNeverCrashes() {
        let blocks = TranscriptTestFixtures.makeTimedBlocks([
            .user(nil),
            .assistant(nil),
            .toolCall(nil),
            .toolOut(nil),
        ])
        let result = TranscriptTurnTiming.compute(blocks: blocks)

        XCTAssertNil(result.turns[1]?.durationSeconds)
        XCTAssertNil(result.tools[3]?.durationSeconds)
        XCTAssertEqual(result.turns[1]?.toolCallCount, 1)
    }

    func testEmptyBlocksProducesEmptyMaps() {
        let result = TranscriptTurnTiming.compute(blocks: [])
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
