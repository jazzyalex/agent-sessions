import XCTest
@testable import AgentSessions

final class GeminiParserTests: XCTestCase {
    private func writeTemp(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gemini_test_\(UUID().uuidString).json")
        try json.data(using: .utf8)?.write(to: url)
        return url
    }

    func testFlatArrayTextAndParts() throws {
        let json = """
        [
          {"type":"user","text":"Prompt 1","ts":"2025-09-18T02:45:00Z"},
          {"type":"model","parts":[{"text":"Reply 1"}],"ts":"2025-09-18T02:45:08Z"}
        ]
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[0].kind, .user)
        XCTAssertEqual(session.events[0].role, "user")
        XCTAssertEqual(session.events[0].text, "Prompt 1")
        XCTAssertNotNil(session.events[0].timestamp)
        XCTAssertEqual(session.events[1].kind, .assistant)
        XCTAssertEqual(session.events[1].role, "assistant")
        XCTAssertEqual(session.events[1].text, "Reply 1")
        XCTAssertNotNil(session.events[1].timestamp)
    }

    func testWrappedHistoryEpoch() throws {
        let json = """
        {
          "history": [
            {"role":"user","text":"Ask","ts":1695000000},
            {"role":"gemini","parts":[{"text":"Answer"}]}
          ],
          "meta": {"model":"gmini-pro"}
        }
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[0].kind, .user)
        XCTAssertEqual(session.events[1].kind, .assistant)
        XCTAssertEqual(session.events[1].text, "Answer")
        XCTAssertNotNil(session.startTime)
        XCTAssertNotNil(session.endTime)
    }

    func testInlineDataPlaceholder() throws {
        let json = """
        {
          "history": [
            {"type":"user","parts":[{"text":"Describe this image:"},{"inlineData":{"mimeType":"image/png","data":"AAAA"}}]},
            {"type":"model","parts":[{"text":"It looks like..."}]}
          ]
        }
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.count, 2)
        XCTAssertTrue(session.events[0].text?.contains("[inline data omitted]") == true)
        XCTAssertEqual(session.events[1].text, "It looks like...")
    }

    func testToolCallsAndInfoMessages() throws {
        let json = """
        {
          "startTime": "2025-12-16T23:47:00.000Z",
          "lastUpdated": "2025-12-16T23:48:00.000Z",
          "projectHash": "205016864bd110904e9ad8314192344ab398d043e779da15bedbb9ee9be00da2",
          "sessionId": "session-2025-12-16T23-47-b4f17607",
          "messages": [
            {
              "id": "m1",
              "timestamp": "2025-12-16T23:47:01.000Z",
              "type": "user",
              "content": "Run a command"
            },
            {
              "id": "m2",
              "timestamp": "2025-12-16T23:47:02.000Z",
              "type": "gemini",
              "content": "",
              "toolCalls": [
                {
                  "id": "run_shell_command-1",
                  "name": "run_shell_command",
                  "displayName": "Shell",
                  "args": { "command": "echo hi", "cwd": "/tmp" },
                  "status": "success",
                  "timestamp": "2025-12-16T23:47:03.000Z",
                  "resultDisplay": "Output: hi\\n",
                  "result": [
                    {
                      "functionResponse": {
                        "id": "run_shell_command-1",
                        "name": "run_shell_command",
                        "response": { "output": "Output: hi\\n" }
                      }
                    }
                  ]
                }
              ]
            },
            {
              "id": "m3",
              "timestamp": "2025-12-16T23:47:04.000Z",
              "type": "info",
              "content": "Request cancelled."
            }
          ]
        }
        """
        let url = try writeTemp(json)
        defer { try? FileManager.default.removeItem(at: url) }

        // Full parse: toolCalls become explicit tool events; info becomes meta.
        guard let session = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_call }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .tool_result }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .meta }.count, 1)

        let call = session.events.first(where: { $0.kind == .tool_call })
        XCTAssertEqual(call?.toolName, "Shell")
        XCTAssertTrue((call?.toolInput ?? "").contains("echo hi"))

        let result = session.events.first(where: { $0.kind == .tool_result })
        XCTAssertTrue((result?.toolOutput ?? "").contains("Output: hi"))

        let meta = session.events.first(where: { $0.kind == .meta })
        XCTAssertEqual(meta?.text, "Request cancelled.")

        // Preview parse: toolCalls contribute to eventCount; info does not.
        guard let preview = GeminiSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.eventCount, 3)
        XCTAssertEqual(preview.messageCount, 3)
    }
}
