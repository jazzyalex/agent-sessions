import Foundation

/// Per-turn duration ("how long did the assistant take to answer"), attached
/// to the turn's anchor block (see `TranscriptTurnTiming`).
struct TurnTiming: Equatable {
    var durationSeconds: Double?
    var toolCallCount: Int
}

/// Per-tool-call duration ("how long did this tool take"), keyed by each
/// output block's `globalBlockIndex` (see `TranscriptTurnTiming`).
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
/// - Tool duration comes from the call ↔ output pairing in
///   `ToolInvocationIndex` (spec §6.2): by call id, then FIFO inside the turn,
///   then a stack fallback for an output with no open call in its own turn.
///   Pairing is session-wide. Each output of an invocation with a call gets
///   `timestamp(output) − timestamp(call)`, keyed by the output's
///   `globalBlockIndex`. nil duration if either timestamp is missing or the
///   delta is negative. An output with no call (orphan) gets no entry.
///   Id-less parallel calls (`call1, call2, out, out`) pair in arrival order:
///   parallel calls are far more common than nested ones, and nested calls
///   from agents that record ids pair by id.
enum TranscriptTurnTiming {

    /// Builds the pairing itself (source `.codex`). Callers that hold a
    /// snapshot's `ToolInvocationIndex` use `compute(blocks:index:)`.
    static func compute(
        blocks: [SessionTranscriptBuilder.LogicalBlock]
    ) -> (turns: [Int: TurnTiming], tools: [Int: ToolTiming]) {
        compute(blocks: blocks, index: ToolInvocationIndex.build(blocks: blocks, source: .codex))
    }

    /// - Parameters:
    ///   - blocks: the full session stream (`globalBlockIndex` == position).
    ///   - index: the pairing built from the same `blocks`.
    static func compute(
        blocks: [SessionTranscriptBuilder.LogicalBlock],
        index: ToolInvocationIndex
    ) -> (turns: [Int: TurnTiming], tools: [Int: ToolTiming]) {
        var turns: [Int: TurnTiming] = [:]
        var tools: [Int: ToolTiming] = [:]

        // MARK: Tool durations — from the session-wide pairing.
        func timestamp(_ globalBlockIndex: Int) -> Date? {
            guard blocks.indices.contains(globalBlockIndex),
                  blocks[globalBlockIndex].globalBlockIndex == globalBlockIndex else { return nil }
            return blocks[globalBlockIndex].timestamp
        }
        for invocation in index.invocations {
            guard let callIndex = invocation.callBlockIndex else { continue }
            let callTimestamp = timestamp(callIndex)
            for outputIndex in invocation.outputBlockIndices {
                tools[outputIndex] = ToolTiming(
                    durationSeconds: duration(from: callTimestamp, to: timestamp(outputIndex)))
            }
        }

        // MARK: Turn segmentation — user block + everything up to the next user block.
        var position = 0
        while position < blocks.count {
            guard blocks[position].kind == .user else {
                // Blocks before the first `.user` block belong to no turn.
                position += 1
                continue
            }

            let userBlock = blocks[position]
            var turnEnd = position + 1
            while turnEnd < blocks.count, blocks[turnEnd].kind != .user {
                turnEnd += 1
            }
            let turnBlocks = blocks[position..<turnEnd]

            let anchorIndex = turnBlocks.first(where: { $0.kind == .assistant })?.globalBlockIndex
                ?? userBlock.globalBlockIndex
            let toolCallCount = turnBlocks.reduce(into: 0) { count, block in
                if block.kind == .toolCall { count += 1 }
            }
            let lastBlock = turnBlocks.last ?? userBlock
            let durationSeconds = duration(from: userBlock.timestamp, to: lastBlock.timestamp)

            turns[anchorIndex] = TurnTiming(durationSeconds: durationSeconds, toolCallCount: toolCallCount)

            position = turnEnd
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

    // MARK: - Static badge formatting (Phase 3 Task 19)

    /// Pure duration formatter, shared by the turn chip and the per-tool
    /// duration suffix. Bucket is chosen from the RAW (unrounded) value:
    /// < 10s → one decimal (`"4.8s"`); 10–59.999...s → whole seconds
    /// (`"42s"`); >= 60s → minutes + whole seconds (`"1m 12s"`). All
    /// rounding is `String(format:)`'s standard round-half-to-even-on-the-
    /// underlying-double behavior — e.g. `9.95` (not exactly representable)
    /// renders `"9.9s"`, not `"10.0s"` (pinned by
    /// `TranscriptTurnTimingTests.testFormatDurationRoundingBoundary`).
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds >= 60 else {
            if seconds < 10 {
                return String(format: "%.1fs", seconds)
            }
            return "\(Int(seconds.rounded()))s"
        }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainderSeconds = totalSeconds % 60
        return "\(minutes)m \(remainderSeconds)s"
    }

    /// Assembled turn-chip text: `"4.8s · 1 call"` / `"4.8s"` (0 calls) /
    /// `""` (nil duration — the caller renders nothing, never an empty chip).
    /// Pure so the assembly rule is unit-testable independent of the view.
    static func turnChipText(durationSeconds: Double?, toolCallCount: Int) -> String {
        guard let durationSeconds else { return "" }
        let formatted = formatDuration(durationSeconds)
        guard toolCallCount > 0 else { return formatted }
        return "\(formatted) · \(toolCallCount) call\(toolCallCount == 1 ? "" : "s")"
    }
}
