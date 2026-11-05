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
/// no such call it is an orphan invocation (a runtime error stays a tool output, spec §7.4).
/// An `.error` block without an id is a plain error and is not indexed.
///
/// Pairing order, in one pass over the blocks:
/// 1. Equal `toolCallID`, session-wide, FIFO per id: an output goes to the earliest call with
///    its id that has no output yet; when every such call has one, to the latest of them.
/// 2. An output without an id: the earliest open id-less call of its turn (FIFO). A turn is a
///    `.user` block plus everything up to the next `.user` block; blocks before the first
///    `.user` block form turn 0.
/// 3. Then the earliest call of its turn that has an id but no output yet (agents that drop the
///    id on some results: Antigravity's tool-name fallback, DSH results without a call id).
/// 4. Stack fallback: the nearest preceding unmatched id-less call of an earlier turn.
/// An output that pairs with nothing becomes its own invocation (an orphan, `callBlockIndex` nil).
struct ToolInvocationIndex: Sendable {
    /// In id order.
    var invocations: [ToolInvocationRef]
    /// Every member block (call, outputs, paired `.error` blocks) → its invocation id.
    var invocationIDByBlock: [Int: Int]
    /// Process or cell id → the invocation that started it. Read from an output's header
    /// ("Process running with session ID N" / "Script running with cell ID N" in the first
    /// `ToolStatusProbe.headerScanLimit` bytes) and from Codex code-mode chunk metadata
    /// (`"session_id":N`). Keyed by N as written. Polls never own: `write_stdin`, `wait`, and a
    /// code-mode `exec` script that calls `tools.write_stdin(` but not `tools.exec_command(`.
    /// A later owner of the same N overwrites an earlier one (Codex reuses ids).
    ///
    /// A call that is still running (`pending` from a running header or a chunk `session_id`
    /// without `exit_code`) becomes `success` once a later poll call names its id in its input
    /// (`session_id` / `cell_id`, JSON or JavaScript): the process went on and was read again, so
    /// "no result yet" would be false. This covers the owner and earlier polls of the same id.
    var processOwnerBySessionID: [String: Int]

    static let empty = ToolInvocationIndex(invocations: [], invocationIDByBlock: [:], processOwnerBySessionID: [:])

