import XCTest
import SQLite3
@testable import AgentSessions

/// Search must retain large structured tool fields that display parsing trims.
final class SearchClineDevinSemanticTests: XCTestCase {
    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func session(_ source: SessionSource, id: String, path: URL) -> Session {
        Session(id: id, source: source, startTime: nil, endTime: nil, model: nil,
                filePath: path.path, fileSizeBytes: 0, eventCount: 0, events: [],
                cwd: nil, repoName: nil, lightweightTitle: nil)
    }

    private func scan(_ session: Session, query: String) async throws -> SearchScanResult {
        let tokenizer = try SearchTokenizer()
        return await SearchSourceScanner.scan(
            session: session,
            query: try SearchQuery(query, tokenizer: tokenizer))
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "SearchClineDevinSemanticFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "SearchClineDevinSemanticFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func sql(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func testClineSearchKeepsLargeStructuredToolInputAndResult() async throws {
        let directory = try makeDirectory("search-cline-large-json")
        let manifestURL = directory.appendingPathComponent("cline.json")
        let messagesURL = directory.appendingPathComponent("cline.messages.json")
        let input = ["payload": String(repeating: "x", count: 36_000) + " clineinputneedle"]
        let output = ["payload": String(repeating: "y", count: 36_000) + " clineresultneedle"]
        let manifest: [String: Any] = [
            "version": 1,
            "session_id": "cline-large-json",
            "source": "cli",
            "started_at": "2026-11-11T12:00:00Z"
        ]
        let messages: [String: Any] = [
            "version": 1,
            "sessionId": "cline-large-json",
            "messages": [[
                "role": "assistant",
                "id": "message-1",
                "ts": 1_794_384_000_000,
                "content": [
                    ["type": "tool_use", "id": "call-1", "name": "write_file", "input": input],
                    ["type": "tool_result", "tool_use_id": "call-1", "name": "write_file", "content": output]
                ]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys]).write(to: messagesURL)

        let display = try XCTUnwrap(ClineSessionParser.parseFileFull(at: manifestURL))
        XCTAssertTrue(display.events[0].toolInput?.hasPrefix("[OMITTED large JSON payload bytes=") == true)
        XCTAssertTrue(display.events[1].toolOutput?.hasPrefix("[OMITTED large JSON payload bytes=") == true)

        let search = try XCTUnwrap(ClineSessionParser.parseFileFull(at: manifestURL, forSearch: true))
        XCTAssertTrue(search.events[0].toolInput?.contains("clineinputneedle") == true)
        XCTAssertTrue(search.events[1].toolOutput?.contains("clineresultneedle") == true)

        let selected = session(.cline, id: "cline-large-json", path: manifestURL)
        let inputHit = try await scan(selected, query: "clineinputneedle")
        XCTAssertEqual(inputHit.truth, .yes)
        XCTAssertTrue(inputHit.summary.complete)
        let outputHit = try await scan(selected, query: "clineresultneedle")
        XCTAssertEqual(outputHit.truth, .yes)
        XCTAssertTrue(outputHit.summary.complete)
    }

    func testDevinSearchKeepsLargeStructuredToolArguments() async throws {
        let directory = try makeDirectory("search-devin-large-json")
        let databaseURL = directory.appendingPathComponent("sessions.db")
        let sessionID = "devin-large-json"
        let arguments: [String: Any] = [
            "payload": String(repeating: "z", count: 36_000) + " devinargumentneedle"
        ]
        let chatMessage = try json([
            "message_id": "assistant-1",
            "role": "assistant",
            "content": "done",
            "tool_calls": [[
                "id": "call-1", "index": 0, "kind": "function",
                "name": "write_file", "arguments": arguments
            ]]
        ])
        try execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, main_chain_id INTEGER);
            CREATE TABLE message_nodes (session_id TEXT, node_id INTEGER, parent_node_id INTEGER,
                chat_message TEXT, created_at INTEGER);
            INSERT INTO sessions VALUES ('\(sessionID)', 1);
            INSERT INTO message_nodes VALUES ('\(sessionID)', 1, NULL, \(sql(chatMessage)), 1780000000);
            """, at: databaseURL)

        let display = DevinSessionParser.events(fromChatMessage: chatMessage, nodeID: 1, time: nil)
        XCTAssertTrue(display.last?.toolInput?.hasPrefix("[OMITTED large JSON payload bytes=") == true)
        let search = DevinSessionParser.events(fromChatMessage: chatMessage, nodeID: 1,
                                               time: nil, forSearch: true)
        XCTAssertTrue(search.last?.toolInput?.contains("devinargumentneedle") == true)

        let selected = session(.devin, id: sessionID, path: databaseURL)
        let result = try await scan(selected, query: "devinargumentneedle")
        XCTAssertEqual(result.truth, .yes)
        XCTAssertTrue(result.summary.complete)
    }
}
