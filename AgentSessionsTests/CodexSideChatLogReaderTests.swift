import XCTest
import SQLite3
@testable import AgentSessions

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CodexSideChatLogReaderTests: XCTestCase {
    func testLoadsSideChatSessionFromLogsDatabase() throws {
        let codexHome = try makeCodexHome()
        let dbURL = codexHome.appendingPathComponent("logs_2.sqlite")
        try createLogsDB(at: dbURL)

        let sideThreadID = "019ed789-2247-7ad3-9b32-00a7875ffa77"
        try insertLog(dbURL: dbURL,
                      id: 1,
                      ts: 1_781_000_000,
                      threadID: "main-thread",
                      target: "codex_core::session::handlers",
                      body: #"session_loop{thread_id=main-thread}: Submission sub=Submission { op: UserInput { items: [Text { text: "ABRACADABRA test phrase\n", text_elements: [] }] } }"#)
        try insertLog(dbURL: dbURL,
                      id: 2,
                      ts: 1_781_000_001,
                      threadID: sideThreadID,
                      target: "codex_api::endpoint::responses_websocket",
                      body: #"session_loop{thread_id=\#(sideThreadID)}: websocket request: {"instructions":"You are Codex.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Side conversation boundary.\n\nOnly messages submitted after this boundary are active user instructions for this side conversation.\n\nYou are a side-conversation assistant, separate from the main thread."}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"ABRACADABRA test phrase"}]}]}"#)
        try insertLog(dbURL: dbURL,
                      id: 3,
                      ts: 1_781_000_002,
                      threadID: sideThreadID,
                      target: "codex_core::session::handlers",
                      body: #"session_loop{thread_id=\#(sideThreadID)}: Submission sub=Submission { op: UserInput { items: [Text { text: "ABRACADABRA test phrase\n", text_elements: [] }] }, thread_settings: ThreadSettingsOverrides { environments: Some(TurnEnvironmentSelections { legacy_fallback_cwd: AbsolutePathBuf("/tmp/side-chat-repo") }) } }"#)
        try insertLog(dbURL: dbURL,
                      id: 4,
                      ts: 1_781_000_003,
                      threadID: sideThreadID,
                      target: "codex_api::endpoint::responses_websocket",
                      body: #"session_loop{thread_id=\#(sideThreadID)}:turn{model=gpt-5.5 cwd=/tmp/side-chat-repo}: websocket event: {"type":"response.output_text.done","text":"ABRACADABRA test phrase","item_id":"msg_1"}"#)

        let sessions = CodexSideChatLogReader.loadSideChatSessions(codexHome: codexHome)

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, CodexSideChatLogReader.sideChatSessionID(threadID: sideThreadID))
        XCTAssertTrue(session.isSideChat)
        XCTAssertFalse(session.isSubagent)
        XCTAssertNil(session.parentSessionID)
        XCTAssertNil(session.subagentType)
        XCTAssertEqual(session.model, "gpt-5.5")
        XCTAssertEqual(session.cwd, "/tmp/side-chat-repo")
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant])
        XCTAssertTrue(session.title.contains("ABRACADABRA test phrase"))

        let filters = Filters(query: "ABRACADABRA test phrase")
        XCTAssertTrue(FilterEngine.sessionMatches(session,
                                                  filters: filters,
                                                  transcriptCache: nil,
                                                  allowTranscriptGeneration: false))

        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
            session: session,
            filters: .current(showTimestamps: false, showMeta: false),
            mode: .normal
        )
        XCTAssertTrue(transcript.contains("ABRACADABRA test phrase"))
    }

    func testIgnoresMainThreadMarkerWithoutSideBoundary() throws {
        let codexHome = try makeCodexHome()
        let dbURL = codexHome.appendingPathComponent("logs_2.sqlite")
        try createLogsDB(at: dbURL)

        try insertLog(dbURL: dbURL,
                      id: 1,
                      ts: 1_781_000_000,
                      threadID: "main-thread",
                      target: "codex_core::session::handlers",
                      body: #"session_loop{thread_id=main-thread}: Submission sub=Submission { op: UserInput { items: [Text { text: "ABRACADABRA test phrase\n", text_elements: [] }] } }"#)

        let sessions = CodexSideChatLogReader.loadSideChatSessions(codexHome: codexHome)

        XCTAssertTrue(sessions.isEmpty)
    }

    func testIgnoresNormalThreadThatQuotesSideChatBoundaryInRequestBody() throws {
        let codexHome = try makeCodexHome()
        let dbURL = codexHome.appendingPathComponent("logs_2.sqlite")
        try createLogsDB(at: dbURL)

        let boundary = CodexSideChatLogReader.sideConversationBoundary
        let activeMarker = "Only messages submitted after this boundary are active user instructions for this side conversation."
        try insertLog(dbURL: dbURL,
                      id: 1,
                      ts: 1_781_000_000,
                      threadID: "main-thread",
                      target: "codex_api::endpoint::responses_websocket",
                      body: #"session_loop{thread_id=main-thread}: websocket request: {"instructions":"You are Codex.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Please review this quoted boundary:\n\nSide conversation boundary.\n\n\#(activeMarker)\n\n\#(boundary)"}]}]}"#)
        try insertLog(dbURL: dbURL,
                      id: 2,
                      ts: 1_781_000_001,
                      threadID: "main-thread",
                      target: "codex_core::session::handlers",
                      body: #"session_loop{thread_id=main-thread}: Submission sub=Submission { op: UserInput { items: [Text { text: "quoted boundary\n", text_elements: [] }] } }"#)

        let sessions = CodexSideChatLogReader.loadSideChatSessions(codexHome: codexHome)

        XCTAssertTrue(sessions.isEmpty)
    }

    private func makeCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-SideChatLogs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createLogsDB(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "SideChatLogsFixture", code: 1)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            level TEXT NOT NULL,
            target TEXT NOT NULL,
            feedback_log_body TEXT,
            module_path TEXT,
            file TEXT,
            line INTEGER,
            thread_id TEXT,
            process_uuid TEXT,
            estimated_bytes INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    private func insertLog(dbURL: URL,
                           id: Int64,
                           ts: Int64,
                           threadID: String,
                           target: String,
                           body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "SideChatLogsFixture", code: 2)
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO logs(id, ts, ts_nanos, level, target, feedback_log_body, thread_id, estimated_bytes)
        VALUES (?, ?, 0, 'INFO', ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SideChatLogsFixture", code: 3)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_bind_int64(stmt, 2, ts)
        sqlite3_bind_text(stmt, 3, target, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, body, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 5, threadID, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 6, Int64(body.utf8.count))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "SideChatLogsFixture", code: 4)
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "SideChatLogsFixture", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