    /// - Parameter blocks: the full session stream (`globalBlockIndex` == position), never a window slice.
    static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource) -> ToolInvocationIndex {
        guard !blocks.isEmpty else { return .empty }

        struct Slot {
            var id: Int
            var callPosition: Int?
            var outputPositions: [Int] = []
            var turn: Int
            /// The call is a poll (`isPollCall`): it never owns a process.
            var isPoll = false
            /// The call is Codex code mode: `codeModeFacts` holds one entry per output.
            var isCodeMode = false
            var codeModeFacts: [ToolStatusProbe.CodeModeFacts] = []
            /// The next slot (call or orphan) with the same `toolCallID`.
            var nextWithSameID: Int?
            /// A later poll named a process this slot's output showed running.
            var polledLater = false
        }
        /// Slots that share one `toolCallID`, linked through `nextWithSameID`. `head` moves past
        /// slots that already have an output.
        struct IDQueue {
            var head: Int
            var tail: Int
        }

        var slots: [Slot] = []
        var queueByCallID: [String: IDQueue] = [:]
        // Id-less calls of the current turn, consumed FIFO from `turnHead`.
        var turnCalls: [Int] = []
        var turnHead = 0
        // Calls with an id in the current turn, for id-less outputs (step 3); `turnIDHead` skips
        // calls that already have an output.
        var turnIDCalls: [Int] = []
        var turnIDHead = 0
        // Unmatched id-less calls of earlier turns, matched as a stack.
        var earlierCalls: [Int] = []
        var turn = 0
        // Turn → position of its last turn_aborted / interrupt notice.
        var noticeByTurn: [Int: Int] = [:]
        var invocationIDByBlock: [Int: Int] = [:]
        invocationIDByBlock.reserveCapacity(blocks.count / 2)
        var processOwners: [String: Int] = [:]
        // Process id → slots whose output showed it running and that no later poll has named yet.
        var runningSlotsByProcessID: [String: [Int]] = [:]

        func enqueue(_ slot: Int, callID: String) {
            if var queue = queueByCallID[callID] {
                slots[queue.tail].nextWithSameID = slot
                queue.tail = slot
                queueByCallID[callID] = queue
            } else {
                queueByCallID[callID] = IDQueue(head: slot, tail: slot)
            }
        }

        /// Step 1: the earliest slot with `callID` and no output, else the latest slot with it.
        func slotForCallID(_ callID: String) -> Int? {
            guard var queue = queueByCallID[callID] else { return nil }
            var current = queue.head
            while !slots[current].outputPositions.isEmpty, let next = slots[current].nextWithSameID {
                current = next
            }
            if current != queue.head {
                queue.head = current
                queueByCallID[callID] = queue
            }
            return current
        }

        /// Steps 2–4 for an output without an id.
        func slotForOutputWithoutID() -> Int? {
            if turnHead < turnCalls.count {
                turnHead += 1
                return turnCalls[turnHead - 1]
            }
            while turnIDHead < turnIDCalls.count, !slots[turnIDCalls[turnIDHead]].outputPositions.isEmpty {
                turnIDHead += 1
            }
            if turnIDHead < turnIDCalls.count {
                turnIDHead += 1
                return turnIDCalls[turnIDHead - 1]
            }
            return earlierCalls.popLast()
        }

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
                turnIDCalls.removeAll(keepingCapacity: true)
                turnIDHead = 0
                turn += 1
            case .meta:
                if isTurnAbortedNotice(blocks[position].text) { noticeByTurn[turn] = position }
            case .toolCall:
                let slot = slots.count
                let toolName = blocks[position].toolName
                let isPoll = isPollCall(toolName: toolName, toolInput: blocks[position].toolInput, source: source)
                slots.append(Slot(id: globalIndex, callPosition: position, turn: turn, isPoll: isPoll,
                                  isCodeMode: ToolStatusProbe.isCodeMode(toolName: toolName, source: source)))
                invocationIDByBlock[globalIndex] = globalIndex
                if isPoll, !runningSlotsByProcessID.isEmpty, let input = blocks[position].toolInput {
                    for processID in processIDs(in: Substring(input), keys: pollIDKeys) {
                        guard let running = runningSlotsByProcessID.removeValue(forKey: processID) else { continue }
                        for earlier in running { slots[earlier].polledLater = true }
                    }
                }
                if let callID = blocks[position].toolCallID {
                    enqueue(slot, callID: callID)
                    turnIDCalls.append(slot)
                } else {
                    turnCalls.append(slot)
                }
            case .toolOut, .error:
                let callID = blocks[position].toolCallID
                var target: Int?
                if let callID {
                    target = slotForCallID(callID)
                } else if kind == .toolOut {
                    target = slotForOutputWithoutID()
                } else {
                    continue   // an `.error` block without an id is a plain error
                }
                if target == nil {
                    target = slots.count
                    slots.append(Slot(id: globalIndex, callPosition: nil, turn: turn))
                    if let callID { enqueue(slots.count - 1, callID: callID) }
                }
                guard let slot = target else { continue }
                slots[slot].outputPositions.append(position)
                let invocationID = slots[slot].id
                invocationIDByBlock[globalIndex] = invocationID
                let ownsProcesses = !slots[slot].isPoll
                if let processID = ToolStatusProbe.runningProcessID(in: blocks[position].text) {
                    if ownsProcesses { processOwners[processID] = invocationID }
                    runningSlotsByProcessID[processID, default: []].append(slot)
                }
                if slots[slot].isCodeMode {
                    let facts = ToolStatusProbe.codeModeFacts(in: blocks[position].text)
                    slots[slot].codeModeFacts.append(facts)
                    if ownsProcesses {
                        for sessionID in facts.sessionIDs { processOwners[sessionID] = invocationID }
                    }
                    if facts.hasRunningChunk {
                        for sessionID in facts.sessionIDs { runningSlotsByProcessID[sessionID, default: []].append(slot) }
                    }
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
            var status = ToolStatusProbe.status(call: call,
                                                outputs: outputs,
                                                source: source,
                                                laterBlocksExist: slot.turn < lastTurn,
                                                turnAbortedAfter: abortedAfter,
                                                precomputedCodeModeFacts: slot.isCodeMode ? slot.codeModeFacts : nil)
            if status == .pending, slot.polledLater { status = .success }
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

    // MARK: Polls

    /// Input keys a poll names its process with: `write_stdin` `session_id`, `wait` `cell_id`.
    static let pollIDKeys = ["session_id", "cell_id"]

    /// A call that reads a running process instead of starting one: `write_stdin`, `wait`, and a
    /// Codex code-mode script whose only tool call is `write_stdin` (a substring check on the input).
    static func isPollCall(toolName: String?, toolInput: String?, source: SessionSource) -> Bool {
        if ToolStatusProbe.isPoll(toolName: toolName) { return true }
        guard ToolStatusProbe.isCodeMode(toolName: toolName, source: source), let input = toolInput else { return false }
        return input.contains("tools.write_stdin(") && !input.contains("tools.exec_command(")
    }

    /// The values of `keys` in `text`, in order: JSON `"session_id":42437` / `"session_id": "7"`,
    /// an escaped `\"session_id\":7`, or JavaScript `session_id: 42437`. A value is a token of
    /// letters, digits, `-` and `_`, the same alphabet the owner ids are read with. A key that is
    /// the tail of a longer name (`parent_session_id`) does not count.
    static func processIDs(in text: Substring, keys: [String]) -> [String] {
        let bytes = Array(text.utf8)
        let n = bytes.count
        func isWordByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
        }
        func isTokenByte(_ b: UInt8) -> Bool { isWordByte(b) || b == 0x2D }
        func skipQuote(_ j: inout Int) {
            if j < n, bytes[j] == 0x5C { j += 1 }                       // backslash of an escaped quote
            if j < n, bytes[j] == 0x22 || bytes[j] == 0x27 { j += 1 }   // " or '
        }
        func skipSpaces(_ j: inout Int) { while j < n, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 } }

        var ids: [String] = []
        for key in keys {
            let k = Array(key.utf8)
            guard !k.isEmpty, n >= k.count else { continue }
            var i = 0
            while i + k.count <= n {
                guard bytes[i] == k[0], bytes[i..<(i + k.count)].elementsEqual(k),
                      i == 0 || !isWordByte(bytes[i - 1]) else {
                    i += 1
                    continue
                }
                var j = i + k.count
                skipQuote(&j)
                skipSpaces(&j)
                guard j < n, bytes[j] == 0x3A else { i += 1; continue }   // ":"
                j += 1
                skipSpaces(&j)
                skipQuote(&j)
                let start = j
                while j < n, isTokenByte(bytes[j]) { j += 1 }
                if j > start { ids.append(String(decoding: bytes[start..<j], as: UTF8.self)) }
                i = max(j, i + 1)
            }
        }
        return ids
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
