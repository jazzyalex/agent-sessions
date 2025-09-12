import XCTest
@testable import CodexHistory

final class TranscriptBuilderTests: XCTestCase {
    // Helper to build a session from raw line strings
    private func session(from lines: [String]) -> Session {
        let idx = SessionIndexer()
        var events: [SessionEvent] = []
        for (i, line) in lines.enumerated() {
            events.append(SessionIndexer.parseLine(line, eventID: "e-\(i)").0)
        }
        return Session(id: "s-1", startTime: Date(), endTime: Date(), model: "test", filePath: "/tmp/x.jsonl", eventCount: events.count, events: events)
    }

    func testAssistantContentArraysConcatenate() throws {
        let line = "{" +
        "\"timestamp\":\"2025-09-10T00:00:00Z\",\"role\":\"assistant\",\"content\":[{" +
        "\"type\":\"text\",\"text\":\"A\"},{\"type\":\"text\",\"text\":\"B\"}]" +
        "}"
        let s = session(from: [line])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("\nAB\n") || txt.contains("\nAB"))
    }

    func testNonStringToolOutputsPrettyPrinted() throws {
        let line = "{" +
        "\"timestamp\":\"2025-09-10T00:00:01Z\",\"type\":\"tool_result\",\"name\":\"exec\",\"stdout\":{\"k\":1},\"stderr\":[\"a\",\"b\"]" +
        "}"
        let s = session(from: [line])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("⟪out⟫"))
        // Pretty JSON with 2-space indent should appear
        XCTAssertTrue(txt.contains("\n  \"k\": 1") || txt.contains("  \"k\": 1"))
        XCTAssertTrue(txt.contains("\n  \"0\": \"a\"") == false) // ensure kept as array format not dict
        XCTAssertTrue(txt.contains("\n  \"a\"\n  ,\n  \"b\"") == false) // tolerate platform JSON spacing
        XCTAssertTrue(txt.contains("\"a\""))
        XCTAssertTrue(txt.contains("\"b\""))
    }

    func testChunksAreCoalescedByMessageID() throws {
        let l1 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"A\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let l2 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"B\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let l3 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"C\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let s = session(from: [l1, l2, l3])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        // Should contain single ABC block (not three separate lines with prefixes)
        XCTAssertTrue(txt.contains("\nABC\n") || txt.contains("\nABC"))
        XCTAssertFalse(txt.contains("\nA\nB\nC\n"))
    }

    func testNoTruncationForLongOutput() throws {
        let payload = String(repeating: "X", count: 120_000)
        let line = "{\"type\":\"tool_result\",\"name\":\"dump\",\"result\":\"\(payload)\"}"
        let s = session(from: [line])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertGreaterThanOrEqual(txt.utf8.count, payload.utf8.count)
        XCTAssertFalse(txt.contains("bytes truncated"))
    }

    func testTimestampsToggle() throws {
        let l1 = "{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":\"2025-09-10T10:00:00Z\"}"
        let s = session(from: [l1])
        let off = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertFalse(off.contains("@10:00:00"))
        let on = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: true, showMeta: false))
        XCTAssertTrue(on.contains("@10:00:00"))
    }

    func testDeterminism() throws {
        let idx = SessionIndexer()
        let s = idx.parseFile(at: Bundle(for: type(of: self)).url(forResource: "session_branch", withExtension: "jsonl")!)!
        let a = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: true))
        let b = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: true))
        XCTAssertEqual(a, b)
    }
}
