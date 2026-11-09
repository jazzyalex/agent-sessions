import Foundation

/// One turn of the transcript: a typed prompt (or a sub-session's parent task)
/// through the next prompt or an interrupt marker.
struct TranscriptTurn: Equatable, Sendable {
    let startIndex: Int
    /// Exclusive.
    let endIndex: Int
    /// True when an interrupt / turn_aborted marker closed the turn, not the
    /// next turn start or the end of the stream.
    let endsWithInterrupt: Bool
    /// Block indices of the turn's visible agent text, ascending.
    let agentBlockIndices: [Int]

    /// The last agent text of the turn.
    var answerIndex: Int? { agentBlockIndices.last }
    /// Every agent text before the answer.
    var noteIndices: ArraySlice<Int> { agentBlockIndices.dropLast() }
}

struct TranscriptTurnIndex: Equatable, Sendable {
    var turns: [TranscriptTurn]
    /// Union of every turn's `noteIndices`.
    var noteBlockIndices: Set<Int>

    static let empty = TranscriptTurnIndex(turns: [], noteBlockIndices: [])
}

/// Pure turn segmentation over the session's coalesced blocks. Shared by
/// `TranscriptTurnTiming` and the transcript's tool-work grouping.
enum TranscriptTurns {

    /// A visible agent message: assistant kind, card row, plain or guardian verdict.
    static func isAgentText(_ block: SessionTranscriptBuilder.LogicalBlock, source: SessionSource) -> Bool {
        guard block.kind == .assistant, let presentation = block.resolvedPresentation(source: source),
              presentation.rowStyle == .card else { return false }
        switch presentation.origin {
        case nil, .approvalVerdict: return true
        default: return false
        }
    }

    /// Turn badges by row id: each turn with timing sits on the row of its first agent block whose
    /// row is visible. A turn with no visible agent row gets no badge.
    /// - Parameters:
    ///   - timing: `TranscriptTurnTiming.compute`'s `turns`, keyed by the turn's first agent block.
    ///   - rowIDByBlock: the row id that shows a block (`TranscriptMessageGroupIndex.groupIDByBlock`).
    static func chipAnchors(timing: [Int: TurnTiming], turnIndex: TranscriptTurnIndex,
                            rowIDByBlock: [Int: Int], visibleRowIDs: Set<Int>) -> [Int: TurnTiming] {
        var anchors: [Int: TurnTiming] = [:]
        for turn in turnIndex.turns {
            guard let first = turn.agentBlockIndices.first, let turnTiming = timing[first] else { continue }
            for blockIndex in turn.agentBlockIndices {
                let rowID = rowIDByBlock[blockIndex] ?? blockIndex
                if visibleRowIDs.contains(rowID) {
                    anchors[rowID] = turnTiming
                    break
                }
            }
        }
        return anchors
    }

    static func index(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource) -> TranscriptTurnIndex {
        var turns: [TranscriptTurn] = []
        var notes = Set<Int>()

        // Typed prompt through the next typed prompt or interruption.
        var position = 0
        while position < blocks.count {
            guard blocks[position].startsTurn else {
                // Only a typed prompt starts a turn; context and control messages do not.
                position += 1
                continue
            }

            var turnEnd = position + 1
            var endsWithInterrupt = false
            while turnEnd < blocks.count, !blocks[turnEnd].startsTurn {
                let closesTurn = blocks[turnEnd].isInterruptControlMessage
                    || (blocks[turnEnd].kind == .meta && ToolInvocationIndex.isTurnAbortedNotice(blocks[turnEnd].text))
                turnEnd += 1
                if closesTurn {
                    endsWithInterrupt = true
                    break
                }
            }

            var agentIndices: [Int] = []
            for i in position..<turnEnd where isAgentText(blocks[i], source: source) {
                agentIndices.append(i)
            }
            let turn = TranscriptTurn(startIndex: position, endIndex: turnEnd,
                                      endsWithInterrupt: endsWithInterrupt, agentBlockIndices: agentIndices)
            notes.formUnion(turn.noteIndices)
            turns.append(turn)
            position = turnEnd
        }
        return TranscriptTurnIndex(turns: turns, noteBlockIndices: notes)
    }
}
