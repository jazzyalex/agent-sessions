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
}
