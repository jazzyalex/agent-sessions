import XCTest

final class DroidSessionParserLogicTests: XCTestCase {
    private func writeTempJSONL(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("droid_logic_test_\(UUID().uuidString).jsonl")
        let content = lines.joined(separator: "\n")
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    func testSessionStoreParsesToolUseAndToolResultWithErrorContent() throws {
        let lines = [
            #"{"type":"session_start","id":"s1","title":"Test Droid","cwd":"/tmp"}"#,
            #"{"type":"message","id":"m1","timestamp":"2025-12-26T23:50:00.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>Do not edit files</system-reminder>\n<system-reminder>More rules</system-reminder>\nanalyze briefly current codebase"}]}}"#,
            #"{"type":"message","id":"m2","timestamp":"2025-12-26T23:50:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Execute","input":{"command":"ls /nope"}}]}}"#,
            #"{"type":"message","id":"m3","timestamp":"2025-12-26T23:50:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Error: Command failed (exit code: 1)\nls: /nope: No such file or directory"}]}}"#
        ]
        let url = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = DroidSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.source, .droid)
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 2)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)

        XCTAssertEqual(session.title, "analyze briefly current codebase")
        XCTAssertTrue(session.events.contains(where: { $0.kind == .user && (($0.text?.contains("<system-reminder>")) ?? false) }))
        XCTAssertTrue(session.events.contains(where: { $0.kind == .user && (($0.text?.trimmingCharacters(in: .whitespacesAndNewlines)) == "analyze briefly current codebase") }))

        let call = session.events.first(where: { $0.kind == .tool_call })
        XCTAssertEqual(call?.toolName, "Execute")
        if let input = call?.toolInput,
           let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = obj["command"] as? String {
            XCTAssertEqual(cmd, "ls /nope")
        } else {
            XCTFail("Expected JSON tool input with command")
        }

        let result = session.events.first(where: { $0.kind == .tool_result })
        XCTAssertEqual(result?.toolName, "Execute")
        XCTAssertTrue((result?.toolOutput ?? "").contains("exit code: 1"))
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
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)
    }
}
