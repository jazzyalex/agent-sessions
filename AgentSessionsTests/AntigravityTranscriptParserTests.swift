import XCTest
@testable import AgentSessions

final class AntigravityTranscriptParserTests: XCTestCase {
    private func writeTranscript(_ lines: [String]) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("conv-1/.system_generated/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesUserAssistantToolEvents() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nlist the files\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>"}"#,
            #"{"step_index":1,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-06-26T21:16:16Z"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"I will list the directory.","tool_calls":[{"name":"list_dir","args":{"DirectoryPath":"\"/tmp/repo\""}}]}"#,
            #"{"step_index":3,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"a.txt\nb.txt\n"}"#,
            ##"{"step_index":4,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"# Resuming from a compaction"}"##,
        ])

        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(s.source, .antigravity)
        XCTAssertEqual(s.id, "conv-1")
        XCTAssertTrue(s.events.contains { $0.kind == .user && ($0.text ?? "").contains("list the files") })
        XCTAssertTrue(s.events.contains { $0.kind == .assistant })
        XCTAssertTrue(s.events.contains { $0.kind == .tool_call && $0.toolName == "list_dir" })
        XCTAssertTrue(s.events.contains { $0.kind == .tool_result && ($0.toolOutput ?? "").contains("a.txt") })
        XCTAssertEqual(s.model, "Gemini 3.5 Flash (Medium)")
        XCTAssertEqual(s.lightweightTitle, "list the files")
        XCTAssertFalse(s.events.contains { ($0.text ?? "").contains("<USER_REQUEST>") })
    }

    func testPreviewParseHasEmptyEventsButCount() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#,
        ])
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: false) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertGreaterThan(s.eventCount, 0)
    }

    func testGeminiParserDispatchesJSONLAndMarkdown() throws {
        let jsonl = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nhello\n</USER_REQUEST>"}"#,
        ])
        XCTAssertNotNil(GeminiSessionParser.parseFileFull(at: jsonl))

        let mdDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/conv-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: mdDir, withIntermediateDirectories: true)
        let md = mdDir.appendingPathComponent("task.md")
        try "# Title\n\nbody".write(to: md, atomically: true, encoding: .utf8)
        XCTAssertNotNil(GeminiSessionParser.parseFileFull(at: md))
    }

    func testDiscoveryFindsNewCLITranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        let logs = cliRoot.appendingPathComponent("c1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let t = logs.appendingPathComponent("transcript.jsonl")
        try #"{"type":"USER_INPUT","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#.write(to: t, atomically: true, encoding: .utf8)

        let disco = GeminiSessionDiscovery(cliRoot: cliRoot.path)
        XCTAssertTrue(disco.discoverSessionFiles().contains { $0.lastPathComponent == "transcript.jsonl" })
    }
}
