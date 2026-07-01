import XCTest
@testable import AgentSessions

final class TerminalGlobalIdentityParityTests: XCTestCase {

    // MARK: Fixtures

    private func makeEvent(id: String,
                           kind: SessionEventKind,
                           text: String? = nil,
                           toolName: String? = nil,
                           toolOutput: String? = nil,
                           messageID: String? = nil,
                           isDelta: Bool = false) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: toolName,
                     toolInput: nil,
                     toolOutput: toolOutput,
                     messageID: messageID ?? id,
                     parentID: nil,
                     isDelta: isDelta,
                     rawJSON: "{}")
    }

    private func makeSession(source: SessionSource, events: [SessionEvent]) -> Session {
        Session(id: "s-global",
                source: source,
                startTime: nil,
                endTime: nil,
                model: "test-model",
                filePath: "/tmp/s-global.jsonl",
                fileSizeBytes: nil,
                eventCount: events.count,
                events: events)
    }

    /// Mixed session: two user prompts, assistant deltas that coalesce, a tool
    /// call + output, and an error — enough to exercise every role + a merge.
    private func mixedEvents() -> [SessionEvent] {
        [
            makeEvent(id: "u1", kind: .user, text: "First question"),
            makeEvent(id: "a1", kind: .assistant, text: "Part one ", messageID: "m1", isDelta: true),
            makeEvent(id: "a2", kind: .assistant, text: "part two.", messageID: "m1", isDelta: true),
            makeEvent(id: "tc1", kind: .tool_call, text: "ls -la", toolName: "shell"),
            makeEvent(id: "to1", kind: .tool_result, toolName: "shell", toolOutput: "file.txt\nother.txt"),
            makeEvent(id: "u2", kind: .user, text: "Second question"),
            makeEvent(id: "a3", kind: .assistant, text: "Answer two."),
            makeEvent(id: "er1", kind: .error, text: "boom"),
        ]
    }

    // MARK: Task 3 assertions

    func testCoalesceAssignsContiguousGlobalBlockIndexes() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertFalse(blocks.isEmpty)
        for (offset, block) in blocks.enumerated() {
            XCTAssertEqual(block.globalBlockIndex, offset,
                           "block at offset \(offset) must carry globalBlockIndex == offset")
        }
    }

    func testCoalesceAssignsFirstEventIndexOfMergeChain() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // The merged assistant block (a1+a2) must report the FIRST event's index.
        guard let merged = blocks.first(where: { $0.kind == .assistant && $0.text.contains("Part one") }) else {
            return XCTFail("expected merged assistant block")
        }
        // a1 is events[1] in mixedEvents().
        XCTAssertEqual(merged.firstEventIndex, 1,
                       "merged block firstEventIndex must be the first event in the chain")
    }
}
