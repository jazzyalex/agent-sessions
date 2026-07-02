import XCTest
@testable import AgentSessions

final class PerfQuickWinsTests: XCTestCase {

    // MARK: - Fixtures

    private func userEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func assistantDelta(_ id: String, _ text: String, messageID: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: messageID, parentID: nil, isDelta: true, rawJSON: "{}")
    }

    private func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: "t-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func session(_ events: [SessionEvent]) -> Session {
        Session(id: "s-perf", source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    // MARK: - Task 1: coalescer delta-merge must be linear, not CoW-quadratic

    func testCoalesceLongDeltaChainIsLinearAndLossless() {
        let chunk = String(repeating: "x", count: 200)
        var events: [SessionEvent] = []
        events.reserveCapacity(20_000)
        for i in 0..<20_000 {
            events.append(assistantDelta("a-\(i)", chunk, messageID: "m-single"))
        }
        let s = session(events)

        let start = Date()
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(blocks.count, 1, "one merge chain must coalesce to one block")
        XCTAssertEqual(blocks[0].text.utf8.count, 20_000 * 200, "no bytes lost in merge")
        XCTAssertEqual(blocks[0].globalBlockIndex, 0)
        XCTAssertEqual(blocks[0].firstEventIndex, 0)
        // Quadratic CoW copies ~40 GB here (minutes); linear is milliseconds.
        XCTAssertLessThan(elapsed, 2.0,
            "coalescing a long delta chain must be linear (CoW append was quadratic)")
    }

    // MARK: - Task 2: error/code detection behavior pins (guard the regex hoist)

    func testToolResultErrorClassificationByExitCodeAndPrefix() {
        let cases: [(output: String, isError: Bool)] = [
            ("exit code: 1\nboom", true),
            ("Exit Code: 0\nfine", false),
            ("exit status 2", true),
            ("[error] failed to fetch", true),
            ("error: no such file", true),
            ("all good\nexit code: 1 mentioned later is ignored", false),
            ("plain output", false)
        ]
        for (output, isError) in cases {
            let s = session([toolResultEvent("t1", output: output)])
            let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0].isErrorOutput, isError, "output: \(output)")
        }
    }

    func testReadToolNumberedDumpClassifiedAsCode() {
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.semanticKind == .code },
                      "line-numbered read-tool output must render as a code segment")
    }
}
