import Foundation

/// Per-turn duration ("how long did the assistant take to answer"), attached
/// to the turn's anchor block (see `TranscriptTurnTiming`).
struct TurnTiming: Equatable {
    var durationSeconds: Double?
    var toolCallCount: Int
}

/// Per-tool-call duration ("how long did this tool take"), keyed by the
/// matching `.toolOut` block's `globalBlockIndex`.
struct ToolTiming: Equatable {
    var durationSeconds: Double?
}

/// Pure per-turn and per-tool duration computation from coalesced
/// `LogicalBlock` timestamps (Phase 3 Task 18). No UI, no state — safe to
/// call from a controller's `apply`/derived-state path on every rebuild, same
/// discipline as `TranscriptToolSummary`.
///
/// Definitions (binding, from the Phase 3 plan):
/// - A "turn" is a `.user` block plus everything up to (not including) the
///   next `.user` block. `TurnTiming` is keyed by the turn's ANCHOR — the
///   first `.assistant` block in the turn, or the `.user` block itself if the
///   turn has no assistant block.
/// - `durationSeconds` = timestamp(last block in the turn) − timestamp(the
///   turn's user block); nil if either timestamp is nil, or if the delta is
///   negative (clock skew — never show a bogus negative duration).
/// - `toolCallCount` = number of `.toolCall` blocks in the turn.
/// - Tool duration is computed SESSION-WIDE, independent of turn boundaries:
///   each `.toolOut` is matched to the nearest PRECEDING UNMATCHED `.toolCall`
///   and keyed by the toolOut's `globalBlockIndex`. This is a LIFO/stack match
///   (push on `.toolCall`, pop on `.toolOut`) — see "Nested vs. interleaved"
///   below. nil duration if either timestamp is missing, the delta is
///   negative, or there is no unmatched toolCall to match against.
///
/// Nested vs. interleaved tool pairs: "nearest preceding unmatched" is
/// deliberately a LIFO stack match, not FIFO-by-arrival-order. For
/// `call1, out1, call2, out2` (sequential/interleaved), out1 closes call1 and
/// out2 closes call2 — both a stack and a queue agree here. For
/// `call1, call2, out2, out1` (nested — call2 opens and closes entirely
/// inside call1's span), a stack correctly matches out2 to call2 (the nearer,
/// still-open call) and out1 to call1, mirroring how nested tool
/// calls/subagent spans actually behave. A queue would incorrectly match out1
/// to call1 by arrival position while ignoring nesting, but here it also
/// happens to agree because call1 IS the next FIFO entry — the two
/// disciplines only diverge when an inner call's output arrives before an
/// unrelated, still-open outer call started even earlier and stays open
/// longer, which a plain stack handles correctly. We use a stack throughout.
enum TranscriptTurnTiming {

    static func compute(
        blocks: [SessionTranscriptBuilder.LogicalBlock]
    ) -> (turns: [Int: TurnTiming], tools: [Int: ToolTiming]) {
        var turns: [Int: TurnTiming] = [:]
        var tools: [Int: ToolTiming] = [:]

        // MARK: Tool matching — session-wide, stack-based nearest-preceding-unmatched.
        var openToolCalls: [SessionTranscriptBuilder.LogicalBlock] = []
        for block in blocks {
            switch block.kind {
            case .toolCall:
                openToolCalls.append(block)
            case .toolOut:
                guard let call = openToolCalls.popLast() else {
                    // Orphaned toolOut — no unmatched toolCall precedes it.
                    continue
                }
                tools[block.globalBlockIndex] = ToolTiming(
                    durationSeconds: duration(from: call.timestamp, to: block.timestamp))
            default:
                break
            }
        }

        // MARK: Turn segmentation — user block + everything up to the next user block.
        var index = 0
        while index < blocks.count {
            guard blocks[index].kind == .user else {
                // Blocks before the first `.user` block belong to no turn.
                index += 1
                continue
            }

            let userBlock = blocks[index]
            var turnEnd = index + 1
            while turnEnd < blocks.count, blocks[turnEnd].kind != .user {
                turnEnd += 1
            }
            let turnBlocks = blocks[index..<turnEnd]

            let anchorIndex = turnBlocks.first(where: { $0.kind == .assistant })?.globalBlockIndex
                ?? userBlock.globalBlockIndex
            let toolCallCount = turnBlocks.reduce(into: 0) { count, block in
                if block.kind == .toolCall { count += 1 }
            }
            let lastBlock = turnBlocks.last ?? userBlock
            let durationSeconds = duration(from: userBlock.timestamp, to: lastBlock.timestamp)

            turns[anchorIndex] = TurnTiming(durationSeconds: durationSeconds, toolCallCount: toolCallCount)

            index = turnEnd
        }

        return (turns, tools)
    }

    /// Seconds from `start` to `end`; nil if either is missing or the delta is
    /// negative (clock skew — never surface a bogus negative duration).
    private static func duration(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end else { return nil }
        let delta = end.timeIntervalSince(start)
        return delta >= 0 ? delta : nil
    }
}
