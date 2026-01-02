import XCTest
@testable import AgentSessions

final class DroidSessionParserTests: XCTestCase {
    private func writeTempJSONL(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("droid_test_\(UUID().uuidString).jsonl")
        let content = lines.joined(separator: "\n")
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    func testSessionStoreParsesToolUseAndToolResultWithErrorContent() throws {
        let lines = [
            #"{"type":"session_start","id":"s1","title":"Test Droid","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","timestamp":"2025-12-26T23:50:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Run a command"}]}}"#,
            #"{"type":"message","id":"m2","timestamp":"2025-12-26T23:50:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"ls /nope"}}]}}"#,
            #"{"type":"message","id":"m3","timestamp":"2025-12-26T23:50:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Error: Command failed (exit code: 1)\nls: /nope: No such file or directory"}]}}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = DroidSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.source, .droid)

        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)

        let call = session.events.first(where: { $0.kind == .tool_call })
        XCTAssertEqual(call?.toolName, "Execute")
        let toolInput = call?.toolInput ?? ""
        XCTAssertTrue(toolInput.contains("ls /nope") || toolInput.contains("ls \\/nope"))

        let result = session.events.first(where: { $0.kind == .tool_result })
        XCTAssertEqual(result?.toolName, "Execute")
        XCTAssertTrue((result?.toolOutput ?? "").contains("exit code: 1"))
    }

    func testSessionStorePreviewCountsCommands() throws {
        let lines = [
            #"{"type":"session_start","id":"s1","title":"Test Droid","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","timestamp":"2025-12-26T23:50:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"echo hi"}}]}}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let preview = DroidSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .droid)
        XCTAssertEqual(preview.events.count, 0)
        XCTAssertEqual(preview.lightweightCommands, 1)
        XCTAssertGreaterThanOrEqual(preview.eventCount, 1)
    }

    func testStreamJSONParsesMidStreamAndIgnoresPartialTrailingLine() throws {
        let lines = [
            #"{"type":"message","session_id":"sid1","timestamp":"2025-12-26T00:00:00.000Z","role":"user","text":"Do thing"}"#,
            #"{"type":"tool_call","session_id":"sid1","timestamp":"2025-12-26T00:00:01.000Z","toolCallId":"c1","toolName":"Shell","parameters":{"command":"echo hi"}}"#,
            #"{"type":"tool_result","session_id":"sid1","timestamp":"2025-12-26T00:00:02.000Z","toolCallId":"c1","value":{"stdout":"hi\n","exitCode":0}}"#,
            #"{"type":"completion","session_id":"sid1","timestamp":"2025-12-26T00:00:03.000Z","finalText":"Done"}"#,
            #"{"type":"message""# // partial
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = DroidSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.source, .droid)
        XCTAssertEqual(session.id, "sid1")

        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)
        XCTAssertGreaterThanOrEqual(session.events.filter { $0.kind == .assistant }.count, 1)

        let result = session.events.first(where: { $0.kind == .tool_result })
        XCTAssertEqual(result?.toolName, "Shell")
        XCTAssertTrue((result?.toolOutput ?? "").contains("exitCode"))
    }
}
