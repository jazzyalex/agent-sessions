import XCTest
@testable import AgentSessions

/// Task 6: `ToolInvocationIndex.build` pairs calls with outputs (by id, then FIFO in
/// the turn, then the stack fallback) and gives each invocation its cheap status.
final class ToolInvocationPairingTests: XCTestCase {
    private typealias F = TranscriptTestFixtures

    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    private func invocation(_ index: ToolInvocationIndex, containing block: Int) -> ToolInvocationRef? {
        guard let id = index.invocationIDByBlock[block] else { return nil }
        return index.invocations.first { $0.id == id }
    }

    // MARK: - Pairing order

    func testParallelCallsPairByID() {
        // 0 user · 1 c1 · 2 c2 · 3 c3 · 4 o1 · 5 o2 · 6 o3
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1"), F.block(.toolCall, id: "t2"), F.block(.toolCall, id: "t3"),
            F.block(.toolOut, id: "t1", text: "a"), F.block(.toolOut, id: "t2", text: "b"),
            F.block(.toolOut, id: "t3", text: "c"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.invocations.map(\.id), [1, 2, 3])
        XCTAssertEqual(index.invocations.map(\.callBlockIndex), [1, 2, 3])
        XCTAssertEqual(index.invocations.map(\.outputBlockIndices), [[4], [5], [6]])
        XCTAssertEqual(index.invocations.map(\.status), [.success, .success, .success])
        XCTAssertEqual(index.invocationIDByBlock, [1: 1, 2: 2, 3: 3, 4: 1, 5: 2, 6: 3])

        // Ids beat arrival order: outputs arrive t3, t1, t2.
        let shuffled = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1"), F.block(.toolCall, id: "t2"), F.block(.toolCall, id: "t3"),
            F.block(.toolOut, id: "t3", text: "c"), F.block(.toolOut, id: "t1", text: "a"),
            F.block(.toolOut, id: "t2", text: "b"),
        ])
        let byID = ToolInvocationIndex.build(blocks: shuffled, source: .codex)
        XCTAssertEqual(byID.invocations.map(\.outputBlockIndices), [[5], [6], [4]])
    }

    func testParallelCallsWithoutIDsPairFIFOInTurn() {
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall), F.block(.toolCall), F.block(.toolCall),
            F.block(.toolOut, text: "a"), F.block(.toolOut, text: "b"), F.block(.toolOut, text: "c"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.invocations.map(\.id), [1, 2, 3])
        XCTAssertEqual(index.invocations.map(\.outputBlockIndices), [[4], [5], [6]])
    }

    func testOutputWithoutCallInItsTurnFallsBackToStack() {
        // turn 1: 0 user · 1 c1 — turn 2: 2 user · 3 c2 · 4 o2 · 5 o1 (no ids)
        let blocks = F.sequence([
            F.block(.user, text: "one"),
            F.block(.toolCall),
            F.block(.user, text: "two"),
            F.block(.toolCall),
            F.block(.toolOut, text: "o2"),
            F.block(.toolOut, text: "o1"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(invocation(index, containing: 4)?.callBlockIndex, 3, "o2 pairs FIFO with c2 in its own turn")
        XCTAssertEqual(invocation(index, containing: 5)?.callBlockIndex, 1, "o1 falls back to the stack: c1")
        XCTAssertEqual(index.invocations.map(\.outputBlockIndices), [[5], [4]])
    }

    func testIDPairingIsSessionWide() {
        // The call is in turn 1, its output (same id) in turn 2.
        let blocks = F.sequence([
            F.block(.user, text: "one"),
            F.block(.toolCall, id: "t1"),
            F.block(.user, text: "two"),
            F.block(.toolOut, id: "t1", text: "late"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)

        XCTAssertEqual(index.invocations.count, 1)
        XCTAssertEqual(index.invocations.first?.outputBlockIndices, [3])
    }

    func testRuntimeErrorBlockPairsAsFailedOutput() {
        // 0 user · 1 c1 (t1) · 2 .error carrying t1 (a Claude runtime error)
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash"),
            F.block(.error, id: "t1", text: "Error: permission denied", isError: true,
                    disposition: .runtimeError),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)

        XCTAssertEqual(index.invocations.count, 1)
        XCTAssertEqual(index.invocations.first?.callBlockIndex, 1)
        XCTAssertEqual(index.invocations.first?.outputBlockIndices, [2])
        XCTAssertEqual(index.invocations.first?.status, .failed(exitCode: nil))
        XCTAssertEqual(index.invocationIDByBlock[2], 1)
    }

    func testErrorBlockWithoutMatchingCallIsFailedOrphan() {
        // A runtime error stays a tool output (spec §7.4): with no call it is an orphan invocation.
        // An `.error` block without an id is a plain error, not a tool block.
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.error, id: "nope", text: "boom", isError: true, disposition: .runtimeError),
            F.block(.error, text: "plain error", isError: true),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)

        XCTAssertEqual(index.invocations.map(\.id), [1])
        XCTAssertEqual(index.invocations.first?.callBlockIndex, nil)
        XCTAssertEqual(index.invocations.first?.outputBlockIndices, [1])
        XCTAssertEqual(index.invocations.first?.status, .failed(exitCode: nil))
        XCTAssertEqual(index.invocationIDByBlock, [1: 1])
    }

    func testIDlessOutputTakesOpenIDCallInItsTurn() {
        // c1 (id "a") · o (no id) in one turn → paired.
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "a"),
            F.block(.toolOut, text: "result"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .antigravity)
        XCTAssertEqual(index.invocations.count, 1)
        XCTAssertEqual(index.invocations.first?.outputBlockIndices, [2])

        // An open id-less call in the turn still comes first.
        let mixed = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "a"),
            F.block(.toolCall),
            F.block(.toolOut, text: "result"),
        ])
        let mixedIndex = ToolInvocationIndex.build(blocks: mixed, source: .antigravity)
        XCTAssertEqual(invocation(mixedIndex, containing: 3)?.callBlockIndex, 2)

        // The open id call of its own turn beats the cross-turn stack.
        let crossTurn = F.sequence([
            F.block(.user, text: "one"),
            F.block(.toolCall),                    // 1: id-less, open, earlier turn
            F.block(.user, text: "two"),
            F.block(.toolCall, id: "a"),           // 3: open id call in this turn
            F.block(.toolOut, text: "result"),     // 4
        ])
        let crossIndex = ToolInvocationIndex.build(blocks: crossTurn, source: .antigravity)
        XCTAssertEqual(invocation(crossIndex, containing: 4)?.callBlockIndex, 3)
    }

    func testRepeatedIDsPairInOrder() {
        // c(t) c(t) o(t) o(t) → 1:1 in order; an extra o(t) joins the latest call.
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t"),
            F.block(.toolCall, id: "t"),
            F.block(.toolOut, id: "t", text: "first"),
            F.block(.toolOut, id: "t", text: "second"),
            F.block(.toolOut, id: "t", text: "third"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)

        XCTAssertEqual(index.invocations.map(\.id), [1, 2])
        XCTAssertEqual(index.invocations.map(\.outputBlockIndices), [[3], [4, 5]])
    }

    func testOrphanOutputBecomesOwnInvocation() {
        // 0 user · 1 assistant · 2 o1 (id, no call) · 3 o2 (no id, no call)
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.assistant, text: "working"),
            F.block(.toolOut, id: "t9", text: "orphan"),
            F.block(.toolOut, text: "orphan 2"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.invocations.map(\.id), [2, 3])
        XCTAssertEqual(index.invocations.map(\.callBlockIndex), [nil, nil])
        XCTAssertEqual(index.invocations.map(\.outputBlockIndices), [[2], [3]])
        XCTAssertEqual(index.invocations.map(\.status), [.success, .success])
        XCTAssertEqual(index.invocationIDByBlock, [2: 2, 3: 3])
    }

    // MARK: - Calls without outputs

    func testCallWithoutOutputAtSessionEndIsPending() {
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1"),
            F.block(.assistant, text: "still working"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.invocations.count, 1)
        XCTAssertEqual(index.invocations.first?.status, .pending)
        XCTAssertEqual(index.invocations.first?.outputBlockIndices, [])
    }

    func testCallWithoutOutputBeforeALaterTurnIsNoResult() {
        let blocks = F.sequence([
            F.block(.user, text: "one"),
            F.block(.toolCall, id: "t1"),
            F.block(.user, text: "two"),
            F.block(.assistant, text: "ok"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.invocations.first?.status, .noResult)
    }

    func testInterruptedByTurnAbortedNotice() {
        // Real coalesce: the `<turn_aborted>` user message is split into its own `.meta`
        // notice, which sits in the call's turn.
        func session(aborted: Bool) -> Session {
            var events: [SessionEvent] = [
                TranscriptTestFixtures.userEvent("u1", "run the build"),
                SessionEvent(id: "c1", timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                             toolName: "exec_command", toolInput: #"{"cmd":"make"}"#, toolOutput: nil,
                             toolNamespace: nil, toolCallID: "call_1",
                             messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}"),
            ]
            if aborted {
                events.append(TranscriptTestFixtures.userEvent(
                    "u2", "<turn_aborted>\n<turn_id>t-1</turn_id>\n<reason>interrupted</reason>\n</turn_aborted>"))
            }
            events.append(TranscriptTestFixtures.userEvent("u3", "try again"))
            events.append(TranscriptTestFixtures.assistantDelta("a1", "ok", messageID: "m-a1"))
            return Session(id: "pairing-abort-\(aborted)-\(UUID().uuidString)", source: .codex,
                           startTime: nil, endTime: nil, model: "test", filePath: "/tmp/abort.jsonl",
                           fileSizeBytes: nil, eventCount: events.count, events: events)
        }

        let abortedBlocks = SessionTranscriptBuilder.coalescedBlocks(for: session(aborted: true), includeMeta: false)
        XCTAssertTrue(abortedBlocks.contains { $0.kind == .meta && $0.text.contains("Tag: turn_aborted") },
                      "sanity: the builder splits the notice into a meta block")
        let aborted = ToolInvocationIndex.build(blocks: abortedBlocks, source: .codex)
        XCTAssertEqual(aborted.invocations.first?.status, .interrupted)

        // Control: the same call with no notice is noResult (a later turn exists).
        let plainBlocks = SessionTranscriptBuilder.coalescedBlocks(for: session(aborted: false), includeMeta: false)
        let plain = ToolInvocationIndex.build(blocks: plainBlocks, source: .codex)
        XCTAssertEqual(plain.invocations.first?.status, .noResult)
    }

    func testInterruptedByUserInterruptMarker() {
        // Claude writes "[Request interrupted by user for tool use]" as a user message.
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash"),
            F.block(.user, text: "[Request interrupted by user for tool use]"),
            F.block(.user, text: "do something else"),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)

        XCTAssertEqual(index.invocations.first?.status, .interrupted)
    }

    func testCursorCallStatusIsUnknown() {
        let blocks = F.sequence([
            F.block(.user, text: "one"),
            F.block(.toolCall),
            F.block(.user, text: "two"),
            F.block(.toolCall),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .cursor)

        XCTAssertEqual(index.invocations.map(\.status), [.unknown, .unknown])
    }

    // MARK: - Process owners

    func testProcessOwnerBySessionID() {
        let running = "Chunk ID: ab12\nWall time: 1.0 seconds\nProcess running with session ID 42437\n"
            + "Original token count: 0\nOutput:\n"
        // A mention deep in an output body is not a header: it must not claim an owner.
        let body = String(repeating: "x", count: 600) + "\nProcess running with session ID 99\n"
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec_command"),                 // 1
            F.block(.toolOut, id: "t1", text: running),                             // 2
            F.block(.toolCall, id: "t2", toolName: "exec"),                         // 3
            F.block(.toolOut, id: "t2", text: "Script running with cell ID 7\nWall time 11.0 seconds\nOutput:\n"), // 4
            F.block(.toolCall, id: "t3", toolName: "exec_command"),                 // 5
            F.block(.toolOut, id: "t3", text: running),                             // 6
            F.block(.toolCall, id: "t4", toolName: "exec_command"),                 // 7
            F.block(.toolOut, id: "t4", text: body),                                // 8
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.processOwnerBySessionID["42437"], 5, "a later owner of the same id wins")
        XCTAssertEqual(index.processOwnerBySessionID["7"], 3)
        XCTAssertNil(index.processOwnerBySessionID["99"])
        XCTAssertEqual(index.processOwnerBySessionID.count, 2)
    }

    func testPollsDoNotTakeOwnership() {
        let running = "Chunk ID: ab12\nWall time: 10.0 seconds\nProcess running with session ID 42437\n"
            + "Original token count: 0\nOutput:\n"
        let blocks = F.sequence([
            F.block(.user, text: "start the dev server"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: #"{"cmd":"npm run dev"}"#), // 1
            F.block(.toolOut, id: "t1", text: running),                                                // 2
            F.block(.toolCall, id: "t2", toolName: "write_stdin", toolInput: #"{"session_id":42437,"chars":""}"#), // 3
            F.block(.toolOut, id: "t2", text: running),                                                // 4
            F.block(.toolCall, id: "t3", toolName: "wait", toolInput: #"{"session_id":42437}"#),        // 5
            F.block(.toolOut, id: "t3", text: running),                                                // 6
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)
        XCTAssertEqual(index.processOwnerBySessionID["42437"], 1, "polls never take ownership")

        // A later non-poll owner of the same id still overwrites (Codex reuses session ids).
        let reused = F.sequence(blocks + [
            F.block(.toolCall, id: "t4", toolName: "exec_command", toolInput: #"{"cmd":"make watch"}"#), // 7
            F.block(.toolOut, id: "t4", text: running),                                                 // 8
        ])
        XCTAssertEqual(ToolInvocationIndex.build(blocks: reused, source: .codex).processOwnerBySessionID["42437"], 7)
    }

    func testCodeModeChunkSessionIDRegistersOwner() {
        let chunk = "Script completed\nWall time 10.0 seconds\nOutput:\n"
            + #"{"chunk_id":"df07ab","wall_time_seconds":10.0,"session_id":90623,"output":"…"}"#
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec", toolInput: "await tools.exec_command({cmd: \"npm run dev\"})"),
            F.block(.toolOut, id: "t1", text: chunk),
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)

        XCTAssertEqual(index.processOwnerBySessionID["90623"], 1)
        XCTAssertEqual(index.invocations.first?.status, .pending)
    }

    /// Task 9 ruling: a code-mode `exec` script whose only tool calls are `write_stdin` is a poll.
    /// Its chunk `session_id` must not take the process over from the script that started it.
    func testCodeModePollScriptIsNotAnOwner() {
        let running = "Script completed\nWall time 10.0 seconds\nOutput:\n"
            + #"{"chunk_id":"df07ab","wall_time_seconds":10.0,"session_id":90623,"output":"ready"}"#
        let blocks = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec",
                    toolInput: "await tools.exec_command({cmd: \"npm run dev\"})"),                     // 1
            F.block(.toolOut, id: "t1", text: running),                                               // 2
            F.block(.toolCall, id: "t2", toolName: "exec",
                    toolInput: "await tools.write_stdin({session_id: 90623, chars: \"\"})"),          // 3
            F.block(.toolOut, id: "t2", text: running),                                               // 4
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)
        XCTAssertEqual(index.processOwnerBySessionID["90623"], 1, "a write_stdin-only script is a poll, not an owner")

        // A script that starts a command and also writes to it is not a pure poll: it still owns.
        let mixed = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec",
                    toolInput: "await tools.exec_command({cmd: \"npm run dev\"})"),                     // 1
            F.block(.toolOut, id: "t1", text: running),                                               // 2
            F.block(.toolCall, id: "t2", toolName: "exec",
                    toolInput: "await tools.exec_command({cmd: \"cat\"}); await tools.write_stdin({session_id: 1, chars: \"x\"})"), // 3
            F.block(.toolOut, id: "t2", text: running),                                               // 4
        ])
        XCTAssertEqual(ToolInvocationIndex.build(blocks: mixed, source: .codex).processOwnerBySessionID["90623"], 3)
    }

    /// Task 9 ruling: a running owner (pending from its "Process running" header or a chunk
    /// `session_id` without `exit_code`) becomes `.success` once a later poll references its id.
    func testRunningOwnerSucceedsAfterLaterPoll() {
        let running = "Chunk ID: ab12\nWall time: 10.0 seconds\nProcess running with session ID 42437\n"
            + "Original token count: 0\nOutput:\n"
        let exited = "Chunk ID: cd34\nWall time: 3.0 seconds\nProcess exited with code 0\nOriginal token count: 0\nOutput:\nbye\n"
        let blocks = F.sequence([
            F.block(.user, text: "start the dev server"),
            F.block(.toolCall, id: "t1", toolName: "exec_command", toolInput: #"{"cmd":"npm run dev"}"#),          // 1
            F.block(.toolOut, id: "t1", text: running),                                                         // 2
            F.block(.toolCall, id: "t2", toolName: "exec_command", toolInput: #"{"cmd":"make watch"}"#),           // 3
            F.block(.toolOut, id: "t2", text: running.replacingOccurrences(of: "42437", with: "555")),           // 4
            F.block(.toolCall, id: "t3", toolName: "write_stdin", toolInput: #"{"session_id":42437,"chars":""}"#), // 5
            F.block(.toolOut, id: "t3", text: running),                                                         // 6
            F.block(.toolCall, id: "t4", toolName: "write_stdin", toolInput: #"{"session_id":42437,"chars":""}"#), // 7
            F.block(.toolOut, id: "t4", text: exited),                                                          // 8
        ])
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)
        XCTAssertEqual(invocation(index, containing: 1)?.status, .success, "a later poll of 42437 finishes its owner")
        XCTAssertEqual(invocation(index, containing: 5)?.status, .success, "a poll that saw it running is read again later")
        XCTAssertEqual(invocation(index, containing: 7)?.status, .success)
        XCTAssertEqual(invocation(index, containing: 3)?.status, .pending, "no poll references 555")
        XCTAssertEqual(index.processOwnerBySessionID["42437"], 1)

        // Code mode: a JS poll (`session_id: N`) of a chunk-registered owner.
        let chunk = "Script completed\nWall time 10.0 seconds\nOutput:\n"
            + #"{"chunk_id":"df07ab","wall_time_seconds":10.0,"session_id":90623,"output":"ready"}"#
        let codeMode = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "exec",
                    toolInput: "await tools.exec_command({cmd: \"npm run dev\"})"),                      // 1
            F.block(.toolOut, id: "t1", text: chunk),                                                  // 2
            F.block(.toolCall, id: "t2", toolName: "exec",
                    toolInput: "await tools.write_stdin({session_id: 90623, chars: \"\"})"),           // 3
            F.block(.toolOut, id: "t2", text: "Script completed\nWall time 1.0 seconds\nOutput:\n"),   // 4
        ])
        let codeIndex = ToolInvocationIndex.build(blocks: codeMode, source: .codex)
        XCTAssertEqual(invocation(codeIndex, containing: 1)?.status, .success)

        // A poll that comes before the owner's output does not count.
        let early = F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "write_stdin", toolInput: #"{"session_id":42437,"chars":""}"#), // 1
            F.block(.toolOut, id: "t1", text: exited),                                                          // 2
            F.block(.toolCall, id: "t2", toolName: "exec_command", toolInput: #"{"cmd":"npm run dev"}"#),          // 3
            F.block(.toolOut, id: "t2", text: running),                                                         // 4
        ])
        XCTAssertEqual(invocation(ToolInvocationIndex.build(blocks: early, source: .codex), containing: 3)?.status, .pending)
    }

    func testEmptyIndex() {
        let index = ToolInvocationIndex.build(blocks: [], source: .codex)
        XCTAssertTrue(index.invocations.isEmpty)
        XCTAssertTrue(ToolInvocationIndex.empty.invocations.isEmpty)
        XCTAssertTrue(ToolInvocationIndex.empty.invocationIDByBlock.isEmpty)
        XCTAssertTrue(ToolInvocationIndex.empty.processOwnerBySessionID.isEmpty)
    }
}
