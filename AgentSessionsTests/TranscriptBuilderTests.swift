import XCTest
@testable import AgentSessions

final class TranscriptBuilderTests: XCTestCase {
    // Helper to build a session from raw line strings
    private func session(from lines: [String]) -> Session {
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
        XCTAssertEqual(txt.trimmingCharacters(in: .whitespacesAndNewlines), "AB")
    }

    func testNonStringToolOutputsPrettyPrinted() throws {
        let line = "{" +
        "\"timestamp\":\"2025-09-10T00:00:01Z\",\"type\":\"tool_result\",\"name\":\"exec\",\"stdout\":{\"k\":1},\"stderr\":[\"a\",\"b\"]" +
        "}"
        let s = session(from: [line])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains(SessionTranscriptBuilder.outPrefix))
        XCTAssertTrue(txt.contains("\"k\" : 1") || txt.contains("\"k\": 1"))
        XCTAssertTrue(txt.contains("["))
        XCTAssertTrue(txt.contains("\"a\""))
        XCTAssertTrue(txt.contains("\"b\""))
    }

    func testChunksAreCoalescedByMessageID() throws {
        let l1 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"A\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let l2 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"B\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let l3 = "{\"role\":\"assistant\",\"message_id\":\"m1\",\"content\":\"C\",\"timestamp\":\"2025-09-10T00:00:00Z\"}"
        let s = session(from: [l1, l2, l3])
        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertEqual(txt.trimmingCharacters(in: .whitespacesAndNewlines), "ABC")
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
        XCTAssertFalse(off.contains(AppDateFormatting.transcriptSeparator))
        let on = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: true, showMeta: false))
        XCTAssertTrue(on.contains(AppDateFormatting.transcriptSeparator))
        XCTAssertTrue(on.contains(AppDateFormatting.transcriptSeparator + SessionTranscriptBuilder.userPrefix))
    }

    func testDeterminism() throws {
        let idx = SessionIndexer()
        let s = idx.parseFile(at: Bundle(for: type(of: self)).url(forResource: "session_branch", withExtension: "jsonl")!)!
        let a = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: true))
        let b = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: true))
        XCTAssertEqual(a, b)
    }

    func testSearchToolIOSanitizesDataURLsAndBase64() throws {
        let base64 = "/9j/" + String(repeating: "A", count: 20_000) + "=="
        let dataURL = "data:image/jpeg;base64,\(base64)"
        let toolOut = "Captured screenshot:\n\(dataURL)\nDone."

        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "chrome_screenshot",
                         toolInput: "{\"tabId\":1}",
                         toolOutput: toolOut,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-toolio",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/toolio.jsonl",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let text = SessionSearchTextBuilder.buildToolIO(session: s)
        XCTAssertTrue(text.contains("Captured screenshot"))
        XCTAssertTrue(text.contains("[data-url omitted:"), "Expected data URLs to be redacted for indexing")
        XCTAssertFalse(text.contains("data:image/jpeg;base64,"), "Should not include data URL payloads in indexed text")
        XCTAssertFalse(text.contains(String(base64.prefix(64))), "Should not include base64 payloads in indexed text")
    }

    func testUsageResetTextTimeOnlyRollsForwardToNextDayWhenPast() throws {
        let tz = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let now = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 5, hour: 20, minute: 21, second: 0))!
        let reset = UsageResetText.resetDate(kind: "5h", source: .codex, raw: "resets 00:03 (UTC)", now: now)
        let expected = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 6, hour: 0, minute: 3, second: 0))!
        XCTAssertEqual(reset, expected)

        let now2 = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 5, hour: 10, minute: 0, second: 0))!
        let reset2 = UsageResetText.resetDate(kind: "5h", source: .codex, raw: "resets 23:00 (UTC)", now: now2)
        let expected2 = cal.date(from: DateComponents(timeZone: tz, year: 2026, month: 1, day: 5, hour: 23, minute: 0, second: 0))!
        XCTAssertEqual(reset2, expected2)
    }
}
