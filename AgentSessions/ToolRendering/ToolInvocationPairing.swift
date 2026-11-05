import Foundation

/// One tool invocation: a call and the outputs paired with it (spec §6.2).
/// All indices are `globalBlockIndex` values in the full session block stream.
struct ToolInvocationRef: Equatable, Sendable {
    /// The call block's `globalBlockIndex`, or the first output's when there is no call.
    var id: Int
    var callBlockIndex: Int?
    /// Outputs in block order: `.toolOut` blocks and `.error` blocks that carry the call's id.
    var outputBlockIndices: [Int]
    var status: ToolStatus
}

/// Whole-session pairing of tool calls with their outputs, and each invocation's cheap status
/// (spec §6.2 pass 1). Built once per snapshot, off the main actor, in
/// `TranscriptDerivedState.computeSnapshot`. It reads ids, flags and short header lines only.
///
/// Tool blocks: `.toolCall`, `.toolOut`, and `.error` blocks that carry a `toolCallID`
/// (Claude runtime errors). Such an `.error` block is an output of the call its id names; with
/// no such call it stays a plain error and is not indexed.
///
/// Pairing order, in one pass over the blocks:
/// 1. Equal `toolCallID` (session-wide; a repeated call id goes to the latest call).
/// 2. Blocks without ids: FIFO inside the turn. A turn is a `.user` block plus everything up to
///    the next `.user` block; blocks before the first `.user` block form turn 0.
/// 3. Stack fallback: an id-less output with no open id-less call in its own turn takes the
///    nearest preceding unmatched id-less call of an earlier turn.
/// An output that pairs with nothing becomes its own invocation (an orphan, `callBlockIndex` nil).
struct ToolInvocationIndex: Sendable {
    /// In id order.
    var invocations: [ToolInvocationRef]
    /// Every member block (call, outputs, paired `.error` blocks) → its invocation id.
    var invocationIDByBlock: [Int: Int]
    /// "Process running with session ID N" / "Script running with cell ID N" in an output's
    /// header (first `ToolStatusProbe.headerScanLimit` bytes) → that output's invocation id.
    /// Keyed by N as written. A later owner of the same N overwrites an earlier one.
    var processOwnerBySessionID: [String: Int]

    static let empty = ToolInvocationIndex(invocations: [], invocationIDByBlock: [:], processOwnerBySessionID: [:])

    /// - Parameter blocks: the full session stream (`globalBlockIndex` == position), never a window slice.
    static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource) -> ToolInvocationIndex {
        guard !blocks.isEmpty else { return .empty }

        struct Slot {
            var id: Int
            var callPosition: Int?
            var outputPositions: [Int]
            var turn: Int
        }

        var slots: [Slot] = []
        var slotByCallID: [String: Int] = [:]
        // Id-less calls of the current turn, consumed FIFO from `turnHead`.
        var turnCalls: [Int] = []
        var turnHead = 0
        // Unmatched id-less calls of earlier turns, matched as a stack.
        var earlierCalls: [Int] = []
        var turn = 0
        // Turn → position of its last turn_aborted / interrupt notice.
        var noticeByTurn: [Int: Int] = [:]
        var invocationIDByBlock: [Int: Int] = [:]
        invocationIDByBlock.reserveCapacity(blocks.count / 2)
        var processOwners: [String: Int] = [:]

        // Fields are read in place (`blocks[position].x`): copying each block would retain
        // every string it holds.
        for position in blocks.indices {
            let kind = blocks[position].kind
            let globalIndex = blocks[position].globalBlockIndex
            switch kind {
            case .user:
                // An interrupt marker closes the turn it ends.
                if isInterruptNotice(blocks[position].text) { noticeByTurn[turn] = position }
                earlierCalls.append(contentsOf: turnCalls[turnHead...])
                turnCalls.removeAll(keepingCapacity: true)
                turnHead = 0
                turn += 1
            case .meta:
                if isTurnAbortedNotice(blocks[position].text) { noticeByTurn[turn] = position }
            case .toolCall:
                let slot = slots.count
                slots.append(Slot(id: globalIndex, callPosition: position, outputPositions: [], turn: turn))
                invocationIDByBlock[globalIndex] = globalIndex
                if let callID = blocks[position].toolCallID {
                    slotByCallID[callID] = slot
                } else {
                    turnCalls.append(slot)
                }
            case .toolOut, .error:
                let callID = blocks[position].toolCallID
                var target: Int?
                if let callID {
                    target = slotByCallID[callID]
                } else if kind == .toolOut {
                    if turnHead < turnCalls.count {
                        target = turnCalls[turnHead]
                        turnHead += 1
                    } else {
                        target = earlierCalls.popLast()
                    }
                }
                if target == nil {
                    // An `.error` block joins only the call its id names.
                    guard kind == .toolOut else { continue }
                    target = slots.count
                    slots.append(Slot(id: globalIndex, callPosition: nil, outputPositions: [], turn: turn))
                    if let callID { slotByCallID[callID] = target }
                }
                guard let slot = target else { continue }
                slots[slot].outputPositions.append(position)
                let invocationID = slots[slot].id
                invocationIDByBlock[globalIndex] = invocationID
                if let processID = ToolStatusProbe.runningProcessID(in: blocks[position].text) {
                    processOwners[processID] = invocationID
                }
            case .assistant:
                break
            }
        }

        let lastTurn = turn
        var invocations: [ToolInvocationRef] = []
        invocations.reserveCapacity(slots.count)
        for slot in slots {
            let call = slot.callPosition.map { blocks[$0] }
            let outputs = slot.outputPositions.map { blocks[$0] }
            var abortedAfter = false
            if let callPosition = slot.callPosition, let notice = noticeByTurn[slot.turn] {
                abortedAfter = notice > callPosition
            }
            let status = ToolStatusProbe.status(call: call,
                                                outputs: outputs,
                                                source: source,
                                                laterBlocksExist: slot.turn < lastTurn,
                                                turnAbortedAfter: abortedAfter)
            invocations.append(ToolInvocationRef(id: slot.id,
                                                 callBlockIndex: call?.globalBlockIndex,
                                                 outputBlockIndices: outputs.map(\.globalBlockIndex),
                                                 status: status))
        }
        // Slots open in block order, so ids already ascend for a full stream; sort only if not.
        if zip(invocations, invocations.dropFirst()).contains(where: { $0.id > $1.id }) {
            invocations.sort { $0.id < $1.id }
        }

        return ToolInvocationIndex(invocations: invocations,
                                   invocationIDByBlock: invocationIDByBlock,
                                   processOwnerBySessionID: processOwners)
    }

    /// A Codex turn_aborted notice: the `.meta` block `SessionTranscriptBuilder` splits out of a
    /// `<turn_aborted>` user message (header "Turn Aborted / Tag: turn_aborted"); the same marker
    /// `SessionTerminalView` uses for its system-notice blocks.
    private static func isTurnAbortedNotice(_ text: String) -> Bool {
        text.range(of: "tag: turn_aborted", options: [.caseInsensitive]) != nil
    }

    /// A user-interrupt marker such as Claude's "[Request interrupted by user for tool use]"
    /// (`TerminalBuilder.isUserInterruptMarker`). Markers are short, so long user text skips the check.
    private static func isInterruptNotice(_ text: String) -> Bool {
        ToolStatusProbe.cheapLength(text) <= 128 && TerminalBuilder.isUserInterruptMarker(text)
    }
}
