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
        XCTAssertTrue(txt.contains("{\"k\":1}"))
        XCTAssertTrue(txt.contains("[\"a\",\"b\"]"))
    }

    func testStructuredToolOutputGetsReadableHeaderAndPrettyJSON() throws {
        let output = #"{"success":true,"query":"agent-sessions-stars","count":3,"results":[{"session_id":"cron_d2c8a0c8d33e_20260425_090025","summary":"Current total stars: 491"}]}"#
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "session_search",
                         toolInput: nil,
                         toolOutput: output,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-structured-tool",
                        source: .hermes,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/structured-tool.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("out: session_search"))
        XCTAssertTrue(txt.contains("success: true"))
        XCTAssertTrue(txt.contains("query: agent-sessions-stars"))
        XCTAssertTrue(txt.contains("results: 3"))
        XCTAssertTrue(txt.contains("[1] cron_d2c8a0c8d33e_20260425_090025"))
        XCTAssertTrue(txt.contains("Current total stars: 491"))
        XCTAssertFalse(txt.contains(#"{"success":true,"query":"#))
    }

    func testMemorySearchOutputSummaryMarkdownIsReadable() throws {
        let output = #"{"success":true,"query":"google-form-response-count","results":[{"session_id":"cron_d2c8a0c8d33e_20260423_180015","when":"April 23, 2026 at 06:00 PM","source":"cron","model":"qwen3.5-9b","summary":"**Session Summary: google-form-response-count Monitoring (April 23, 2026)**\n\n**1. Objective**\nThe system executed a scheduled cron job.\n\n**2. Actions Taken and Outcomes**\n*   **Memory Search:** The Assistant initiated a `session_search` tool call.\n*   **Last Known State:** The memory search confirmed **9 responses**."}]}"#
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "session_search",
                         toolInput: nil,
                         toolOutput: output,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-memory-search",
                        source: .hermes,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/memory-search.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("out: session_search"))
        XCTAssertTrue(txt.contains("query: google-form-response-count"))
        XCTAssertTrue(txt.contains("results: 1"))
        XCTAssertTrue(txt.contains("[1] cron_d2c8a0c8d33e_20260423_180015"))
        XCTAssertTrue(txt.contains("when: April 23, 2026 at 06:00 PM"))
        XCTAssertTrue(txt.contains("Session Summary: google-form-response-count Monitoring (April 23, 2026)"))
        XCTAssertTrue(txt.contains("- Memory Search: The Assistant initiated a `session_search` tool call."))
        XCTAssertTrue(txt.contains("- Last Known State: The memory search confirmed 9 responses."))
        XCTAssertFalse(txt.contains("**"))
        XCTAssertFalse(txt.contains("*   "))
    }

    func testStructuredMetadataDoesNotHideStdoutPayload() throws {
        let output = #"{"success":true,"query":"x","stdout":"real output"}"#
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "session_search",
                         toolInput: nil,
                         toolOutput: output,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-stdout-payload",
                        source: .hermes,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/stdout-payload.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("real output"))
        XCTAssertFalse(txt.contains("success: true\nquery: x"))
    }

    func testUnsupportedResultsPayloadFallsBackToPrettyJSON() throws {
        let output = #"{"success":true,"query":"x","results":["a","b"]}"#
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "session_search",
                         toolInput: nil,
                         toolOutput: output,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-array-results",
                        source: .hermes,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/array-results.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains(#""results" : ["#))
        XCTAssertTrue(txt.contains(#""a""#))
        XCTAssertTrue(txt.contains(#""b""#))
        XCTAssertFalse(txt.contains("results: 2"))
    }

    func testUnsupportedResultObjectPayloadFallsBackToPrettyJSON() throws {
        let output = #"{"success":true,"query":"x","results":[{"path":"/tmp/a","matches":3}]}"#
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "session_search",
                         toolInput: nil,
                         toolOutput: output,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-object-results",
                        source: .hermes,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/object-results.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains(#""path" : "#))
        XCTAssertTrue(txt.contains("tmp"))
        XCTAssertTrue(txt.contains(#""matches" : 3"#))
        XCTAssertFalse(txt.contains("[1] result"))
    }

    func testRawJSONOnlyNestedValueRemainsVisible() throws {
        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .tool_result,
                         role: "tool",
                         text: nil,
                         toolName: "droid",
                         toolInput: nil,
                         toolOutput: nil,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: #"{"payload":{"value":"ls: /nope"}}"#)
        ]
        let s = Session(id: "s-rawjson-value",
                        source: .droid,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/rawjson-value.json",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("ls: /nope"))
        XCTAssertFalse(txt.contains("(no output)"))
    }

    func testHermesToolOutputTranscriptIsLabeled() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-HermesTranscript-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_tool_output.json")
        let json = """
        {
          "session_id": "20260428_hermes_tool",
          "model": "qwen3.5-9b",
          "platform": "cron",
          "session_start": "2026-04-28T09:00:00.000000",
          "last_updated": "2026-04-28T09:05:00.000000",
          "message_count": 3,
          "messages": [
            { "role": "user", "content": "Check stars" },
            { "role": "assistant", "content": "I'll check.", "tool_calls": [
              { "id": "call_1", "type": "function", "function": { "name": "session_search", "arguments": "{\\"query\\":\\"agent-sessions-stars\\"}" } }
            ] },
            { "role": "tool", "tool_call_id": "call_1", "tool_name": "session_search", "content": "{\\"success\\":true,\\"query\\":\\"agent-sessions-stars\\",\\"count\\":3}" }
          ]
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        guard let session = HermesSessionParser.parseFileFull(at: url) else {
            return XCTFail("Hermes full parse returned nil")
        }

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("out: session_search"))
        XCTAssertTrue(txt.contains("query: agent-sessions-stars"))
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

    func testTurnAbortedBlocksRenderAsMetaInsteadOfUser() throws {
        let text = """
        <turn_aborted>
          <turn_id>21</turn_id>
          <reason>interrupted</reason>
          <guidance>The user interrupted the previous turn.</guidance>
        </turn_aborted>
        """

        let events: [SessionEvent] = [
            SessionEvent(id: "e1",
                         timestamp: nil,
                         kind: .user,
                         role: "user",
                         text: text,
                         toolName: nil,
                         toolInput: nil,
                         toolOutput: nil,
                         messageID: "m1",
                         parentID: nil,
                         isDelta: false,
                         rawJSON: "{}")
        ]
        let s = Session(id: "s-turn-aborted",
                        source: .codex,
                        startTime: nil,
                        endTime: nil,
                        model: "test",
                        filePath: "/tmp/turn-aborted.jsonl",
                        fileSizeBytes: nil,
                        eventCount: events.count,
                        events: events)

        let lines = TerminalBuilder.buildLines(for: s, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.role == .meta && $0.text == "Turn Aborted" }))
        XCTAssertTrue(lines.contains(where: { $0.role == .meta && $0.text.contains("Turn ID: 21") }))
        XCTAssertTrue(lines.contains(where: { $0.role == .meta && $0.text.contains("Reason: interrupted") }))
        XCTAssertFalse(lines.contains(where: { $0.role == .user && $0.text.contains("<turn_aborted") }))

        let plain = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: s, filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertFalse(plain.contains("<turn_aborted"), "Plain transcript should not include raw <turn_aborted> blocks")
        XCTAssertTrue(plain.contains("Turn Aborted"), "Plain transcript should include a readable turn-aborted notice")
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: plain, query: "turn_aborted"))

        let joined = lines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: joined, query: "turn_aborted"))
    }
}
