import XCTest
@testable import AgentSessions

final class SearchLargeSemanticFieldTests: XCTestCase {
    private func scan(_ session: Session, query: String) async throws -> SearchScanResult {
        let tokenizer = try SearchTokenizer()
        let parsedQuery = try SearchQuery(query, tokenizer: tokenizer)
        return await SearchSourceScanner.scan(session: session, query: parsedQuery)
    }

    private func assertScannerFindsSemanticField(_ session: Session, marker: String) async throws {
        let hit = try await scan(session, query: marker)
        XCTAssertTrue(hit.summary.complete, "search coverage must be complete for \(session.source.rawValue)")
        XCTAssertTrue(hit.truth == .yes, "scanner must find \(marker) for \(session.source.rawValue)")

        let omission = try await scan(session, query: "\"OMITTED large JSON payload\"")
        XCTAssertTrue(omission.summary.complete, "the omission-marker query must have complete coverage")
        XCTAssertTrue(omission.truth == .no,
                      "the display-only omission marker must not replace the structured source field")
    }

    func testPiScannerFindsLargeStructuredToolArgumentsSemantically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-search-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("large.jsonl")
        let padding = String(repeating: "x", count: 40_000)
        let lines = [
            #"{"type":"session","version":3,"id":"pi-large-search","timestamp":"2026-05-12T01:00:00.000Z"}"#,
            #"{"type":"message","id":"m1","parentId":"pi-large-search","timestamp":"2026-05-12T01:00:01.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call1","name":"BigTool","arguments":{"semanticMarker":"pimarkersemantic","padding":"\#(padding)"}}]}}"#
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let displaySession = try XCTUnwrap(PiSessionParser.parseFileFull(at: url))
        let displayCall = try XCTUnwrap(displaySession.events.first { $0.kind == .tool_call })
        XCTAssertTrue(displayCall.toolInput?.contains("[OMITTED large JSON payload bytes=") == true)

        try await assertScannerFindsSemanticField(displaySession, marker: "pimarkersemantic")
    }

    func testKimiScannerFindsLargeStructuredToolArgumentsSemantically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-search-large-\(UUID().uuidString)", isDirectory: true)
        let wireURL = directory
            .appendingPathComponent("sessions/wd_test/session-kimi-large/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: wireURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let padding = String(repeating: "y", count: 40_000)
        let lines = [
            #"{"type":"metadata","protocol_version":"1.4","created_at":1784950509920}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"BigTool","args":{"semanticMarker":"kimimarkersemantic","padding":"\#(padding)"},"toolCallId":"kimi-call1","stepUuid":"step1"},"time":1784950509920}"#
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: wireURL, atomically: true, encoding: .utf8)

        let displaySession = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wireURL))
        let displayCall = try XCTUnwrap(displaySession.events.first { $0.kind == .tool_call })
        XCTAssertTrue(displayCall.toolInput?.contains("[OMITTED large JSON payload bytes=") == true)

        try await assertScannerFindsSemanticField(displaySession, marker: "kimimarkersemantic")
    }

    func testGrokScannerFindsLargeStructuredToolArgumentsSemantically() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000031"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-search-large-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("%2Ftmp%2Fas-agent-lab%2Fgrok%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let padding = String(repeating: "z", count: 40_000)
        let transcript = #"{"type":"backend_tool_call","kind":{"tool_type":"web_search","action":{"semanticMarker":"grokmarkersemantic","padding":"\#(padding)"}}}"# + "\n"
        try transcript.write(to: sessionDirectory.appendingPathComponent("chat_history.jsonl"),
                             atomically: true, encoding: .utf8)
        let summary = #"{"info":{"id":"\#(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"},"generated_title":"Large Grok Search"}"#
        try summary.write(to: sessionDirectory.appendingPathComponent("summary.json"),
                          atomically: true, encoding: .utf8)

        let transcriptURL = sessionDirectory.appendingPathComponent("chat_history.jsonl")
        let displaySession = try XCTUnwrap(GrokSessionParser.parseFileFull(at: transcriptURL))
        let displayCall = try XCTUnwrap(displaySession.events.first { $0.kind == .tool_call })
        XCTAssertTrue(displayCall.toolInput?.contains("[OMITTED large JSON payload bytes=") == true)

        try await assertScannerFindsSemanticField(displaySession, marker: "grokmarkersemantic")
    }

    func testQwenScannerFindsLargeStructuredToolArgumentsSemantically() async throws {
        let sessionID = "019f0000-0000-7000-8000-000000000041"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-search-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("\(sessionID).jsonl")
        let padding = String(repeating: "w", count: 40_000)
        let records: [[String: Any]] = [
            [
                "uuid": "qwen-root-user", "parentUuid": NSNull(), "sessionId": sessionID,
                "timestamp": "2026-08-17T12:00:00.000Z", "type": "user", "cwd": "/tmp/qwen-search",
                "version": "0.21.13",
                "message": ["role": "user", "parts": [["text": "Synthetic large tool call."]]],
                "systemPayload": ["displayText": "Synthetic large tool call."]
            ],
            [
                "uuid": "qwen-large-call", "parentUuid": "qwen-root-user", "sessionId": sessionID,
                "timestamp": "2026-08-17T12:00:01.000Z", "type": "assistant", "cwd": "/tmp/qwen-search",
                "version": "0.21.13",
                "message": [
                    "role": "model",
                    "parts": [[
                        "functionCall": [
                            "id": "qwen-call1", "name": "BigTool",
                            "args": ["semanticMarker": "qwenmarkersemantic", "padding": padding]
                        ]
                    ]]
                ]
            ]
        ]
        let data = try records.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) + Data([10]) }
            .reduce(into: Data()) { $0.append($1) }
        try data.write(to: url)

        let displaySession = try XCTUnwrap(QwenSessionParser.parseFileFull(at: url))
        let displayCall = try XCTUnwrap(displaySession.events.first { $0.kind == .tool_call })
        XCTAssertTrue(displayCall.toolInput?.contains("[OMITTED large JSON payload bytes=") == true)

        try await assertScannerFindsSemanticField(displaySession, marker: "qwenmarkersemantic")
    }
}
