import XCTest
@testable import AgentSessions

final class ToolJSONTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    private func parseClaudeLine(_ line: String) throws -> [SessionEvent] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ToolJSONTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.jsonl")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url))
        return session.events
    }

    private func blockText(toolName: String, input: String) -> String {
        let event = TranscriptTestFixtures.toolCallEvent("e1", toolName: toolName, input: input)
        let session = Session(id: "toolJSON-\(UUID().uuidString)", source: .codex, startTime: nil, endTime: nil,
                              model: "test", filePath: "/tmp/x.jsonl", fileSizeBytes: nil,
                              eventCount: 1, events: [event])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        return blocks.map(\.text).joined(separator: "\n")
    }

    func testSlashesAreNotEscaped() {
        XCTAssertEqual(ToolJSON.string(from: ["command": "cd /Users/a && ls"], pretty: false),
                       #"{"command":"cd /Users/a && ls"}"#)
    }

    func testPrettyAndSortedKeys() {
        let out = ToolJSON.string(from: ["b": "/x", "a": 1], pretty: true)
        XCTAssertEqual(out, "{\n  \"a\" : 1,\n  \"b\" : \"/x\"\n}")
    }

    func testClaudeBashInputHasNoEscapedSlash() throws {
        let events = try parseClaudeLine(#"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat /etc/hosts"}}]}}"#)
        let event = try XCTUnwrap(events.first { $0.kind == .tool_call })
        XCTAssertTrue(event.toolInput!.contains("/etc/hosts"))
        XCTAssertFalse(event.toolInput!.contains(#"\/"#))
    }

    func testCallLabelHasNoEscapedSlash() {
        let text = blockText(toolName: "Read", input: #"{"file_path":"/tmp/a.txt"}"#)
        XCTAssertTrue(text.contains("/tmp/a.txt"))
        XCTAssertFalse(text.contains(#"\/"#))
    }

    // MARK: - Codex content items and call-id merge guard

    private func parseCodexLine(_ line: String) -> SessionEvent? {
        SessionIndexer.parseLine(line, eventID: "e-test").0
    }

    private func resultEvent(id: String, output: String, messageID: String?, callID: String?, isDelta: Bool = false) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: "shell", toolInput: nil, toolOutput: output,
                     toolNamespace: nil, toolCallID: callID,
                     messageID: messageID, parentID: nil, isDelta: isDelta, rawJSON: "{}")
    }

    private func session(_ events: [SessionEvent]) -> Session {
        Session(id: "toolCallID-\(UUID().uuidString)", source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/x.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    func testCodexContentItemOutputBecomesText() throws {
        let line = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.4 seconds\nOutput:\n"},{"type":"input_text","text":"hello\n"}]}}"#
        let e = try XCTUnwrap(parseCodexLine(line))
        XCTAssertEqual(e.toolOutput, "Script completed\nWall time 0.4 seconds\nOutput:\nhello\n")
        XCTAssertEqual(e.toolCallID, "c1")
    }

    func testJoinedContentItemTextHandlesImagesAndOtherShapes() {
        let items: [[String: Any]] = [["type": "output_text", "text": "a"], ["type": "input_image", "image_url": "x"], ["type": "text", "text": "b"]]
        XCTAssertEqual(ToolJSON.joinedContentItemText(items), "a\n[image]\nb")
        XCTAssertNil(ToolJSON.joinedContentItemText([["type": "weird", "text": "a"]]))
        XCTAssertNil(ToolJSON.joinedContentItemText("plain"))
        XCTAssertNil(ToolJSON.joinedContentItemText([Any]()))
    }

    func testOutputsWithDifferentCallIDsNeverMerge() {
        let a = resultEvent(id: "r1", output: "one", messageID: "m", callID: "t1")
        let b = resultEvent(id: "r2", output: "two", messageID: "m", callID: "t2")
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session([a, b]), includeMeta: false)
        XCTAssertEqual(blocks.map(\.text), ["one", "two"])
        XCTAssertEqual(blocks.map(\.toolCallID), ["t1", "t2"])
    }

    func testDeltaOutputsOfOneCallStillMerge() {
        let a = resultEvent(id: "r1", output: "on", messageID: nil, callID: "t1", isDelta: true)
        let b = resultEvent(id: "r2", output: "e", messageID: nil, callID: "t1", isDelta: true)
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session([a, b]), includeMeta: false).map(\.text), ["one"])
    }
}
