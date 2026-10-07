import XCTest
import SQLite3
import Combine
@testable import AgentSessions

private final class SearchCoordinatorTestStore: SearchSessionStoring {
    private(set) var parseFullCallCount = 0

    func transcriptCache(for source: SessionSource) -> TranscriptCache? {
        nil
    }

    func updateSession(_ session: Session) {}

    func parseFull(session: Session) async -> Session? {
        parseFullCallCount += 1
        return session
    }
}

final class SessionParserTests: XCTestCase {
    func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "jsonl")!
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    @discardableResult
    private func withProcessEnvironment<T>(
        _ updates: [String: String?],
        _ body: () throws -> T
    ) rethrows -> T {
        let original = ProcessInfo.processInfo.environment
        for (key, value) in updates {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        defer {
            for (key, _) in updates {
                if let value = original[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        return try body()
    }

    private func createCodexStateSQLiteFixture(at url: URL, includeGitColumns: Bool) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open Codex state SQLite fixture")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(err)
                throw NSError(domain: "CodexStateSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        let gitColumns = includeGitColumns ? ", git_branch TEXT, git_origin_url TEXT" : ""
        let gitInsertColumns = includeGitColumns ? ", git_branch, git_origin_url" : ""
        let gitValues = includeGitColumns ? ", 'feature/state-git', 'https://example.test/acme/widgets.git'" : ""
        try exec("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            first_user_message TEXT NOT NULL\(gitColumns)
        );
        INSERT INTO threads (id, rollout_path, cwd, title, first_user_message\(gitInsertColumns))
        VALUES ('thread-state', '/tmp/rollout-state.jsonl', '/tmp/state-worktree', '', 'State title fallback'\(gitValues));
        """)
    }

    private func makeCodexHierarchySession(
        id: String,
        runtimeID: String,
        timestamp: String,
        cwd: String,
        parentSessionID: String? = nil,
        subagentType: String? = nil,
        relationshipKind: SessionRelationshipKind? = nil,
        events: [SessionEvent] = []
    ) -> Session {
        Session(
            id: id,
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/rollout-\(timestamp)-\(runtimeID).jsonl",
            eventCount: events.count,
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: id,
            codexInternalSessionIDHint: runtimeID,
            parentSessionID: parentSessionID,
            subagentType: subagentType,
            relationshipKind: relationshipKind
        )
    }

    /// Minimal metadata-only session for exercising `SearchCoordinator`'s allowed-source
    /// gating without depending on transcript text or a warmed FTS database.
    private func makeRepoSession(id: String, source: SessionSource, repoName: String) -> Session {
        Session(
            id: id,
            source: source,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/\(source.rawValue)/\(id).jsonl",
            eventCount: 0,
            events: [],
            cwd: "/tmp/repo",
            repoName: repoName,
            lightweightTitle: id
        )
    }

    private func createOpenCodeSQLiteFixture(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open SQLite fixture")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(err)
                throw NSError(domain: "OpenCodeSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        func sqlString(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        try exec("""
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            parent_id TEXT,
            slug TEXT NOT NULL,
            directory TEXT NOT NULL,
            title TEXT NOT NULL,
            version TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            time_archived INTEGER
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        """)

        try exec("""
        INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
        VALUES ('ses_sqlite_demo', 'proj_sqlite', NULL, 'sqlite-demo', '/tmp/repo', 'SQLite demo', '1.4.6', 1776370000000, 1776370002000, NULL);
        """)

        let userMessage = #"{"role":"user","time":{"created":1776370000010},"agent":"build","model":{"providerID":"opencode","modelID":"big-pickle"},"summary":{"diffs":[]}}"#
        let assistantMessage = #"{"parentID":"msg_user_sqlite","role":"assistant","mode":"build","agent":"build","path":{"cwd":"/tmp/repo","root":"/tmp/repo"},"cost":0,"tokens":{"total":10},"modelID":"big-pickle","providerID":"opencode"}"#
        try exec("""
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_user_sqlite', 'ses_sqlite_demo', 1776370000010, 1776370000010, \(sqlString(userMessage)));
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_assistant_sqlite', 'ses_sqlite_demo', 1776370001000, 1776370002000, \(sqlString(assistantMessage)));
        """)

        let userText = #"{"type":"text","text":"Hello from SQLite","time":{"start":1776370000010,"end":1776370000010}}"#
        let assistantText = #"{"type":"text","text":"SQLite response","time":{"start":1776370001000,"end":1776370001000}}"#
        let toolPart = #"{"type":"tool","tool":"grep","callID":"call_sqlite_1","state":{"status":"completed","input":{"pattern":"SQLite"},"output":"Found 1 match","time":{"start":1776370001100,"end":1776370001200}}}"#
        try exec("""
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('prt_user_text_sqlite', 'msg_user_sqlite', 'ses_sqlite_demo', 1776370000010, 1776370000010, \(sqlString(userText)));
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('prt_assistant_text_sqlite', 'msg_assistant_sqlite', 'ses_sqlite_demo', 1776370001000, 1776370001000, \(sqlString(assistantText)));
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('prt_tool_sqlite', 'msg_assistant_sqlite', 'ses_sqlite_demo', 1776370001100, 1776370001200, \(sqlString(toolPart)));
        """)
    }

    private func createOpenClawSQLiteFixture(at url: URL, compressed: Bool = false) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open OpenClaw SQLite fixture")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(err)
                throw NSError(domain: "OpenClawSQLiteFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        func sqlString(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        let compressedColumns = compressed ? ", event_zstd BLOB, event_utf8_bytes INTEGER" : ""
        try exec("""
        CREATE TABLE session_windows (
            session_id TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            started_at INTEGER,
            ended_at INTEGER,
            model TEXT,
            display_name TEXT
        );
        CREATE TABLE transcript_events (
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            event_json TEXT,
            created_at INTEGER NOT NULL\(compressedColumns),
            PRIMARY KEY (session_id, seq)
        );
        CREATE TABLE transcript_event_identities (
            session_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            event_id TEXT,
            PRIMARY KEY (session_id, seq)
        );
        INSERT INTO session_windows
            (session_id, created_at, updated_at, started_at, ended_at, model, display_name)
        VALUES
            ('sqlite-demo', 1776370000000, 1776370004000, 1776370000000, 1776370004000,
             'metadata-model', 'OpenClaw SQLite demo');
        """)

        let header = #"{"type":"session","version":3,"id":"sqlite-demo","timestamp":"2026-04-16T00:00:00.000Z","cwd":"/tmp/openclaw"}"#
        let user = #"{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"OpenClaw SQLite fixture"}]}}"#
        let assistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"record-model","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"content":[{"type":"text","text":"fixture response"}]}}"#
        let modelChange = #"{"type":"model_change","modelId":"record-model","timestamp":"2026-04-16T00:00:03.000Z"}"#
        let records = [header, user, assistant, modelChange]
        for (offset, record) in records.enumerated() {
            let sequence = offset + 1
            let eventID = "event-\(sequence)"
            let timestamp = 1776370000000 + (Int64(sequence) * 1000)
            let jsonValue: String
            if compressed && sequence == 3 {
                jsonValue = "NULL"
            } else {
                jsonValue = sqlString(record)
            }
            let compressedValue = compressed && sequence == 3 ? ", X'789c01', 0" : (compressed ? ", NULL, \(record.utf8.count)" : "")
            try exec("""
            INSERT INTO transcript_events
                (session_id, seq, event_json, created_at\(compressed ? ", event_zstd, event_utf8_bytes" : ""))
            VALUES ('sqlite-demo', \(sequence), \(jsonValue), \(timestamp)\(compressedValue));
            INSERT INTO transcript_event_identities (session_id, seq, event_id)
            VALUES ('sqlite-demo', \(sequence), \(sqlString(eventID)));
            """)
        }
    }

    private func executeSQLite(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open SQLite fixture")
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "SQLiteFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func waitForOpenClawIndexerQuiescence(
        _ indexer: OpenClawSessionIndexer,
        timeout: TimeInterval = 20
    ) {
        let exp = expectation(description: "OpenClaw indexer quiescent")
        var idleTicks = 0
        func poll() {
            if indexer.isIndexing {
                idleTicks = 0
            } else {
                idleTicks += 1
                if idleTicks >= 10 {
                    exp.fulfill()
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [exp], timeout: timeout)
    }

    @MainActor
    private func withIsolatedIndexerStore<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-IndexerDB-\(UUID().uuidString)",
            isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        IndexDBTestHooks.applicationSupportDirectoryProvider = { root }
        let enablementKey = AgentEnablement.enablementKey(for: .openclaw)
        let previousEnablement = UserDefaults.standard.object(forKey: enablementKey)
        UserDefaults.standard.set(true, forKey: enablementKey)
        defer {
            if let previousEnablement {
                UserDefaults.standard.set(previousEnablement, forKey: enablementKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enablementKey)
            }
            IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider
            try? fm.removeItem(at: root)
        }
        return try body()
    }

    private func createHermesStateDBFixture(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open Hermes state SQLite fixture")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown sqlite error"
                sqlite3_free(err)
                throw NSError(domain: "HermesStateSQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        func sqlString(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

        try exec("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT,
            user_id TEXT,
            model TEXT,
            model_config TEXT,
            system_prompt TEXT,
            parent_session_id TEXT,
            started_at REAL,
            ended_at REAL,
            end_reason TEXT,
            message_count INTEGER,
            tool_call_count INTEGER,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            total_tokens INTEGER,
            cost REAL,
            title TEXT,
            last_activity_at REAL
        );
        CREATE TABLE session_model_usage (
            session_id TEXT NOT NULL,
            model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '',
            billing_base_url TEXT NOT NULL DEFAULT '',
            billing_mode TEXT NOT NULL DEFAULT '',
            task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0,
            actual_cost_usd REAL NOT NULL DEFAULT 0,
            cost_status TEXT,
            cost_source TEXT,
            first_seen REAL,
            last_seen REAL
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT,
            content TEXT,
            tool_call_id TEXT,
            tool_calls TEXT,
            tool_name TEXT,
            timestamp REAL,
            token_count INTEGER,
            finish_reason TEXT,
            reasoning TEXT,
            reasoning_content TEXT,
            reasoning_details TEXT,
            codex_reasoning_items TEXT,
            codex_message_items TEXT,
            platform_message_id TEXT,
            observed INTEGER
        );
        """)

        let modelConfig = #"{"cwd":"/tmp/hermes-repo","reasoning_config":{"effort":"high"}}"#
        let toolCalls = #"[{"id":"call_hermes_1","type":"function","function":{"name":"shell","arguments":"{\"cmd\":\"pwd\"}"}}]"#
        try exec("""
        INSERT INTO sessions (id, source, user_id, model, model_config, system_prompt, parent_session_id, started_at, ended_at, end_reason, message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, cost, title, last_activity_at)
        VALUES ('hermes_sqlite_demo', 'cli', 'user_1', 'qwen3.5-9b', \(sqlString(modelConfig)), 'system', NULL, 1780000000.0, 1780000004.0, 'complete', 3, 1, 10, 20, 0, 0, 2, 30, 0.01, 'Hermes SQLite demo', 1780000003.5);
        INSERT INTO session_model_usage (session_id, model, task, api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES ('hermes_sqlite_demo', 'qwen3.5-9b', '', 1, 10, 20, 0, 0, 2, 1780000000.1, 1780000003.5);
        INSERT INTO session_model_usage (session_id, model, task, api_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES ('hermes_sqlite_demo', 'qwen3.5-9b', 'title_generation', 1, 999, 999, 0, 0, 0, 1780000000.0, 1780000000.0);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (1, 'hermes_sqlite_demo', 'user', 'Hello from Hermes SQLite', NULL, NULL, NULL, 1780000000.1, 4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (2, 'hermes_sqlite_demo', 'assistant', 'Running pwd.', NULL, \(sqlString(toolCalls)), NULL, 1780000001.0, 8, NULL, 'brief reasoning', NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (3, 'hermes_sqlite_demo', 'tool', '/tmp/hermes-repo', 'call_hermes_1', NULL, 'shell', 1780000002.0, 3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (4, 'hermes_sqlite_demo', 'session_meta', NULL, NULL, NULL, NULL, 1780000003.0, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (5, 'hermes_sqlite_demo', 'tool', '{"results": [{"task_index": 0, "status": "completed", "summary": "{\\"passed\\":true}", "api_calls": 4, "duration_seconds": 23.2}]}', 'call_hermes_2', NULL, '', 1780000003.5, 3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        """)
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func testJSONLStreamingAndDecoding() throws {
        let url = fixtureURL("session_simple")
        let reader = JSONLReader(url: url)
        let lines = try reader.readLines()
        XCTAssertEqual(lines.count, 2)
        let e1 = SessionIndexer.parseLine(lines[0], eventID: "e-1").0
        XCTAssertEqual(e1.kind, .user)
        XCTAssertEqual(e1.role, "user")
        XCTAssertEqual(e1.text, "What's the weather like in SF today?")
        XCTAssertNotNil(e1.timestamp)
        XCTAssertFalse(e1.rawJSON.isEmpty)
    }

    func testBuildsSessionMetadata() throws {
        let url = fixtureURL("session_toolcall")
        let indexer = SessionIndexer()
        let session = indexer.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }
        XCTAssertEqual(s.eventCount, 4)
        XCTAssertEqual(s.model, "gpt-4o-mini")
        XCTAssertNotNil(s.startTime)
        XCTAssertNotNil(s.endTime)
        XCTAssertLessThan((s.startTime ?? .distantPast), (s.endTime ?? .distantFuture))
    }

    func testSearchAndFilters() throws {
        // Build two sample sessions from fixtures
        let idx = SessionIndexer()
        let s1 = idx.parseFileFull(at: fixtureURL("session_simple"))!
        let s2 = idx.parseFileFull(at: fixtureURL("session_toolcall"))!
        let all = [s1, s2]
        // Query should match assistant text in s1
        var filters = Filters(query: "sunny", dateFrom: nil, dateTo: nil, model: nil, kinds: Set(SessionEventKind.allCases))
        var filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s1.id)

        // Filter by model
        filters = Filters(query: "", dateFrom: nil, dateTo: nil, model: "gpt-4o-mini", kinds: Set(SessionEventKind.allCases))
        filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s2.id)

        // Filter kinds (only tool_result)
        filters = Filters(query: "hola", dateFrom: nil, dateTo: nil, model: nil, kinds: [.tool_result])
        filtered = FilterEngine.filterSessions(all, filters: filters)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.id, s2.id)
    }

    func testSideChatFilterOnlyShowsSideChats() throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-00-00",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat
        )

        let filtered = FilterEngine.filterSessions(
            [root, sideChat],
            filters: Filters(sideChatsOnly: true),
            allowTranscriptGeneration: false
        )

        XCTAssertEqual(filtered.map(\.id), ["side-chat"])
    }

    func testSideSearchTagOnlyShowsSideChatsWithoutSearchingSideText() throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-00-00",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat
        )

        let filtered = FilterEngine.filterSessions(
            [root, sideChat],
            filters: Filters(query: "#side"),
            allowTranscriptGeneration: false
        )

        XCTAssertEqual(filtered.map(\.id), ["side-chat"])
        XCTAssertEqual(FilterEngine.parseOperators("#side").freeText, "")
    }

    func testSideSearchTagIgnoresArchivedCodexDesktopFilter() throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-00-00",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat
        )

        let filtered = FilterEngine.filterSessions(
            [root, sideChat],
            filters: Filters(query: "#side", archivedCodexDesktopOnly: true),
            allowTranscriptGeneration: false
        )

        XCTAssertEqual(filtered.map(\.id), ["side-chat"])
    }

    func testSearchCoordinatorSideTagOnlyUsesMetadataPath() async throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-00-00",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat
        )
        let store = SearchCoordinatorTestStore()
        let coordinator = SearchCoordinator(store: store)

        coordinator.start(query: "#side",
                          filters: Filters(query: "#side"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: [root, sideChat])

        try await waitForSearchResults(coordinator, expectedIDs: ["side-chat"])
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(store.parseFullCallCount, 0)
    }

    func testSearchCoordinatorSideTagIgnoresArchivedCodexDesktopFilter() async throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-00-00",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat
        )
        let store = SearchCoordinatorTestStore()
        let coordinator = SearchCoordinator(store: store)

        coordinator.start(query: "#side",
                          filters: Filters(query: "#side", archivedCodexDesktopOnly: true),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: [root, sideChat])

        try await waitForSearchResults(coordinator, expectedIDs: ["side-chat"])
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(store.parseFullCallCount, 0)
    }

    /// Regression: `SearchCoordinator.start` grew one `include<Provider>` parameter per
    /// source by hand, and Kimi was never added when it shipped as the 11th source. `.kimi`
    /// therefore never entered the allowed-source set, so Kimi sessions were silently absent
    /// from every search result while still appearing in the unfiltered list.
    ///
    /// The twelve Bools are now a single `allowed: Set<SessionSource>`, which is what makes
    /// that class of omission unrepresentable: a source is gated by being absent from the
    /// set, never by a parameter nobody remembered to pass. The assertions are unchanged —
    /// Kimi in the set means Kimi sessions come back; Kimi subtracted from it means they
    /// do not, without disturbing the sources that stayed in.
    func testSearchCoordinatorIncludeKimiGatesKimiSessions() async throws {
        let kimi = makeRepoSession(id: "kimi-session", source: .kimi, repoName: "kimirepo")
        let codex = makeRepoSession(id: "codex-session", source: .codex, repoName: "kimirepo")

        let included = SearchCoordinator(store: SearchCoordinatorTestStore())
        included.start(query: "repo:kimirepo",
                       filters: Filters(query: "repo:kimirepo"),
                       allowed: Set(SessionSource.allCases),
                       enableDeepScan: false,
                       all: [kimi])

        try await waitForSearchResults(included, expectedIDs: ["kimi-session"])

        // And the gate still excludes Kimi when the caller opts out, without disturbing
        // the sources that are opted in.
        let excluded = SearchCoordinator(store: SearchCoordinatorTestStore())
        excluded.start(query: "repo:kimirepo",
                       filters: Filters(query: "repo:kimirepo"),
                       allowed: Set(SessionSource.allCases).subtracting([.kimi]),
                       enableDeepScan: false,
                       all: [kimi, codex])

        try await waitForSearchResults(excluded, expectedIDs: ["codex-session"])
    }

    func testSearchCoordinatorScansPastStaleIdentityFTSHit() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let path = "/tmp/opencode.db"
        let session = Session(
            id: "shared-db-session",
            source: .opencode,
            startTime: Date(timeIntervalSince1970: 1_900),
            endTime: Date(timeIntervalSince1970: 2_000),
            model: nil,
            filePath: path,
            fileSizeBytes: nil,
            eventCount: 1,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Shared DB session"
        )
        let currentSession = Session(
            id: "current-shared-db-session",
            source: .opencode,
            startTime: Date(timeIntervalSince1970: 2_100),
            endTime: Date(timeIntervalSince1970: 2_200),
            model: nil,
            filePath: path,
            fileSizeBytes: nil,
            eventCount: 1,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Current shared DB session"
        )

        try await db.begin()
        try await db.upsertFile(path: path, mtime: 10, size: 20, source: "opencode")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: session.id, source: "opencode", path: path, mtime: 10, size: 20,
            startTS: 1_900, endTS: 2_000, model: nil, cwd: "/tmp/repo", repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        try await db.upsertSessionSearch(sessionID: session.id, source: "opencode",
                                         mtime: 1, size: 1, text: "staleonly")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: currentSession.id, source: "opencode", path: path, mtime: 10, size: 20,
            startTS: 2_100, endTS: 2_200, model: nil, cwd: "/tmp/repo", repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        let currentRevision = SearchIngestService.contentRevision(for: currentSession)
        try await db.upsertSessionSearch(sessionID: currentSession.id, source: "opencode",
                                         mtime: currentRevision.updatedMillis,
                                         size: currentRevision.extent,
                                         text: "staleonly " + String(repeating: "filler ", count: 200))
        try await db.commit()

        // Hydration changes the rendered event count, but not the provider's logical
        // message-count revision. Search must keep the current FTS row eligible.
        let hydratedCurrentSession = Session(
            id: currentSession.id,
            source: currentSession.source,
            startTime: currentSession.startTime,
            endTime: currentSession.endTime,
            model: currentSession.model,
            filePath: currentSession.filePath,
            fileSizeBytes: currentSession.fileSizeBytes,
            eventCount: 2,
            events: [SessionEvent(id: "hydrated-event", timestamp: currentSession.endTime,
                                  kind: .assistant, role: "assistant", text: "hydrated",
                                  toolName: nil, toolInput: nil, toolOutput: nil,
                                  messageID: "message", parentID: nil, isDelta: false,
                                  rawJSON: "{}")],
            cwd: currentSession.cwd,
            repoName: currentSession.repoName,
            lightweightTitle: currentSession.lightweightTitle
        )

        let firstPage = try await db.searchSessionIDsFTS(
            sources: ["opencode"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "staleonly", includeSystemProbes: true,
            limit: 1
        )
        XCTAssertEqual(firstPage, [session.id], "fixture must put the stale row ahead of the current hit")

        let store = SearchCoordinatorTestStore()
        let coordinator = SearchCoordinator(store: store, db: db, ftsResultLimitForTesting: 1)
        coordinator.start(query: "staleonly",
                          filters: Filters(query: "staleonly"),
                          allowed: [.opencode],
                          enableDeepScan: false,
                          all: [session, hydratedCurrentSession])

        try await waitForSearchResults(coordinator, expectedIDs: [currentSession.id])
        XCTAssertFalse(coordinator.results.contains(where: { $0.id == session.id }),
                       "stale FTS text must never publish")
    }

    func testSearchCoordinatorDoesNotTrustByteCurrentPreviousFormatText() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let path = "/tmp/previous-format.jsonl"
        let session = Session(
            id: "previous-format",
            source: .claude,
            startTime: Date(timeIntervalSince1970: 1_900),
            endTime: Date(timeIntervalSince1970: 2_000),
            model: nil,
            filePath: path,
            fileSizeBytes: 42,
            eventCount: 1,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Generated current title"
        )

        try await db.begin()
        try await db.upsertFile(path: path, mtime: 7, size: 42, source: "claude")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: session.id, source: "claude", path: path, mtime: 7, size: 42,
            startTS: 1_900, endTS: 2_000, model: nil, cwd: session.cwd, repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        // The byte revision is current, but the v4 corpus predates the current
        // parser/title semantics. It must take the fresh parse path rather than
        // being treated as authoritative solely because its file stat matches.
        try await db.upsertSessionSearch(sessionID: session.id, source: "claude",
                                         mtime: 7, size: 42,
                                         text: "obsolete title",
                                         formatVersion: 4)
        try await db.commit()

        let store = SearchCoordinatorTestStore()
        let coordinator = SearchCoordinator(store: store, db: db)
        coordinator.start(query: "generated",
                          filters: Filters(query: "generated"),
                          allowed: [.claude],
                          enableDeepScan: false,
                          all: [session])

        try await waitForSearchResults(coordinator, expectedIDs: [session.id])
        XCTAssertEqual(store.parseFullCallCount, 1,
                       "a previous format is not proof of current parser semantics")
    }

    func testSearchCoordinatorTreatsSameRevisionAtDifferentIdentityPathAsUnindexed() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let livePath = "/tmp/live/opencode.db"
        let archivePath = "/tmp/archive/opencode.db"
        let endTime = Date(timeIntervalSince1970: 2_000)
        let session = Session(
            id: "moved-shared-db-session",
            source: .opencode,
            startTime: Date(timeIntervalSince1970: 1_900),
            endTime: endTime,
            model: nil,
            filePath: archivePath,
            fileSizeBytes: nil,
            eventCount: 1,
            events: [
                SessionEvent(id: "fresh-archive-event", timestamp: endTime,
                             kind: .assistant, role: "assistant",
                             text: "fresh archive marker", toolName: nil,
                             toolInput: nil, toolOutput: nil, messageID: "message",
                             parentID: nil, isDelta: false, rawJSON: "{}")
            ],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Moved shared DB session"
        )
        let revision = SearchIngestService.contentRevision(for: session)

        try await db.begin()
        try await db.upsertFile(path: livePath, mtime: revision.updatedMillis,
                                size: revision.extent, source: "opencode")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: session.id, source: "opencode", path: livePath,
            mtime: revision.updatedMillis, size: revision.extent,
            startTS: 1_900, endTS: 2_000, model: nil, cwd: "/tmp/repo", repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        try await db.upsertSessionSearch(sessionID: session.id, source: "opencode",
                                         mtime: revision.updatedMillis,
                                         size: revision.extent,
                                         text: "old live marker")
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "fresh archive marker",
                          filters: Filters(query: "fresh archive marker"),
                          allowed: [.opencode],
                          enableDeepScan: false,
                          all: [session])

        try await waitForSearchResults(coordinator, expectedIDs: [session.id])
    }

    func testSearchCoordinatorToolCapacityExcludesOrdinaryDuplicatesBeforeLimit() async throws {
        let defaults = UserDefaults.standard
        let key = PreferencesKey.Advanced.enableRecentToolIOIndex
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let ordinaryAndTool = makeRepoSession(id: "a-ordinary-and-tool", source: .codex, repoName: "repo")
        let toolOnly = makeRepoSession(id: "b-tool-only", source: .codex, repoName: "repo")

        try await db.begin()
        for session in [ordinaryAndTool, toolOnly] {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "codex")
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: "codex", path: session.filePath, mtime: 10, size: 20,
                startTS: 1, endTS: 2, model: nil, cwd: "/tmp/repo", repo: "repo",
                title: nil, codexInternalSessionID: nil, isHousekeeping: false,
                messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            try await db.upsertSessionSearch(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20,
                                             text: session.id == ordinaryAndTool.id ? "dualmatch" : "ordinary-only")
            try await db.upsertSessionToolIO(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20, refTS: 2,
                                             text: "dualmatch")
        }
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(),
                                            db: db,
                                            ftsResultLimitForTesting: 2)
        coordinator.start(query: "dualmatch",
                          filters: Filters(query: "dualmatch"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: [ordinaryAndTool, toolOnly])

        try await waitForSearchResults(coordinator,
                                       expectedIDs: [ordinaryAndTool.id, toolOnly.id])
    }

    func testSearchCoordinatorTitleHitDoesNotExcludeItsRankedToolHit() async throws {
        let defaults = UserDefaults.standard
        let key = PreferencesKey.Advanced.enableRecentToolIOIndex
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let titleAndTool = makeRepoSession(id: "a-title-and-tool", source: .codex, repoName: "repo")
        let lowerRankedTool = makeRepoSession(id: "b-lower-ranked-tool", source: .codex, repoName: "repo")

        try await db.begin()
        for session in [titleAndTool, lowerRankedTool] {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "codex")
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: "codex", path: session.filePath,
                mtime: 10, size: 20, startTS: 1, endTS: 2, model: nil,
                cwd: session.cwd, repo: session.rowRepoName, title: nil,
                codexInternalSessionID: nil, isHousekeeping: false, messages: 1,
                commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            try await db.upsertSessionSearch(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20, text: "ordinary unrelated body")
            let toolText = session.id == titleAndTool.id
                ? "RankedToolNeedle953"
                : "RankedToolNeedle953 " + String(repeating: "filler ", count: 100)
            try await db.upsertSessionToolIO(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20, refTS: 2, text: toolText)
        }
        try await db.commit()

        let rankedToolIDs = try await db.searchSessionIDsToolIOFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "RankedToolNeedle953",
            includeSystemProbes: true, limit: 1
        )
        XCTAssertEqual(rankedToolIDs, [titleAndTool.id], "fixture must rank the title-bearing tool hit first")

        let titleOverride = [SearchCoordinator.SessionKey(titleAndTool): "RankedToolNeedle953"]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db,
                                            ftsResultLimitForTesting: 1)
        coordinator.start(query: "RankedToolNeedle953",
                          filters: Filters(query: "RankedToolNeedle953"),
                          allowed: [.codex], enableDeepScan: false,
                          all: [titleAndTool, lowerRankedTool],
                          effectiveDisplayTitles: titleOverride)
        try await waitForSearchResults(coordinator, expectedIDs: [titleAndTool.id])
        XCTAssertEqual(coordinator.results.map(\.id), [titleAndTool.id],
                       "a cheap title match must not remove its real tool hit before ranked capacity is applied")
    }

    /// Successor guard to the regression above (SPEC §8.5). The allow-list the views hand to
    /// `SearchCoordinator.start` is now produced in one place —
    /// `UnifiedSessionIndexer.allowedSearchSources()` — and follows one policy for every registered
    /// sources: a source is searchable when it is *both* globally enabled and included by the
    /// source filter. Previously two of the three production call sites gated only pi/kimi/grok
    /// and let the other nine through regardless.
    ///
    /// Asserted through the UserDefaults-backed seams the indexer already exposes: inclusion via
    /// the published `include*` flags, enablement via `syncAgentEnablementFromDefaults(defaults:)`
    /// against a scratch suite. Enablement is only ever driven *off* here — flipping a provider
    /// on would make the indexer kick off a real filesystem refresh for it. The two `include`
    /// flags this touches persist to standard defaults, so they are restored on exit. Task 7's
    /// handle-injection harness replaces the scratch suite.
    @MainActor
    func testAllowedSearchSourcesIsEnabledAndIncluded() throws {
        let unified = makeUnifiedIndexerForAllowListTests()

        func expectedAllowed() -> Set<SessionSource> {
            Set(SessionSource.allCases.filter { unified.isAgentEnabled($0) && unified.isIncluded($0) })
        }

        let savedIncludeKimi = unified.includeKimi
        let savedIncludeGrok = unified.includeGrok
        defer {
            unified.includeKimi = savedIncludeKimi
            unified.includeGrok = savedIncludeGrok
        }

        // The rule holds over every registered source, whatever this machine's stored preferences are.
        XCTAssertEqual(unified.allowedSearchSources(), expectedAllowed())

        // Inclusion seam: included sources ride on their enablement, excluded ones never
        // appear — and excluding one leaves the other eleven exactly where they were.
        unified.includeKimi = true
        unified.includeGrok = true
        XCTAssertTrue(unified.isIncluded(.kimi))
        XCTAssertTrue(unified.isIncluded(.grok))
        let bothIncluded = unified.allowedSearchSources()
        XCTAssertEqual(bothIncluded, expectedAllowed())
        XCTAssertEqual(bothIncluded.contains(.kimi), unified.isAgentEnabled(.kimi))
        XCTAssertEqual(bothIncluded.contains(.grok), unified.isAgentEnabled(.grok))

        unified.includeKimi = false
        XCTAssertFalse(unified.isIncluded(.kimi))
        XCTAssertFalse(unified.allowedSearchSources().contains(.kimi))
        XCTAssertEqual(unified.allowedSearchSources(), bothIncluded.subtracting([.kimi]))

        // Enablement seam: a source the user has switched off is not searchable even when the
        // source filter includes it. Switching every enabled provider off empties the list.
        unified.includeKimi = true
        let suiteName = "AllowedSearchSourcesTests-\(UUID().uuidString)"
        let scratch = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { scratch.removePersistentDomain(forName: suiteName) }
        for source in SessionSource.allCases {
            scratch.set(false, forKey: AgentEnablement.enablementKey(for: source))
        }
        unified.syncAgentEnablementFromDefaults(defaults: scratch)

        XCTAssertTrue(SessionSource.allCases.allSatisfy { !unified.isAgentEnabled($0) })
        XCTAssertTrue(unified.isIncluded(.kimi))
        XCTAssertEqual(unified.allowedSearchSources(), [])
    }

    /// A throwaway `UnifiedSessionIndexer` over a throwaway catalog — which builds one
    /// throwaway indexer per source. Provider indexer `init`s only wire Combine pipelines
    /// and read stored path overrides — none of them scans until asked — so this is cheap
    /// and side-effect free as long as no refresh is triggered.
    @MainActor
    private func makeUnifiedIndexerForAllowListTests() -> UnifiedSessionIndexer {
        UnifiedSessionIndexer(catalog: SessionProviderCatalog())
    }

    private func waitForSearchResults(_ coordinator: SearchCoordinator,
                                      expectedIDs: [String],
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async throws {
        for _ in 0..<50 {
            if coordinator.results.map(\.id) == expectedIDs {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for search results. Got \(coordinator.results.map(\.id))",
                file: file,
                line: line)
    }

    func testSideSearchTagCombinesWithRemainingPhrase() throws {
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-0000-7000-8000-000000000002",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            relationshipKind: .sideChat,
            events: [
                SessionEvent(id: "side-marker",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "ABRACADABRA side-chat note",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ]
        )
        let matchingRoot = makeCodexHierarchySession(
            id: "matching-root",
            runtimeID: "019ed789-0000-7000-8000-000000000003",
            timestamp: "2026-06-18T12-02-00",
            cwd: "/tmp/repo",
            events: [
                SessionEvent(id: "root-marker",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "ABRACADABRA root note",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ]
        )

        let filtered = FilterEngine.filterSessions(
            [matchingRoot, sideChat],
            filters: Filters(query: "#side ABRACADABRA"),
            allowTranscriptGeneration: false
        )

        XCTAssertEqual(filtered.map(\.id), ["side-chat"])
        XCTAssertEqual(FilterEngine.parseOperators("#side ABRACADABRA").freeText, "ABRACADABRA")
    }

    func testQuotedSideSearchTagRemainsLiteralText() throws {
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019ed789-0000-7000-8000-000000000001",
            timestamp: "2026-06-18T12-01-00",
            cwd: "/tmp/repo",
            events: [
                SessionEvent(id: "quoted-side",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "literal #side tag",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ]
        )

        let parsed = FilterEngine.parseOperators("\"#side\"")
        let filtered = FilterEngine.filterSessions(
            [root],
            filters: Filters(query: "\"#side\""),
            allowTranscriptGeneration: false
        )

        XCTAssertFalse(parsed.sideChatsOnly)
        XCTAssertEqual(parsed.freeText, "\"#side\"")
        XCTAssertEqual(filtered.map(\.id), ["root"])
    }

    func testSearchMatchesLightweightSessionTitle() throws {
        let session = Session(
            id: "codex-desktop-archived",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-codex-desktop-archived.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Bay Area Gold group contacts",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )

        let filters = Filters(query: "Bay Area Gold",
                              dateFrom: nil,
                              dateTo: nil,
                              model: nil,
                              kinds: Set(SessionEventKind.allCases))

        XCTAssertTrue(FilterEngine.sessionMatches(session, filters: filters, allowTranscriptGeneration: false))

        let cache = TranscriptCache()
        cache.set(session.id, transcript: "cached transcript without the title")
        XCTAssertTrue(FilterEngine.sessionMatches(session,
                                                  filters: filters,
                                                  transcriptCache: cache,
                                                  allowTranscriptGeneration: false))
    }

    func testArchivedCodexPredicateMatchesAnyCodexArchivedPath() throws {
        let archivedDesktop = Session(
            id: "archived-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-archived.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Archived desktop",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let activeDesktop = Session(
            id: "active-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/24/rollout-2026-04-24T16-10-54-active.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Active desktop",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let archivedCLI = Session(
            id: "archived-cli",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-cli.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Archived CLI",
            codexOriginator: "codex_cli_rs",
            codexSurface: .cli
        )
        let archivedClaudeDesktop = Session(
            id: "archived-claude",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-claude.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Archived Claude",
            originator: "Claude Desktop",
            surface: .desktop
        )

        // Path-only semantics: any Codex session under archived_sessions matches,
        // regardless of surface. Metadata (codexOriginator/codexSurface) is NOT consulted,
        // since hydrated sessions routinely lack it (see isArchivedCodexDesktopSession).
        XCTAssertTrue(archivedDesktop.isArchivedCodexDesktopSession)
        XCTAssertFalse(activeDesktop.isArchivedCodexDesktopSession)
        XCTAssertTrue(archivedCLI.isArchivedCodexDesktopSession)
        // Non-Codex sources never match, even under an archived_sessions path.
        XCTAssertFalse(archivedClaudeDesktop.isArchivedCodexDesktopSession)
    }

    func testArchivedCodexDesktopFilterNarrowsCodexAndLeavesOtherAgentsVisible() throws {
        let archived = Session(
            id: "archived-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-archived.jsonl",
            eventCount: 1,
            events: [
                SessionEvent(id: "u1",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "Find the west bay tournament invoice",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Bay Area Gold contacts",
            customTitle: "Bay Area Gold contacts",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let active = Session(
            id: "active-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/24/rollout-2026-04-24T16-10-54-active.jsonl",
            eventCount: 1,
            events: [
                SessionEvent(id: "u2",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "Find the west bay tournament invoice",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Bay Area Gold contacts",
            customTitle: "Bay Area Gold contacts",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let claude = Session(
            id: "claude-desktop",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/repo/session.jsonl",
            eventCount: 1,
            events: [
                SessionEvent(id: "u3",
                             timestamp: nil,
                             kind: .user,
                             role: "user",
                             text: "Find the west bay tournament invoice",
                             toolName: nil,
                             toolInput: nil,
                             toolOutput: nil,
                             messageID: nil,
                             parentID: nil,
                             isDelta: false,
                             rawJSON: "{}")
            ],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Bay Area Gold contacts",
            customTitle: "Bay Area Gold contacts",
            originator: "Claude Desktop",
            surface: .desktop
        )
        let all = [archived, active, claude]

        var filters = Filters(query: "",
                              dateFrom: nil,
                              dateTo: nil,
                              model: nil,
                              kinds: Set(SessionEventKind.allCases),
                              archivedCodexDesktopOnly: true)
        XCTAssertEqual(FilterEngine.filterSessions(all, filters: filters).map(\.id), ["archived-desktop", "claude-desktop"])

        filters.query = "Bay Area Gold"
        XCTAssertEqual(FilterEngine.filterSessions(all, filters: filters).map(\.id), ["archived-desktop", "claude-desktop"])

        filters.query = "west bay tournament"
        XCTAssertEqual(FilterEngine.filterSessions(all, filters: filters).map(\.id), ["archived-desktop", "claude-desktop"])
    }

    func testCodexDesktopSurfacePillsIncludeArchivedMarker() throws {
        let archived = Session(
            id: "archived-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-archived.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Archived desktop",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let active = Session(
            id: "active-desktop",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/24/rollout-2026-04-24T16-10-54-active.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Active desktop",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let archivedOriginatorOnly = Session(
            id: "archived-originator-only",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-04-24T16-10-54-originator.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Archived desktop metadata",
            codexOriginator: "Codex Desktop"
        )

        let archivedPills = UnifiedSessionsView.surfacePills(for: archived)
        XCTAssertEqual(archivedPills.map(\.label), ["desk"])
        XCTAssertEqual(archivedPills.map(\.isArchived), [true])
        XCTAssertEqual(archivedPills.map(\.identity), ["desk-archived"])
        XCTAssertEqual(archivedPills.map { $0.accessibilityLabel(agentLabel: "Codex") }, ["Codex Desktop archived session"])

        let activePills = UnifiedSessionsView.surfacePills(for: active)
        XCTAssertEqual(activePills.map(\.label), ["desk"])
        XCTAssertEqual(activePills.map(\.isArchived), [false])
        XCTAssertEqual(activePills.map(\.identity), ["desk-standard"])
        XCTAssertEqual(activePills.map { $0.accessibilityLabel(agentLabel: "Codex") }, ["Codex Desktop app"])

        let archivedOriginatorOnlyPills = UnifiedSessionsView.surfacePills(for: archivedOriginatorOnly)
        XCTAssertEqual(archivedOriginatorOnlyPills.map(\.label), ["desk"])
        XCTAssertEqual(archivedOriginatorOnlyPills.map(\.isArchived), [true])
        XCTAssertEqual(archivedOriginatorOnlyPills.map(\.identity), ["desk-archived"])
    }

    func testCodexDesktopProjectlessThreadsDisplayAsChatsProject() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsProjectless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateURL = dir.appendingPathComponent(".codex-global-state.json")
        try writeText(#"{"projectless-thread-ids":["thread-chat"]}"#, to: stateURL)
        CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(stateURL)
        defer { CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(nil) }

        let session = Session(
            id: "desktop-chat",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/08/rollout-2026-05-08T13-35-32-thread-chat.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Documents/Codex/2026-05-08/use-computer-send-message",
            repoName: "use-computer-send-message",
            lightweightTitle: "Bay Area Gold group contacts",
            codexInternalSessionIDHint: "thread-chat",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )

        XCTAssertEqual(session.repoName, "Codex Desktop Chats")
        XCTAssertEqual(session.repoDisplay, "Codex Desktop Chats")
    }

    func testCodexDesktopChatsProjectDoesNotAffectRepoBackedOrNonDesktopSessions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsProjectless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateURL = dir.appendingPathComponent(".codex-global-state.json")
        try writeText(#"{"projectless-thread-ids":["thread-chat"]}"#, to: stateURL)
        CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(stateURL)
        defer { CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(nil) }

        let repoBackedDesktop = Session(
            id: "desktop-repo",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/08/rollout-2026-05-08T13-35-32-thread-repo.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Codex-History",
            repoName: "Codex-History",
            lightweightTitle: "Repo task",
            codexInternalSessionIDHint: "thread-repo",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )
        let cliWithProjectlessID = Session(
            id: "cli-chat-id",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/08/rollout-2026-05-08T13-35-32-thread-chat.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Documents/Codex/2026-05-08/use-computer-send-message",
            repoName: "use-computer-send-message",
            lightweightTitle: "CLI task",
            codexInternalSessionIDHint: "thread-chat",
            codexOriginator: "codex_cli_rs",
            codexSurface: .cli
        )

        XCTAssertEqual(repoBackedDesktop.repoName, "Codex-History")
        XCTAssertEqual(cliWithProjectlessID.repoName, "use-computer-send-message")
    }

    func testCodexDesktopGeneratedChatWorkspaceDisplaysAsChatsProjectWithoutStateID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsProjectless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateURL = dir.appendingPathComponent(".codex-global-state.json")
        try writeText(#"{"projectless-thread-ids":[]}"#, to: stateURL)
        CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(stateURL)
        defer { CodexDesktopProjectlessThreadStore.shared.setStateURLOverrideForTesting(nil) }

        let session = Session(
            id: "desktop-chat-workspace",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/archived_sessions/rollout-2026-05-05T11-54-32-thread-old.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Documents/Codex/2026-04-24/use-computer-send-imessage-to-hi",
            repoName: "use-computer-send-imessage-to-hi",
            lightweightTitle: "Send iMessage",
            codexInternalSessionIDHint: "thread-old",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )

        XCTAssertEqual(session.repoName, "Codex Desktop Chats")
        XCTAssertEqual(session.repoDisplay, "Codex Desktop Chats")
    }

    func testClaudeDesktopGeneratedChatWorkspaceDisplaysAsClaudeChatsProject() throws {
        let session = Session(
            id: "claude-desktop-chat",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/Library/Application Support/Claude/local-agent-mode-sessions/account/workspace/local_abc/.claude/projects/-sessions-peaceful-awesome-bohr/11111111-1111-4111-8111-111111111111.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/sessions/peaceful-awesome-bohr",
            repoName: "peaceful-awesome-bohr",
            lightweightTitle: "Redesign junior tennis analytics website",
            codexInternalSessionIDHint: "11111111-1111-4111-8111-111111111111",
            originator: "Claude Desktop",
            originSource: "local-agent-mode",
            surface: .desktop
        )

        XCTAssertEqual(session.repoName, "Claude Desktop Chats")
        XCTAssertEqual(session.repoDisplay, "Claude Desktop Chats")
    }

    func testClaudeDesktopChatsProjectDoesNotAffectRepoBackedSessions() throws {
        let session = Session(
            id: "claude-desktop-repo",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/Library/Application Support/Claude/local-agent-mode-sessions/account/workspace/local_abc/.claude/projects/-Users-test-Repo/11111111-1111-4111-8111-111111111111.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: "Repo",
            lightweightTitle: "Repo task",
            codexInternalSessionIDHint: "11111111-1111-4111-8111-111111111111",
            originator: "Claude Desktop",
            originSource: "local-agent-mode",
            surface: .desktop
        )

        XCTAssertEqual(session.repoName, "Repo")
        XCTAssertEqual(session.repoDisplay, "Repo")
    }

    func testGeneratedWorktreePathsDisplayParentProject() throws {
        let tennisWorktree = Session(
            id: "tennis-worktree",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-Users-test-Repository-Scripts-tennis-scraper/agent.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper/.worktrees/visual-redesign",
            repoName: "visual-redesign",
            lightweightTitle: "Visual redesign"
        )
        let claudeWorktree = Session(
            id: "claude-worktree",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-Users-test-Repository-Codex-History--claude-worktrees-flamboyant-elion-309182/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Codex-History/.claude/worktrees/flamboyant-elion-309182",
            repoName: "flamboyant-elion-309182",
            lightweightTitle: "TEST session",
            originator: "Claude Desktop",
            surface: .desktop
        )
        let numberedSiblingWorktree = Session(
            id: "numbered-worktree",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/13/rollout-2026-04-13T15-33-08-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/triada-54",
            repoName: "triada-54",
            lightweightTitle: "Triada brush fix"
        )
        let numberedSiblingWorktreeSubdir = Session(
            id: "numbered-worktree-subdir",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/13/rollout-2026-04-13T15-33-08-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/triada-54/Triada",
            repoName: "Triada",
            lightweightTitle: "Triada brush fix"
        )
        let nestedNumberedSiblingWorktree = Session(
            id: "nested-numbered-worktree",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/13/rollout-2026-04-13T15-33-08-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper-54",
            repoName: "tennis-scraper-54",
            lightweightTitle: "Tennis scraper worktree"
        )
        let nestedNumberedSiblingWorktreeSubdir = Session(
            id: "nested-numbered-worktree-subdir",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/13/rollout-2026-04-13T15-33-08-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper-54/outputs",
            repoName: "outputs",
            lightweightTitle: "Tennis scraper worktree output"
        )
        let codexDesktopSiblingWorktree = Session(
            id: "codex-desktop-sibling-worktree",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Codex-History-pi-support",
            repoName: "Codex-History-pi-support",
            lightweightTitle: "Pi support",
            originator: "Codex Desktop",
            originSource: "vscode",
            surface: .desktop
        )
        let codexDesktopSiblingWorktreeSubdir = Session(
            id: "codex-desktop-sibling-worktree-subdir",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Codex-History-pi-support/AgentSessions",
            repoName: "AgentSessions",
            lightweightTitle: "Pi support source",
            originator: "Codex Desktop",
            originSource: "vscode",
            surface: .desktop
        )
        let codexDesktopCapitalizedRepository = Session(
            id: "codex-desktop-capitalized-repository",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Junior-Tennis-Academy-map",
            repoName: "Junior-Tennis-Academy-map",
            lightweightTitle: "Academy map",
            originator: "Codex Desktop",
            originSource: "vscode",
            surface: .desktop
        )

        XCTAssertEqual(tennisWorktree.repoName, "tennis-scraper")
        XCTAssertEqual(claudeWorktree.repoName, "Codex-History")
        XCTAssertEqual(numberedSiblingWorktree.repoName, "Triada")
        XCTAssertEqual(numberedSiblingWorktreeSubdir.repoName, "Triada")
        XCTAssertEqual(nestedNumberedSiblingWorktree.repoName, "tennis-scraper")
        XCTAssertEqual(nestedNumberedSiblingWorktreeSubdir.repoName, "tennis-scraper")
        XCTAssertEqual(codexDesktopSiblingWorktree.repoName, "Codex-History-pi-support")
        XCTAssertNil(codexDesktopSiblingWorktree.projectWorktreeDisplayName)
        XCTAssertEqual(codexDesktopSiblingWorktreeSubdir.repoName, "Codex-History-pi-support")
        XCTAssertNil(codexDesktopSiblingWorktreeSubdir.projectWorktreeDisplayName)
        XCTAssertEqual(codexDesktopCapitalizedRepository.repoName, "Junior-Tennis-Academy-map")
        XCTAssertNil(codexDesktopCapitalizedRepository.projectWorktreeDisplayName)
        XCTAssertEqual(tennisWorktree.projectWorktreeDisplayName, "visual-redesign")
        XCTAssertEqual(claudeWorktree.projectWorktreeDisplayName, "flamboyant-elion-309182")
        XCTAssertEqual(numberedSiblingWorktree.projectWorktreeDisplayName, "triada-54")
    }

    func testCodexDesktopSiblingWorktreeUsesGitMetadataWhenNameIsLowercase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-WorktreeMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let repo = root.appendingPathComponent("Repository", isDirectory: true)
        let base = repo.appendingPathComponent("agent-sessions", isDirectory: true)
        let worktree = repo.appendingPathComponent("agent-sessions-ui", isDirectory: true)
        let gitWorktreeDir = base.appendingPathComponent(".git/worktrees/agent-sessions-ui", isDirectory: true)
        try fm.createDirectory(at: gitWorktreeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeText("gitdir: \(gitWorktreeDir.path)\n", to: worktree.appendingPathComponent(".git"))

        let session = Session(
            id: "codex-desktop-lowercase-git-metadata-worktree",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: worktree.appendingPathComponent("AgentSessions").path,
            repoName: "agent-sessions-ui",
            lightweightTitle: "UI worktree",
            originator: "Codex Desktop",
            originSource: "vscode",
            surface: .desktop
        )

        XCTAssertEqual(session.repoName, "agent-sessions")
        XCTAssertEqual(session.projectWorktreeDisplayName, "agent-sessions-ui")
    }

    func testCodexDesktopArbitrarySiblingWorktreeUsesGitOriginMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OriginMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let repo = root.appendingPathComponent("Repository", isDirectory: true)
        let base = repo.appendingPathComponent("stable-home", isDirectory: true)
        let worktree = repo.appendingPathComponent("build-lab-seven", isDirectory: true)
        try fm.createDirectory(at: base.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        try writeText(
            """
            [remote "origin"]
            \turl = https://example.test/acme/widgets.git
            """,
            to: base.appendingPathComponent(".git/config")
        )

        let raw = #"{"type":"session_meta","payload":{"cwd":"\#(worktree.appendingPathComponent("Sources").path)","originator":"Codex Desktop","source":"exec","git":{"branch":"feature/blue","repository_url":"https://example.test/acme/widgets.git"}}}"#
        let event = SessionEvent(
            id: "origin-meta",
            timestamp: nil,
            kind: .meta,
            role: nil,
            text: nil,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: raw
        )

        let session = Session(
            id: "codex-desktop-arbitrary-origin-worktree",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 1,
            events: [event],
            originator: "Codex Desktop",
            originSource: "exec",
            surface: .desktop
        )

        XCTAssertEqual(session.repoName, "stable-home")
        XCTAssertEqual(session.projectWorktreeDisplayName, "build-lab-seven")
    }

    func testCodexDesktopSiblingRepositoryWithoutGitOriginMetadataDoesNotUseBaseDirectoryFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ExistingSiblingRepo-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let repo = root.appendingPathComponent("Repository", isDirectory: true)
        let base = repo.appendingPathComponent("alpha-control", isDirectory: true)
        let standalone = repo.appendingPathComponent("delta-client-space", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: standalone, withIntermediateDirectories: true)

        let session = Session(
            id: "codex-desktop-existing-sibling-repo",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/12/rollout-2026-05-12T18-00-00-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: standalone.path,
            repoName: "delta-client-space",
            lightweightTitle: "Standalone repo",
            originator: "Codex Desktop",
            originSource: "vscode",
            surface: .desktop
        )

        XCTAssertEqual(session.repoName, "delta-client-space")
        XCTAssertNil(session.projectWorktreeDisplayName)
    }

    func testCodexStateThreadsReadCurrentSchemaGitMetadata() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-StateCurrent-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        try createCodexStateSQLiteFixture(at: dbURL, includeGitColumns: true)

        let lookup = SessionIndexer.readCodexStateThreads(from: dbURL)
        let thread = try XCTUnwrap(lookup.byID["thread-state"])
        XCTAssertEqual(thread.rolloutPath, "/tmp/rollout-state.jsonl")
        XCTAssertEqual(thread.cwd, "/tmp/state-worktree")
        XCTAssertEqual(thread.gitBranch, "feature/state-git")
        XCTAssertEqual(thread.gitOriginURL, "https://example.test/acme/widgets.git")
        XCTAssertEqual(thread.bestTitle, "State title fallback")
    }

    func testCodexStateThreadsReadOldSchemaWithoutGitColumns() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-StateOld-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        try createCodexStateSQLiteFixture(at: dbURL, includeGitColumns: false)

        let lookup = SessionIndexer.readCodexStateThreads(from: dbURL)
        let thread = try XCTUnwrap(lookup.byID["thread-state"])
        XCTAssertEqual(thread.rolloutPath, "/tmp/rollout-state.jsonl")
        XCTAssertEqual(thread.cwd, "/tmp/state-worktree")
        XCTAssertNil(thread.gitBranch)
        XCTAssertNil(thread.gitOriginURL)
        XCTAssertEqual(thread.bestTitle, "State title fallback")
    }

    private func codexFallbackThread(firstUserMessage: String?, title: String? = nil) -> SessionIndexer.CodexStateThread {
        SessionIndexer.CodexStateThread(
            id: "thread-fallback",
            rolloutPath: "/tmp/rollout-fallback.jsonl",
            cwd: nil,
            gitBranch: nil,
            gitOriginURL: nil,
            title: title,
            firstUserMessage: firstUserMessage
        )
    }

    func testCodexFallbackPastedFileWrapperReturnsRequest() throws {
        let thread = codexFallbackThread(firstUserMessage: "# Files pasted by the user:\nfoo.txt contents\n## My request:\nFix the login bug")
        XCTAssertEqual(thread.bestTitle, "Fix the login bug")
    }

    func testCodexFallbackStripsRepeatedControlBlocks() throws {
        let raw = """
        # AGENTS.md instructions for /tmp/repo
        <INSTRUCTIONS>follow these</INSTRUCTIONS>
        <app-context>synthetic context</app-context>
        <environment_context>synthetic env</environment_context>
        Real request here
        """
        XCTAssertEqual(codexFallbackThread(firstUserMessage: raw).bestTitle, "Real request here")
    }

    func testCodexFallbackPreservesOrdinaryContent() throws {
        let cases = [
            "# Heading\nSome **bold** text",
            "```swift\nlet x = 1\n```",
            "/tmp/repo/file.swift",
            "日本語のテストメッセージです",
            "Use <div> tag here"
        ]
        for raw in cases {
            XCTAssertEqual(codexFallbackThread(firstUserMessage: raw).bestTitle, raw, "input must be preserved: \(raw)")
        }
    }

    func testCodexFallbackPreservesMalformedWrappers() throws {
        let unclosed = "<app-context>unclosed content"
        XCTAssertEqual(codexFallbackThread(firstUserMessage: unclosed).bestTitle, unclosed)
        let missingDelimiter = "# Files pasted by the user:\nfoo.txt contents\nNo delimiter here"
        XCTAssertEqual(codexFallbackThread(firstUserMessage: missingDelimiter).bestTitle, missingDelimiter)
        let incompleteAgents = "# AGENTS.md instructions for /tmp/repo\n<INSTRUCTIONS>incomplete"
        XCTAssertEqual(codexFallbackThread(firstUserMessage: incompleteAgents).bestTitle, incompleteAgents)
    }

    func testCodexFallbackPreservesMarkerAfterContent() throws {
        let raw = "Fix the login bug\n<app-context>later</app-context>"
        XCTAssertEqual(codexFallbackThread(firstUserMessage: raw).bestTitle, raw)
    }

    func testCodexExplicitTitleWinsOverWrappedFallback() throws {
        let wrapped = "# Files pasted by the user:\nfoo\n## My request:\nWrapped request"
        XCTAssertEqual(codexFallbackThread(firstUserMessage: wrapped, title: "Explicit state title").bestTitle, "Explicit state title")
        XCTAssertEqual(codexFallbackThread(firstUserMessage: wrapped, title: "<app-context>Explicit</app-context>").bestTitle, "<app-context>Explicit</app-context>")
    }

    func testCodexFallbackScaffoldingOnlyProducesNil() throws {
        XCTAssertNil(codexFallbackThread(firstUserMessage: "<app-context>only scaffolding</app-context>").bestTitle)
        XCTAssertNil(codexFallbackThread(firstUserMessage: "# Files pasted by the user:\nfoo\n## My request:").bestTitle)
    }

    func testCodexStateLongPastedWrapperSanitizesToRequest() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-StateLongWrapper-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let filler = String(repeating: "a", count: 66000)
        let message = "# Files pasted by the user:\n\(filler)\n## My request:\nFix the login bug"
        XCTAssertGreaterThan(message.components(separatedBy: "## My request:").first?.count ?? 0, 65536)
        try executeSQLite("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            first_user_message TEXT NOT NULL
        );
        """, at: dbURL)
        try executeSQLite("""
        INSERT INTO threads (id, rollout_path, cwd, title, first_user_message)
        VALUES ('thread-long-wrapper', '/tmp/rollout-long-wrapper.jsonl', '/tmp/long-wrapper', '', '\(message)');
        """, at: dbURL)

        let lookup = SessionIndexer.readCodexStateThreads(from: dbURL)
        let thread = try XCTUnwrap(lookup.byID["thread-long-wrapper"])
        XCTAssertEqual(thread.bestTitle, "Fix the login bug")
    }

    func testCodexStateLongMalformedWrapperStaysBounded() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-StateLongMalformed-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let filler = String(repeating: "a", count: 66000)
        let message = "# Files pasted by the user:\n\(filler)\nNo delimiter here"
        XCTAssertGreaterThan(message.count, 65536)
        try executeSQLite("""
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT NOT NULL,
            title TEXT NOT NULL,
            first_user_message TEXT NOT NULL
        );
        """, at: dbURL)
        try executeSQLite("""
        INSERT INTO threads (id, rollout_path, cwd, title, first_user_message)
        VALUES ('thread-long-malformed', '/tmp/rollout-long-malformed.jsonl', '/tmp/long-malformed', '', '\(message)');
        """, at: dbURL)

        let lookup = SessionIndexer.readCodexStateThreads(from: dbURL)
        let thread = try XCTUnwrap(lookup.byID["thread-long-malformed"])
        let title = try XCTUnwrap(thread.bestTitle)
        XCTAssertEqual(title.count, 512)
        XCTAssertEqual(title, String(message.prefix(512)))
    }

    func testCodexFallbackOversizedOrdinaryMessageStaysBounded() throws {
        let raw = String(repeating: "a", count: 600)
        let title = try XCTUnwrap(codexFallbackThread(firstUserMessage: raw).bestTitle)
        XCTAssertEqual(title.count, 512)
        XCTAssertEqual(title, String(repeating: "a", count: 512))
    }

    func testNumericRepositoryNamesDoNotNormalizeAsGeneratedWorktrees() throws {
        let versionedRepo = Session(
            id: "versioned-repo",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/13/rollout-2026-04-13T15-33-08-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/api-2024",
            repoName: "api-2024",
            lightweightTitle: "Versioned repo task"
        )

        XCTAssertEqual(versionedRepo.repoName, "api-2024")
    }

    func testNestedRepoPathsDisplayRepoRootProject() throws {
        let siteSubdir = Session(
            id: "site-subdir",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-Users-test-Repository-Scripts-tennis-scraper/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper/TennisGroupSite",
            repoName: "TennisGroupSite",
            lightweightTitle: "Update event page"
        )
        let outputSubdir = Session(
            id: "output-subdir",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-Users-test-Repository-Scripts-tennis-scraper/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper/outputs",
            repoName: "outputs",
            lightweightTitle: "Inspect generated output"
        )
        let publishClone = Session(
            id: "publish-clone",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-Users-test-Repository-Scripts-tennis-scraper/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/Repository/Scripts/tennis-scraper/.tennisgroup_repo_fresh",
            repoName: ".tennisgroup_repo_fresh",
            lightweightTitle: "Publish TennisGroup page"
        )

        XCTAssertEqual(siteSubdir.repoName, "tennis-scraper")
        XCTAssertEqual(outputSubdir.repoName, "tennis-scraper")
        XCTAssertEqual(publishClone.repoName, "tennis-scraper")
    }

    func testGenericNonProjectPathsDoNotUseStoredDirectoryName() throws {
        let rootSession = Session(
            id: "root",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.claude/projects/-/session.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/",
            repoName: "/",
            lightweightTitle: "Root task"
        )
        let codexMemorySession = Session(
            id: "codex-memory",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/05/08/rollout-thread.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/test/.codex/memories",
            repoName: "memories",
            lightweightTitle: "Memory task"
        )

        XCTAssertNil(rootSession.repoName)
        XCTAssertNil(codexMemorySession.repoName)
    }

    func testCodexModifiedAtUsesFreshEndTimeForRestoredOldRollout() throws {
        let restoredEnd = Date(timeIntervalSince1970: 1_778_269_498)
        let session = Session(
            id: "old-rollout-restored",
            source: .codex,
            startTime: Date(timeIntervalSince1970: 1_777_072_254),
            endTime: restoredEnd,
            model: nil,
            filePath: "/Users/test/.codex/sessions/2026/04/24/rollout-2026-04-24T16-10-54-old-rollout-restored.jsonl",
            eventCount: 1,
            events: [],
            cwd: "/Users/test/Repo",
            repoName: nil,
            lightweightTitle: "Bay Area Gold group contacts",
            codexOriginator: "Codex Desktop",
            codexSource: "vscode",
            codexSurface: .desktop
        )

        XCTAssertEqual(session.modifiedAt, restoredEnd)
    }

    func testCodexPayloadCwdRepoAndBranchExtraction() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex073-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repoDir.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let lines = [
            #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"\#(repoDir.path)","originator":"codex_cli_rs","cli_version":"0.73.0","git":{"branch":"feature/test"},"instructions":"short"}}"#,
            #"{"timestamp":"2025-12-17T23:27:50.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}"#,
            #"{"timestamp":"2025-12-17T23:27:51.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertEqual(s.cwd, repoDir.path)
        XCTAssertEqual(s.repoName, repoDir.lastPathComponent)
        XCTAssertEqual(s.gitBranch, "feature/test")
        XCTAssertEqual(s.codexInternalSessionID, "019b2ea4-2a8d-76e2-9cd8-58208e1f2837")
        XCTAssertEqual(s.codexOriginator, "codex_cli_rs")
        XCTAssertEqual(s.codexSource, nil)
        XCTAssertEqual(s.codexSurface, .cli)
    }

    func testCodexSurfaceClassifiesDesktopBeforeVscodeSource() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexDesktop-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-26T13-43-29-019dc662-1345-7301-b0da-bd28cfab7887.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-25T20:44:15.181Z","type":"session_meta","payload":{"id":"019dc662-1345-7301-b0da-bd28cfab7887","cwd":"/tmp","originator":"Codex Desktop","source":"vscode","cli_version":"0.125.0-alpha.3"}}"#,
            #"{"timestamp":"2026-04-25T20:44:16.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Desktop title"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.codexOriginator, "Codex Desktop")
        XCTAssertEqual(session?.codexSource, "vscode")
        XCTAssertEqual(session?.codexSurface, .desktop)
    }

    func testCodexSurfaceClassifiesVSCodeOriginator() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexVSCode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-26T17-50-52-019dcc6a-eae1-7cf1-abc6-3e89614353f1.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-26T17:50:52.000Z","type":"session_meta","payload":{"id":"019dcc6a-eae1-7cf1-abc6-3e89614353f1","cwd":"/tmp","originator":"codex_vscode","source":"vscode"}}"#,
            #"{"timestamp":"2026-04-26T17:50:53.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"VS Code title"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.codexOriginator, "codex_vscode")
        XCTAssertEqual(session?.codexSource, "vscode")
        XCTAssertEqual(session?.codexSurface, .vscode)
    }

    func testCodexSurfaceClassifiesSubagentObjectAndPreservesHierarchy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexSubagent-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-17T13-28-49-019d9d21-c62f-7290-aab2-809d579e782e.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-17T20:28:50.252Z","type":"session_meta","payload":{"id":"019d9d21-c62f-7290-aab2-809d579e782e","cwd":"/tmp","originator":"codex-tui","source":{"subagent":"review"}}}"#,
            #"{"timestamp":"2026-04-17T20:28:51.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review this"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "review")
        XCTAssertEqual(session?.codexSurface, .subagent)
        XCTAssertTrue(session?.codexSource?.contains(#""subagent":"review""#) == true)
    }

    // MARK: - Codex guardian subagent classification (2026-07-19)

    func testCodexGuardianOtherSubagentClassifiesAndLinksParent() throws {
        // Newer Codex builds (0.145+) spawn guardian approval reviewers with
        // source {"subagent":{"other":"guardian"}} and stamp the parent link
        // at payload top level (NOT inside thread_spawn, and there is no
        // thread_spawn_edges row for them).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexGuardian-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T17-22-56-019f7ce7-8979-7203-8867-34084576cf0c.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T00:22:56.633Z","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/Users/test/Documents/Codex/2026-07-19/kaize-slug","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}},"thread_source":"subagent"}}"#,
            #"{"timestamp":"2026-07-20T00:22:57.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess the planned action"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "guardian")
        XCTAssertEqual(session?.parentSessionID, "019f7ce5-7a52-7e32-8fc5-99c3193aba48")
        XCTAssertTrue(session?.isSubagent == true)
        XCTAssertEqual(session?.codexSurface, .subagent)
    }

    func testCodexGuardianOtherSubagentClassifiesViaParseFileFull() throws {
        // parseFile(at:) resolves to lightweightSession for any readable,
        // well-formed fixture, so the pinning above never exercises
        // parseFileFull's copy of this branch (SessionIndexer.swift:507, :630
        // both call into it directly). Call it explicitly so a future edit
        // that only touches the parseFileFull block gets caught here too.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexGuardianFull-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T17-22-56-019f7ce7-8979-7203-8867-34084576cf0c.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T00:22:56.633Z","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/Users/test/Documents/Codex/2026-07-19/kaize-slug","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}},"thread_source":"subagent"}}"#,
            #"{"timestamp":"2026-07-20T00:22:57.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess the planned action"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFileFull(at: url)
        XCTAssertEqual(session?.subagentType, "guardian")
        XCTAssertEqual(session?.parentSessionID, "019f7ce5-7a52-7e32-8fc5-99c3193aba48")
        XCTAssertTrue(session?.isSubagent == true)
        XCTAssertEqual(session?.codexSurface, .subagent)
    }

    func testCodexGuardianWithoutTopLevelParentStillClassifies() throws {
        // 68 of 70 on-disk guardian rollouts predate the parent_thread_id
        // stamp: subagentType alone must classify them (parent then resolves
        // via SubagentHierarchyBuilder's role-only same-cwd inference).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexGuardianOld-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-06-01T10-00-00-019f0000-0000-7000-8000-000000000001.jsonl")
        let lines = [
            #"{"timestamp":"2026-06-01T17:00:00.000Z","type":"session_meta","payload":{"id":"019f0000-0000-7000-8000-000000000001","cwd":"/tmp/repo","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}}}}"#,
            #"{"timestamp":"2026-06-01T17:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "guardian")
        XCTAssertNil(session?.parentSessionID)
        XCTAssertTrue(session?.isSubagent == true)
    }

    func testCodexUnknownSubagentStructVariantFallsBackToVariantName() throws {
        // Future-proofing: an unrecognized struct variant must still classify
        // as a subagent (variant name as type) instead of silently reading as
        // a root session — that silence is exactly how guardian slipped through.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexFutureSub-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T18-00-00-019f0000-0000-7000-8000-000000000002.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T01:00:00.000Z","type":"session_meta","payload":{"id":"019f0000-0000-7000-8000-000000000002","cwd":"/tmp/repo","source":{"subagent":{"future_kind":{"detail":1}}}}}"#,
            #"{"timestamp":"2026-07-20T01:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "future_kind")
        XCTAssertTrue(session?.isSubagent == true)
    }

    func testSubagentHierarchyNestsGuardianUnderExplicitParent() {
        // End-to-end row shape: guardian with an explicit parentSessionID nests
        // under the parent resolved via the parent's internal-ID hint.
        let parent = makeCodexHierarchySession(
            id: "work-parent",
            runtimeID: "019f7ce5-7a52-7e32-8fc5-99c3193aba48",
            timestamp: "2026-07-19T17-20-41",
            cwd: "/Users/test/Documents/Codex/2026-07-19/kaize-slug"
        )
        let guardian = makeCodexHierarchySession(
            id: "guardian-child",
            runtimeID: "019f7ce7-8979-7203-8867-34084576cf0c",
            timestamp: "2026-07-19T17-22-56",
            cwd: "/Users/test/Documents/Codex/2026-07-19/kaize-slug",
            parentSessionID: "019f7ce5-7a52-7e32-8fc5-99c3193aba48",
            subagentType: "guardian"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, guardian],
            hierarchyEnabled: true
        )
        XCTAssertEqual(result.sessions.map(\.id), ["work-parent", "guardian-child"])
        XCTAssertEqual(result.rowMeta["work-parent"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["guardian-child"]?.depth, 1)
    }

    func testReloadHydrationPreservesExplicitCodexHierarchyAndRowOrder() {
        // Real indexed shape: the row ID is a path hash, while children point to
        // the parent's raw Codex runtime UUID. Both reload publishes must retain
        // that UUID or the children become roots and the table performs a large reorder.
        let parentRuntimeID = "01a04b59-5078-7fe0-a8f0-31d3d8c02e41"
        var parent = makeCodexHierarchySession(
            id: "105db93de0440f3dcb5e7777f8c16bcc1dd1cb6c97b40b97a7cb81fadc4eb188",
            runtimeID: parentRuntimeID,
            timestamp: "2026-08-28T19-28-59",
            cwd: "/Users/test/Repository/Codex-History"
        )
        parent.isFavorite = true
        parent.isHousekeeping = true
        let child = makeCodexHierarchySession(
            id: "03be9c9a27a099bd09c8d6f08f925abf45aaf85f41808bd491bf3448835413ca",
            runtimeID: "01a04b66-0000-7000-8000-000000000001",
            timestamp: "2026-08-28T19-40-00",
            cwd: "/Users/test/Repository/Codex-History",
            parentSessionID: parentRuntimeID,
            subagentType: "review"
        )
        let interveningRoots = (0..<200).map { index in
            makeCodexHierarchySession(
                id: "unrelated-root-\(index)",
                runtimeID: "unrelated-runtime-\(index)",
                timestamp: "2026-08-28T19-35-00",
                cwd: "/Users/test/Repository/Other"
            )
        }
        let sourceOrder = [parent] + interveningRoots + [child]
        let initial = SubagentHierarchyBuilder.build(
            sessions: sourceOrder,
            hierarchyEnabled: true
        )

        // Sensitivity check: reproduce the pre-fix metadata loss. The child falls
        // back to its distant source position and crosses the table rebuild threshold.
        let parentWithoutRuntimeID = makeCodexHierarchySession(
            id: parent.id,
            runtimeID: "",
            timestamp: "2026-08-28T19-28-59",
            cwd: "/Users/test/Repository/Codex-History"
        )
        let broken = SubagentHierarchyBuilder.build(
            sessions: [parentWithoutRuntimeID] + interveningRoots + [child],
            hierarchyEnabled: true
        )
        XCTAssertTrue(UnifiedTableIdentityPolicy.isLargeReorder(old: initial.sessions, new: broken.sessions))

        let parsedEvent = SessionEvent(
            id: "parsed-event",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .assistant,
            role: "assistant",
            text: "Hydrated",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let tailParse = Session(
            id: parent.id,
            source: .codex,
            startTime: parent.startTime,
            endTime: parent.endTime,
            model: nil,
            filePath: parent.filePath,
            eventCount: 1,
            events: [parsedEvent]
        )
        let fullParse = Session(
            id: parent.id,
            source: .codex,
            startTime: parent.startTime,
            endTime: parent.endTime,
            model: "gpt-5",
            filePath: parent.filePath,
            eventCount: 1,
            events: [parsedEvent],
            codexInternalSessionIDHint: parentRuntimeID
        )

        let stages: [(SessionIndexer.ReloadHydrationStage, Session, Bool, Bool)] = [
            (.tail, tailParse, true, true),
            (.full, fullParse, false, false)
        ]
        for (stage, parsed, expectedPartial, expectedHousekeeping) in stages {
            let hydrated = SessionIndexer.mergeReloadedSession(
                current: parent,
                parsed: parsed,
                stage: stage
            )
            let result = SubagentHierarchyBuilder.build(
                sessions: [hydrated] + interveningRoots + [child],
                hierarchyEnabled: true
            )

            XCTAssertEqual(hydrated.codexInternalSessionIDHint, parentRuntimeID)
            XCTAssertEqual(hydrated.isPartiallyHydrated, expectedPartial)
            XCTAssertEqual(hydrated.isHousekeeping, expectedHousekeeping)
            XCTAssertTrue(hydrated.isFavorite)
            XCTAssertEqual(result.sessions.map(\.id), initial.sessions.map(\.id))
            XCTAssertEqual(result.rowMeta[parent.id]?.childCount, 1)
            XCTAssertEqual(result.rowMeta[child.id]?.depth, 1)
            XCTAssertFalse(UnifiedTableIdentityPolicy.isLargeReorder(old: initial.sessions, new: result.sessions))
        }
    }

    func testCodexSubagentParsesReasoningEffortFromTurnContext() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexSubagentEffort-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-28T10-00-00-019e3b0c-0000-7000-8000-000000000031.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-28T17:00:00.000Z","type":"session_meta","payload":{"id":"019e3b0c-0000-7000-8000-000000000031","cwd":"/tmp","originator":"codex-tui","source":{"subagent":"review"}}}"#,
            #"{"timestamp":"2026-04-28T17:00:01.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5.5","effort":"high"}}"#,
            #"{"timestamp":"2026-04-28T17:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review this"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.model, "gpt-5.5")
        XCTAssertEqual(session?.subagentType, "review")
        XCTAssertEqual(session?.reasoningEffort, "high")
    }

    func testCodexNormalSessionDoesNotPersistReasoningEffort() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexNormalEffort-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-28T10-10-00-019e3b0c-0000-7000-8000-000000000032.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-28T17:10:00.000Z","type":"session_meta","payload":{"id":"019e3b0c-0000-7000-8000-000000000032","cwd":"/tmp","originator":"codex-tui","source":"cli"}}"#,
            #"{"timestamp":"2026-04-28T17:10:01.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5.5","effort":"high"}}"#,
            #"{"timestamp":"2026-04-28T17:10:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Normal session"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.model, "gpt-5.5")
        XCTAssertFalse(session?.isSubagent == true)
        XCTAssertNil(session?.reasoningEffort)
    }

    func testCodexSurfaceDefaultsUnknownWithoutMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexUnknown-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-04-26T00-00-00-unknown.jsonl")
        try #"{"timestamp":"2026-04-26T00:00:00.000Z","type":"session_meta","payload":{"id":"unknown","cwd":"/tmp"}}"#
            .data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertNil(session?.codexOriginator)
        XCTAssertNil(session?.codexSource)
        XCTAssertEqual(session?.codexSurface, .unknown)
    }

    func testSubagentHierarchyInfersRoleOnlyCodexParentInSameWorkspace() {
        let cwd = "/tmp/repo"
        let earlierParent = makeCodexHierarchySession(
            id: "earlier-parent",
            runtimeID: "019d9d0d-74e5-7c71-8682-a3fd159be56a",
            timestamp: "2026-04-17T13-06-38",
            cwd: cwd
        )
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: cwd
        )
        let roleOnlyChild = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9d15-b642-7fd3-b91b-390331f2aefa",
            timestamp: "2026-04-17T13-15-39",
            cwd: cwd,
            subagentType: "review"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [roleOnlyChild, parent, earlierParent],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["parent", "review-child", "earlier-parent"])
        XCTAssertEqual(result.rowMeta["parent"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["parent"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["earlier-parent"]?.hasChildren, false)
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 1)
    }

    func testSubagentHierarchyHidesChildrenForCollapsedParents() {
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: "/tmp/repo"
        )
        let child = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9d15-b642-7fd3-b91b-390331f2aefa",
            timestamp: "2026-04-17T13-15-39",
            cwd: "/tmp/repo",
            parentSessionID: "019d9d10-3975-78d0-aa1d-76869a532044",
            subagentType: "review"
        )

        let collapsed = SubagentHierarchyBuilder.build(
            sessions: [parent, child],
            collapsedParents: ["parent"],
            hierarchyEnabled: true
        )

        XCTAssertEqual(collapsed.sessions.map(\.id), ["parent"])
        XCTAssertEqual(collapsed.rowMeta["parent"]?.hasChildren, true)
        XCTAssertEqual(collapsed.rowMeta["parent"]?.childCount, 1)
        XCTAssertNil(collapsed.rowMeta["review-child"])
    }

    func testSubagentHierarchyKeepsGrandchildrenWhenParentIsItselfASubagent() {
        // A `review` subagent that gets an *inferred* role-only parent is both a
        // child and a parent. The flatten loop used to skip every session in
        // `childIDs` and only emit `childrenByParentID[s.id]` for the survivors,
        // so this grandchild was dropped from the list entirely.
        let cwd = "/tmp/repo"
        let reviewRuntimeID = "019d9d15-b642-7fd3-b91b-390331f2aefa"
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: cwd
        )
        // Role-only: no parentSessionID, so it resolves to `root` by inference.
        let review = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: reviewRuntimeID,
            timestamp: "2026-04-17T13-15-39",
            cwd: cwd,
            subagentType: "review"
        )
        let grandchild = makeCodexHierarchySession(
            id: "thread-spawn-grandchild",
            runtimeID: "019d9d18-1a2b-7c3d-8e4f-5a6b7c8d9e0f",
            timestamp: "2026-04-17T13-17-39",
            cwd: cwd,
            parentSessionID: reviewRuntimeID,
            subagentType: "thread_spawn"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [root, review, grandchild],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["root", "review-child", "thread-spawn-grandchild"])
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 1)
        XCTAssertEqual(result.rowMeta["review-child"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["review-child"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["thread-spawn-grandchild"]?.depth, 2)
        XCTAssertEqual(result.rowMeta["thread-spawn-grandchild"]?.hasChildren, false)
    }

    func testSubagentHierarchyCollapsingRootHidesEntireSubtree() {
        let cwd = "/tmp/repo"
        let reviewRuntimeID = "019d9d15-b642-7fd3-b91b-390331f2aefa"
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: cwd
        )
        let review = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: reviewRuntimeID,
            timestamp: "2026-04-17T13-15-39",
            cwd: cwd,
            subagentType: "review"
        )
        let grandchild = makeCodexHierarchySession(
            id: "thread-spawn-grandchild",
            runtimeID: "019d9d18-1a2b-7c3d-8e4f-5a6b7c8d9e0f",
            timestamp: "2026-04-17T13-17-39",
            cwd: cwd,
            parentSessionID: reviewRuntimeID,
            subagentType: "thread_spawn"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [root, review, grandchild],
            collapsedParents: ["root"],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["root"])
        XCTAssertEqual(result.rowMeta["root"]?.childCount, 1)
        XCTAssertNil(result.rowMeta["review-child"])
        XCTAssertNil(result.rowMeta["thread-spawn-grandchild"])
    }

    func testSubagentHierarchyCollapsingMidLevelParentHidesOnlyItsChildren() {
        let cwd = "/tmp/repo"
        let reviewRuntimeID = "019d9d15-b642-7fd3-b91b-390331f2aefa"
        let root = makeCodexHierarchySession(
            id: "root",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: cwd
        )
        let review = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: reviewRuntimeID,
            timestamp: "2026-04-17T13-15-39",
            cwd: cwd,
            subagentType: "review"
        )
        let grandchild = makeCodexHierarchySession(
            id: "thread-spawn-grandchild",
            runtimeID: "019d9d18-1a2b-7c3d-8e4f-5a6b7c8d9e0f",
            timestamp: "2026-04-17T13-17-39",
            cwd: cwd,
            parentSessionID: reviewRuntimeID,
            subagentType: "thread_spawn"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [root, review, grandchild],
            collapsedParents: ["review-child"],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["root", "review-child"])
        XCTAssertEqual(result.rowMeta["review-child"]?.hasChildren, true)
        XCTAssertNil(result.rowMeta["thread-spawn-grandchild"])
    }

    func testSubagentHierarchyShowsChildrenWhenCollapsedParentsIsEmpty() {
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: "/tmp/repo"
        )
        let child = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9d15-b642-7fd3-b91b-390331f2aefa",
            timestamp: "2026-04-17T13-15-39",
            cwd: "/tmp/repo",
            parentSessionID: "019d9d10-3975-78d0-aa1d-76869a532044",
            subagentType: "review"
        )

        let expanded = SubagentHierarchyBuilder.build(
            sessions: [parent, child],
            collapsedParents: [],
            hierarchyEnabled: true
        )

        XCTAssertEqual(expanded.sessions.map(\.id), ["parent", "review-child"])
        XCTAssertEqual(expanded.rowMeta["parent"]?.hasChildren, true)
        XCTAssertEqual(expanded.rowMeta["parent"]?.childCount, 1)
        XCTAssertEqual(expanded.rowMeta["review-child"]?.depth, 1)
    }

    func testSubagentHierarchyDoesNotInferRoleOnlyParentAcrossWorkspaces() {
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d10-3975-78d0-aa1d-76869a532044",
            timestamp: "2026-04-17T13-09-39",
            cwd: "/tmp/repo-a"
        )
        let roleOnlyChild = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9d15-b642-7fd3-b91b-390331f2aefa",
            timestamp: "2026-04-17T13-15-39",
            cwd: "/tmp/repo-b",
            subagentType: "review"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [roleOnlyChild, parent],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["review-child", "parent"])
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 0)
        XCTAssertEqual(result.rowMeta["parent"]?.hasChildren, false)
    }

    func testSubagentHierarchyDoesNotInferSideChatAsRoleOnlyParent() {
        let cwd = "/tmp/repo"
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019ed789-2247-7ad3-9b32-00a7875ffa77",
            timestamp: "2026-06-18T10-00-00",
            cwd: cwd,
            relationshipKind: .sideChat
        )
        let roleOnlyChild = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019ed789-2247-7ad3-9b32-00a7875ffa88",
            timestamp: "2026-06-18T10-05-00",
            cwd: cwd,
            subagentType: "review"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [roleOnlyChild, sideChat],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["review-child", "side-chat"])
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 0)
        XCTAssertEqual(result.rowMeta["side-chat"]?.hasChildren, false)
    }

    func testSubagentHierarchyNestsSideChatWhenParentExists() {
        let parentRuntimeID = "019ee839-07ff-7370-8a66-2fedf3ee3956"
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: parentRuntimeID,
            timestamp: "2026-06-21T03-28-32",
            cwd: "/tmp/repo"
        )
        let sideChat = makeCodexHierarchySession(
            id: "side-chat",
            runtimeID: "019eeb13-9ffc-7671-9481-2f2246e09b8a",
            timestamp: "2026-06-21T09-46-32",
            cwd: "/tmp/repo",
            parentSessionID: parentRuntimeID,
            relationshipKind: .sideChat
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [sideChat, parent],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["parent", "side-chat"])
        XCTAssertEqual(result.rowMeta["parent"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["parent"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["side-chat"]?.depth, 1)
    }

    func testSubagentHierarchyInfersRoleOnlyParentAfterLongGap() {
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d1c-5243-7da0-8125-f543471883b0",
            timestamp: "2026-04-17T13-22-52",
            cwd: "/Users/alexm/Repository/Codex-History"
        )
        let roleOnlyChild = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9d9c-a7c2-74a0-be0a-8428fba12509",
            timestamp: "2026-04-17T15-43-02",
            cwd: "/Users/alexm/Repository/Codex-History",
            subagentType: "review"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [roleOnlyChild, parent],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["parent", "review-child"])
        XCTAssertEqual(result.rowMeta["parent"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["parent"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 1)
    }

    func testSubagentHierarchyDoesNotInferRoleOnlyParentWhenCandidateIsStale() {
        let parent = makeCodexHierarchySession(
            id: "parent",
            runtimeID: "019d9d1c-5243-7da0-8125-f543471883b0",
            timestamp: "2026-04-17T13-22-52",
            cwd: "/Users/alexm/Repository/Codex-History"
        )
        let roleOnlyChild = makeCodexHierarchySession(
            id: "review-child",
            runtimeID: "019d9ec7-30b2-7ab2-834b-7bd2a6f00f7d",
            timestamp: "2026-04-18T01-43-02",
            cwd: "/Users/alexm/Repository/Codex-History",
            subagentType: "review"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [roleOnlyChild, parent],
            hierarchyEnabled: true
        )

        XCTAssertEqual(result.sessions.map(\.id), ["review-child", "parent"])
        XCTAssertEqual(result.rowMeta["review-child"]?.depth, 0)
        XCTAssertEqual(result.rowMeta["parent"]?.hasChildren, false)
    }

    func testRepoNamePrefersStoredLightweightRepoName() {
        let session = Session(
            id: "test-session",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/fake.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/Users/alexm/Music/some/nested/path",
            repoName: "stored-repo",
            lightweightTitle: "t"
        )

        XCTAssertEqual(session.repoName, "stored-repo")
    }

    func testCodexLightweightHandlesHugeFirstLine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexHugeMeta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repoDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let hugeInstructions = String(repeating: "A", count: 320_000)
        let first = #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"\#(repoDir.path)","originator":"codex_cli_rs","cli_version":"0.73.0","instructions":"\#(hugeInstructions)"}}"#
        let second = #"{"timestamp":"2025-12-17T23:27:50.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello title"}]}}"#
        try ([first, second].joined(separator: "\n")).data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFile(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertTrue(s.events.isEmpty, "Lightweight parse should not load events")
        XCTAssertEqual(s.cwd, repoDir.path)
        XCTAssertEqual(s.title, "Hello title")
    }

    func testCodexSanitizesEncryptedContentWhenHuge() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexEncrypted-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let huge = String(repeating: "B", count: 160_000)
        let lines = [
            #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","timestamp":"2025-12-17T23:27:49.389Z","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.73.0"}}"#,
            #"{"timestamp":"2025-12-17T23:27:55.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null,"encrypted_content":"\#(huge)"}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        let meta = s.events.filter { $0.kind == .meta }
        XCTAssertTrue(meta.contains(where: { $0.rawJSON.contains("[ENCRYPTED_OMITTED]") }))
        XCTAssertTrue(meta.allSatisfy { $0.rawJSON.count < 50_000 }, "Sanitized rawJSON should stay reasonably small")
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(huge.prefix(100))) }))
    }

    func testCodexSanitizerHandlesDuplicateKeysWithoutCrashing() throws {
        // This guards against regressions where sanitizer loops replace multiple occurrences
        // of the same key in a single JSONL line (possible in malformed logs).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexDupKeys-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2025-12-17T15-27-49-019b2ea4-2a8d-76e2-9cd8-58208e1f2837.jsonl")
        let hugeA = String(repeating: "A", count: 120_000)
        let hugeB = String(repeating: "B", count: 120_000)
        let line = #"{"timestamp":"2025-12-17T23:27:49.405Z","type":"session_meta","payload":{"id":"019b2ea4-2a8d-76e2-9cd8-58208e1f2837","cwd":"/tmp","instructions":"\#(hugeA)","instructions":"\#(hugeB)"}}"#
        try (line + "\n").data(using: .utf8)!.write(to: url)

        let idx = SessionIndexer()
        let session = idx.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        let meta = s.events.filter { $0.kind == .meta }
        XCTAssertTrue(meta.contains(where: { $0.rawJSON.contains("[INSTRUCTIONS_OMITTED]") }))
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(hugeA.prefix(50))) }))
        XCTAssertFalse(meta.contains(where: { $0.rawJSON.contains(String(hugeB.prefix(50))) }))
    }

    func testClaudeSplitsThinkingAndToolBlocks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_sample.jsonl")
        let sessionID = "ses_testClaude"

        let lines = [
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","cwd":"/tmp","message":{"role":"user","content":"Hello"},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reasoning goes here."},{"type":"text","text":"I'll list files."},{"type":"tool_use","name":"bash","input":{"command":"ls"}}]},"uuid":"a1","timestamp":"2025-12-16T00:00:01.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":{"stdout":"file1\nfile2\n","stderr":"","is_error":false},"message":{"role":"assistant","content":[{"type":"tool_result","content":"ok"}]},"uuid":"a2","timestamp":"2025-12-16T00:00:02.000Z"}"#,
            #"{"type":"assistant","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"uuid":"a3","timestamp":"2025-12-16T00:00:03.000Z"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.contains("[thinking]") && $0.contains("Reasoning goes here.") }))

        let assistantTexts = parsed.events.filter { $0.kind == .assistant }.compactMap { $0.text }
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("I'll list files.") }))
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("Done.") }))

        let toolCalls = parsed.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "bash")
        XCTAssertNotNil(toolCalls.first?.toolInput)
        XCTAssertTrue(toolCalls.first?.toolInput?.contains("\"ls\"") ?? false)

        let toolResults = parsed.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertTrue(toolResults.first?.toolOutput?.contains("file1") ?? false)
    }

    func testClaudeFullParsePreservesCleanedLightweightTitle() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeTitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_title.jsonl")
        let caveat = "Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.\n<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>\n<local-command-stdout>Set model to haiku</local-command-stdout>"
        let encodedCaveat = caveat.replacingOccurrences(of: "\n", with: "\\n")
        let lines = [
            #"{"type":"user","sessionId":"ses_title","version":"2.0.71","cwd":"/tmp","message":{"role":"user","content":"\#(encodedCaveat)"},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#,
            #"{"type":"user","sessionId":"ses_title","version":"2.0.71","cwd":"/tmp","message":{"role":"user","content":"Real prompt after model switch"},"uuid":"u2","timestamp":"2025-12-16T00:00:01.000Z"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let preview = try XCTUnwrap(ClaudeSessionParser.parseFile(at: url))
        let full = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url))

        XCTAssertEqual(preview.listTitle, "Real prompt after model switch")
        XCTAssertEqual(full.lightweightTitle, preview.lightweightTitle)
        XCTAssertEqual(full.listTitle, preview.listTitle)
        XCTAssertFalse(full.listTitle.contains("Caveat:"))
        XCTAssertFalse(full.listTitle.contains("<local-command-"))
    }

    func testClaudeToolResultErrorClassification() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-Errors-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_errors.jsonl")
        let sessionID = "ses_testClaudeErrors"

        // 1) Runtime-ish: exit non-zero => .error
        // 2) Not found => keep as .tool_result
        // 3) User rejected tool use => meta (hidden by default)
        // 4) Interrupted => .error
        let lines = [
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","message":{"role":"user","content":"Start"},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: Exit code 1\nsomething failed","message":{"role":"user","content":[{"type":"tool_result","content":"x","is_error":true}]},"uuid":"u2","timestamp":"2025-12-16T00:00:01.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: File does not exist.","message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>File does not exist.</tool_use_error>","is_error":true}]},"uuid":"u3","timestamp":"2025-12-16T00:00:02.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: The user doesn't want to proceed with this tool use. The tool use was rejected.","message":{"role":"user","content":[{"type":"tool_result","content":"rejected","is_error":true}]},"uuid":"u4","timestamp":"2025-12-16T00:00:03.000Z"}"#,
            #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":"Error: [Request interrupted by user for tool use]","message":{"role":"user","content":[{"type":"tool_result","content":"interrupted","is_error":true}]},"uuid":"u5","timestamp":"2025-12-16T00:00:04.000Z"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let errorTexts = parsed.events.filter { $0.kind == .error }.compactMap { $0.text }
        XCTAssertEqual(errorTexts.count, 2)
        XCTAssertTrue(errorTexts.contains(where: { $0.contains("Exit code 1") }))
        XCTAssertTrue(errorTexts.contains(where: { $0.localizedCaseInsensitiveContains("interrupted") }))

        let toolResults = parsed.events.filter { $0.kind == .tool_result }.compactMap { $0.toolOutput }
        XCTAssertTrue(toolResults.contains(where: { $0.localizedCaseInsensitiveContains("file does not exist") }))

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.localizedCaseInsensitiveContains("Rejected tool use:") }))
    }

    func testClaudeToolResultEmbeddedImageIsSummarizedAndSanitized() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-Images-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_images.jsonl")
        let sessionID = "ses_testClaudeImages"

        // Simulate Chrome MCP screenshots (tool_result content blocks with base64 image payloads).
        let bigBase64 = String(repeating: "A", count: 120_000)
        let line = #"""
{"type":"user","sessionId":"\#(sessionID)","version":"2.0.76","cwd":"/tmp","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_img","content":[{"type":"text","text":"Captured screenshot."},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(bigBase64)"}}]}]},"uuid":"u1","timestamp":"2026-01-04T20:50:23.199Z"}
"""#
        try (line + "\n").data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        let toolResults = parsed.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        let output = toolResults[0].toolOutput ?? ""
        XCTAssertTrue(output.contains("Captured screenshot."))
        XCTAssertTrue(output.contains("[image omitted:"), "Expected tool output to summarize embedded image payloads")
        XCTAssertFalse(output.contains(String(bigBase64.prefix(64))), "Should not surface raw base64 image data in tool output")

        // rawJSON is base64-wrapped JSON; decode and ensure large strings were sanitized.
        let raw = toolResults[0].rawJSON
        let decoded = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(decoded.contains("[OMITTED bytes="), "Expected raw JSON to redact large embedded strings")
        XCTAssertFalse(decoded.contains(String(bigBase64.prefix(64))), "Should not keep raw base64 image payloads in raw JSON")
    }

    func testCopilotJoinsToolExecutionByToolCallId() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("copilot_sample.jsonl")
        let sessionID = "copilot_test_123"

        let lines = [
            #"{"type":"session.start","data":{"sessionId":"\#(sessionID)","version":1,"producer":"copilot-agent","copilotVersion":"0.0.372","startTime":"2025-12-18T21:32:04.182Z"},"id":"e1","timestamp":"2025-12-18T21:32:04.183Z","parentId":null}"#,
            #"{"type":"session.model_change","data":{"newModel":"gpt-5-mini"},"id":"e2","timestamp":"2025-12-18T21:32:05.000Z","parentId":"e1"}"#,
            #"{"type":"session.info","data":{"infoType":"folder_trust","message":"Folder /tmp/repo has been added to trusted folders."},"id":"e3","timestamp":"2025-12-18T21:32:06.000Z","parentId":"e2"}"#,
            #"{"type":"user.message","data":{"content":"Hello","transformedContent":"Hello","attachments":[]},"id":"e4","timestamp":"2025-12-18T21:32:07.000Z","parentId":"e3"}"#,
            #"{"type":"assistant.message","data":{"content":"","toolRequests":[{"toolCallId":"call_1","name":"bash","arguments":{"command":"ls"}}]},"id":"e5","timestamp":"2025-12-18T21:32:08.000Z","parentId":"e4"}"#,
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call_1","success":true,"result":{"content":"file1\\n"}},"id":"e6","timestamp":"2025-12-18T21:32:09.000Z","parentId":"e5"}"#,
            #"{"type":"assistant.message","data":{"content":"Done","toolRequests":[]},"id":"e7","timestamp":"2025-12-18T21:32:10.000Z","parentId":"e6"}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = CopilotSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let s = session else { return }

        XCTAssertEqual(s.id, sessionID)
        XCTAssertEqual(s.model, "gpt-5-mini")
        XCTAssertEqual(s.cwd, "/tmp/repo")

        let assistants = s.events.filter { $0.kind == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.text, "Done")

        let toolCalls = s.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "bash")
        XCTAssertTrue(toolCalls.first?.toolInput?.contains("\"ls\"") ?? false)

        let toolResults = s.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.toolName, "bash")
        XCTAssertEqual(toolResults.first?.toolOutput, "file1\n")
    }

    func testClaudeFileReadToolResultDoesNotFalsePositiveExitCode() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-FileRead-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("claude_fileread.jsonl")
        let sessionID = "ses_testClaudeFileRead"

        // Claude read-file tool_result payloads can include line numbers like "219→ ...".
        // Previously our exit-code regex could match across the newline ("exit code\n220") and
        // mistakenly treat the next line number as a non-zero exit code, coloring the whole block red.
        let fileDump = """
             219→        // Check exit code
             220→        let exitCode = process.terminationStatus
        """
        let fileDumpEscaped = fileDump.replacingOccurrences(of: "\n", with: "\\n")
        let line = #"{"type":"user","sessionId":"\#(sessionID)","version":"2.0.71","toolUseResult":{"type":"file","file":{"filePath":"/tmp/ClaudeStatusService.swift","content":"\#(fileDumpEscaped)"}},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_abc","content":"\#(fileDumpEscaped)"}]},"uuid":"u1","timestamp":"2025-12-16T00:00:00.000Z"}"#
        try line.data(using: .utf8)!.write(to: url)

        let session = ClaudeSessionParser.parseFileFull(at: url)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        XCTAssertTrue(parsed.events.filter { $0.kind == .error }.isEmpty)
        let toolOutputs = parsed.events.filter { $0.kind == .tool_result }.compactMap { $0.toolOutput }
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertTrue(toolOutputs.first?.contains("Check exit code") ?? false)
    }

    func testOpenCodeParsesTextPartsIntoConversation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionID = "ses_testQuickCheckIn"
        let projectID = "global"

        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"))

        let sessionDir = storageRoot
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        let messageDir = storageRoot
            .appendingPathComponent("message", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)

        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: messageDir, withIntermediateDirectories: true)

        let createdMillis: Int64 = 1_700_000_000_000

        // Session record
        let sessionURL = sessionDir.appendingPathComponent("\(sessionID).json")
        let sessionJSON = """
        {
          "id": "\(sessionID)",
          "version": "1.0.test",
          "projectID": "\(projectID)",
          "directory": "/tmp",
          "title": "Quick check-in",
          "time": { "created": \(createdMillis), "updated": \(createdMillis + 1000) },
          "summary": { "additions": 0, "deletions": 0, "files": 0 }
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionURL)

        // User message record without summary (text lives only in part/*.json)
        let userMsgID = "msg_user_1"
        let userMsgJSON = """
        {
          "id": "\(userMsgID)",
          "sessionID": "\(sessionID)",
          "role": "user",
          "agent": "plan",
          "time": { "created": \(createdMillis + 10) }
        }
        """
        try userMsgJSON.data(using: .utf8)!.write(to: messageDir.appendingPathComponent("msg_0001.json"))

        // Assistant message record without summary (text lives only in part/*.json)
        let assistantMsgID = "msg_assistant_1"
        let assistantMsgJSON = """
        {
          "id": "\(assistantMsgID)",
          "sessionID": "\(sessionID)",
          "role": "assistant",
          "agent": "plan",
          "time": { "created": \(createdMillis + 20) },
          "providerID": "openrouter",
          "modelID": "anthropic/claude-haiku-4.5"
        }
        """
        try assistantMsgJSON.data(using: .utf8)!.write(to: messageDir.appendingPathComponent("msg_0002.json"))

        // Parts: actual user prompt + assistant response
        let partRoot = storageRoot.appendingPathComponent("part", isDirectory: true)
        let userPartDir = partRoot.appendingPathComponent(userMsgID, isDirectory: true)
        let assistantPartDir = partRoot.appendingPathComponent(assistantMsgID, isDirectory: true)
        try fm.createDirectory(at: userPartDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assistantPartDir, withIntermediateDirectories: true)

        let userPartJSON = """
        {
          "id": "prt_user_text_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(userMsgID)",
          "type": "text",
          "text": "Hello there",
          "time": { "start": \(createdMillis + 10), "end": \(createdMillis + 10) }
        }
        """
        try userPartJSON.data(using: .utf8)!.write(to: userPartDir.appendingPathComponent("prt_user_0001.json"))

        let assistantPartJSON = """
        {
          "id": "prt_assistant_text_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(assistantMsgID)",
          "type": "text",
          "text": "Hi! How can I help?",
          "time": { "start": \(createdMillis + 20), "end": \(createdMillis + 20) }
        }
        """
        try assistantPartJSON.data(using: .utf8)!.write(to: assistantPartDir.appendingPathComponent("prt_assistant_0001.json"))

        // Unknown part type should not crash import and should surface in JSON via meta events.
        let unknownPartJSON = """
        {
          "id": "prt_unknown_1",
          "sessionID": "\(sessionID)",
          "messageID": "\(assistantMsgID)",
          "type": "new-type",
          "payload": { "hello": "world" }
        }
        """
        try unknownPartJSON.data(using: .utf8)!.write(to: assistantPartDir.appendingPathComponent("prt_unknown_0002.json"))

        let preview = OpenCodeSessionParser.parseFile(at: sessionURL)
        XCTAssertEqual(preview?.customTitle, "Quick check-in")
        XCTAssertEqual(preview?.title, "Quick check-in")

        let session = OpenCodeSessionParser.parseFileFull(at: sessionURL)
        XCTAssertNotNil(session)
        guard let parsed = session else { return }

        XCTAssertEqual(parsed.customTitle, "Quick check-in")
        XCTAssertEqual(parsed.title, "Quick check-in")

        let userTexts = parsed.events.filter { $0.kind == .user }.compactMap { $0.text }
        let assistantTexts = parsed.events.filter { $0.kind == .assistant }.compactMap { $0.text }

        XCTAssertTrue(userTexts.contains(where: { $0.contains("Hello there") }), "Expected user text part to appear as a .user event")
        XCTAssertTrue(assistantTexts.contains(where: { $0.contains("Hi! How can I help?") }), "Expected assistant text part to appear as a .assistant event")

        let metaTexts = parsed.events.filter { $0.kind == .meta }.compactMap { $0.text }
        XCTAssertTrue(metaTexts.contains(where: { $0.contains("OpenCode part: new-type") }), "Expected unknown OpenCode part type to be preserved as a meta event for JSON view")

        // OpenCode's timestamp-only bootstrap name must not outrank the real
        // first user prompt in either the lightweight or hydrated row.
        let generatedTitleJSON = sessionJSON.replacingOccurrences(
            of: "Quick check-in",
            with: "New session - 2026-09-15T06:53:15.144Z"
        )
        try generatedTitleJSON.data(using: .utf8)!.write(to: sessionURL)
        let generatedPreview = try XCTUnwrap(OpenCodeSessionParser.parseFile(at: sessionURL))
        XCTAssertNil(generatedPreview.customTitle)
        XCTAssertEqual(generatedPreview.lightweightTitle, "Hello there")
        XCTAssertEqual(generatedPreview.listTitle, "Hello there")

        let generatedFull = try XCTUnwrap(OpenCodeSessionParser.parseFileFull(at: sessionURL))
        XCTAssertNil(generatedFull.customTitle)
        XCTAssertEqual(generatedFull.lightweightTitle, "Hello there")
        XCTAssertEqual(generatedFull.listTitle, "Hello there")
        XCTAssertFalse(OpenCodeSessionParser.isGeneratedDefaultSessionTitle("New session - planning"))

        // A blank summary title must not suppress the body fallback when older
        // JSON storage has no text part for the first user message.
        try fm.removeItem(at: userPartDir.appendingPathComponent("prt_user_0001.json"))
        let summaryFallbackMessage = """
        {
          "id": "\(userMsgID)",
          "sessionID": "\(sessionID)",
          "role": "user",
          "time": { "created": \(createdMillis + 10) },
          "summary": { "title": "   ", "body": "Summary body fallback" }
        }
        """
        try summaryFallbackMessage.data(using: .utf8)!.write(to: messageDir.appendingPathComponent("msg_0001.json"))
        let summaryFallbackPreview = try XCTUnwrap(OpenCodeSessionParser.parseFile(at: sessionURL))
        XCTAssertEqual(summaryFallbackPreview.listTitle, "Summary body fallback")
    }

    func testHermesUnwrapDelegateOutputDecodesDoubleEncodedSummary() {
        let raw = #"{"results":[{"task_index":0,"status":"completed","summary":"{\"passed\":true,\"notes\":\"fine\"}","api_calls":4,"duration_seconds":12.0}]}"#
        let out = HermesSessionParser.unwrapDelegateOutput(raw)
        XCTAssertTrue(out.hasPrefix("Subtask 0 · completed · 12s · 4 API calls\n\n"), out)
        XCTAssertTrue(out.contains("\"passed\" : true"), out)
        XCTAssertFalse(out.contains("\\\""), "summary must be decoded, not left escaped: \(out)")
        XCTAssertEqual(HermesSessionParser.unwrapDelegateOutput("plain text"), "plain text")
    }

    func testQwenToolResponseTextUnwrapsOutputEnvelope() {
        XCTAssertEqual(QwenSessionParser.toolResponseText(["output": "# Report\n\nline"]), "# Report\n\nline")
        XCTAssertEqual(QwenSessionParser.toolResponseText(["error": "boom"]), "boom")
        XCTAssertEqual(QwenSessionParser.toolResponseText(["output": "x", "extra": 1])?.contains("extra"), true)
    }

    func testPiParentSessionIDStripsTimestampPrefix() {
        let id = "019e19c9-1b2c-7d3e-8f4a-0123456789ab"
        XCTAssertEqual(PiSessionParser.parentSessionID(from: "/x/2026-05-12T01-24-44-826Z_\(id).jsonl"), id)
        XCTAssertEqual(PiSessionParser.parentSessionID(from: "/x/\(id).jsonl"), id)
        XCTAssertEqual(PiSessionParser.parentSessionID(from: "/x/legacy_name.jsonl"), "legacy_name")
        XCTAssertNil(PiSessionParser.parentSessionID(from: nil))
    }

    func testOpenCodeUnwrapTaskOutputStripsEnvelopeAndSurfacesChildSession() {
        let raw = "<task id=\"ses_child1\" state=\"completed\">\n<task_result>\n# Audit\n\nline two\n</task_result>\n</task>"
        let out = OpenCodeSessionParser.unwrapTaskOutput(raw, childSessionID: nil)
        XCTAssertEqual(out, "Subagent session: ses_child1\n\n# Audit\n\nline two")

        let legacy = "Answer body.\n\n<task_metadata>\nsession_id: ses_child2\n</task_metadata>"
        XCTAssertEqual(OpenCodeSessionParser.unwrapTaskOutput(legacy, childSessionID: nil),
                       "Subagent session: ses_child2\n\nAnswer body.")

        let empty = "<task id=\"ses_x\" state=\"completed\">\n<task_result>\n</task_result>\n</task>"
        XCTAssertEqual(OpenCodeSessionParser.unwrapTaskOutput(empty, childSessionID: "ses_meta"),
                       "Subagent session: ses_meta\n(subagent returned no result)")

        XCTAssertEqual(OpenCodeSessionParser.unwrapTaskOutput("plain", childSessionID: nil), "plain")
    }

    func testOpenCodeToolExitCodeClassifiesErrorAndAppendsExitCode() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-Exit-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let sessionDir = storageRoot.appendingPathComponent("session", isDirectory: true).appendingPathComponent("proj", isDirectory: true)
        let messageRoot = storageRoot.appendingPathComponent("message", isDirectory: true)
        let partRoot = storageRoot.appendingPathComponent("part", isDirectory: true)

        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: messageRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: partRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"))

        let sessionID = "ses_exit_demo"
        let sessionURL = sessionDir.appendingPathComponent("\(sessionID).json")
        try #"{"id":"\#(sessionID)","version":"1.1.3","projectID":"proj","directory":"/tmp/repo","time":{"created":1730000000000,"updated":1730000001000}}"#.data(using: .utf8)!.write(to: sessionURL)

        let messageDir = messageRoot.appendingPathComponent(sessionID, isDirectory: true)
        try fm.createDirectory(at: messageDir, withIntermediateDirectories: true)

        let msgID = "msg_tool_demo"
        let msgURL = messageDir.appendingPathComponent("\(msgID).json")
        try #"{"id":"\#(msgID)","sessionID":"\#(sessionID)","role":"assistant","time":{"created":1730000000000},"agent":"opencode","model":{"providerID":"openai","modelID":"gpt-4o-mini"}}"#.data(using: .utf8)!.write(to: msgURL)

        let partDir = partRoot.appendingPathComponent(msgID, isDirectory: true)
        try fm.createDirectory(at: partDir, withIntermediateDirectories: true)

        let partJSON = """
        {
          "id": "prt_tool_0001",
          "sessionID": "\(sessionID)",
          "messageID": "\(msgID)",
          "type": "tool",
          "callID": "call_1",
          "tool": "bash",
          "state": {
            "status": "completed",
            "input": { "command": "ls /non-existent-directory" },
            "output": "ls: /non-existent-directory: No such file or directory\\n",
            "metadata": { "exit": 1 },
            "time": { "start": 1730000000000, "end": 1730000000100 }
          }
        }
        """
        try partJSON.data(using: .utf8)!.write(to: partDir.appendingPathComponent("prt_0001.json"))

        guard let session = OpenCodeSessionParser.parseFileFull(at: sessionURL) else { return XCTFail("parse returned nil") }
        XCTAssertTrue(session.events.contains(where: { $0.kind == .tool_call }))
        let errorEvents = session.events.filter { $0.kind == .error }
        XCTAssertEqual(errorEvents.count, 1)
        XCTAssertTrue((errorEvents.first?.toolOutput ?? "").contains("Exit Code: 1"))
    }

    func testOpenCodeDiscoveryAcceptsStorageRootOverride() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let storageRoot = root.appendingPathComponent("storage", isDirectory: true)
        let sessionDir = storageRoot.appendingPathComponent("session", isDirectory: true).appendingPathComponent("global", isDirectory: true)
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try "2".data(using: .utf8)!.write(to: storageRoot.appendingPathComponent("migration"))

        let sessionURL = sessionDir.appendingPathComponent("ses_demo.json")
        try #"{"id":"ses_demo","time":{"created":1700000000000}}"#.data(using: .utf8)!.write(to: sessionURL)

        let discovery = OpenCodeSessionDiscovery(customRoot: storageRoot.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "ses_demo.json")
    }

    func testOpenCodeSqliteReaderLoadsCurrentDatabaseLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-SQLite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("opencode.db")
        try createOpenCodeSQLiteFixture(at: dbURL)

        XCTAssertTrue(OpenCodeBackendDetector.isSQLiteAvailable(customRoot: dbURL.path))

        let sessions = OpenCodeSqliteReader.listSessions(customRoot: dbURL.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "ses_sqlite_demo")
        XCTAssertEqual(sessions.first?.cwd, "/tmp/repo")
        XCTAssertEqual(sessions.first?.model, "big-pickle")
        XCTAssertEqual(sessions.first?.eventCount, 2)
        XCTAssertEqual(sessions.first?.customTitle, "SQLite demo")
        XCTAssertEqual(sessions.first?.title, "SQLite demo")

        guard let full = OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo") else {
            return XCTFail("full SQLite parse returned nil")
        }
        XCTAssertEqual(full.customTitle, "SQLite demo")
        XCTAssertEqual(full.title, "SQLite demo")
        XCTAssertTrue(full.events.contains { $0.kind == .user && ($0.text ?? "").contains("Hello from SQLite") })
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("SQLite response") })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "grep" })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result && ($0.toolOutput ?? "").contains("Found 1 match") })

        // Session Info labels the indexed model as current. A later message
        // must therefore replace the earlier model in both the lightweight
        // row and the hydrated session; otherwise a model switch is silently
        // presented as first-observed/current confusion.
        try executeSQLite("""
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_latest_model', 'ses_sqlite_demo', 1776370003000, 1776370003000,
                '{"role":"assistant","modelID":"latest-model","providerID":"opencode"}');
        """, at: dbURL)
        let switchedPreview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertEqual(switchedPreview.model, "latest-model")
        XCTAssertEqual(SessionInfoQuickFacts(session: switchedPreview).currentModel.value, "latest-model")
        let switchedFull = try XCTUnwrap(
            OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")
        )
        XCTAssertEqual(switchedFull.model, "latest-model")

        // Current OpenCode schemas carry a session-level effective model. It
        // remains authoritative even when the last assistant message predates
        // a user-side model switch.
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN model TEXT;
        UPDATE session
        SET model = '{"id":"authoritative-current","providerID":"opencode"}'
        WHERE id = 'ses_sqlite_demo';
        """, at: dbURL)
        let authoritativePreview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertEqual(authoritativePreview.model, "authoritative-current")
        let authoritativeFull = try XCTUnwrap(
            OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")
        )
        XCTAssertEqual(authoritativeFull.model, "authoritative-current")

        try executeSQLite("""
        UPDATE session
        SET model = NULL
        WHERE id = 'ses_sqlite_demo';
        """, at: dbURL)
        XCTAssertNil(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first?.model)
        XCTAssertNil(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")?.model)

        // A present session.model column remains authoritative even when its
        // JSON is unrecognized or malformed. Message metadata must not be
        // relabelled as the current model in either quick or full loading.
        try executeSQLite("""
        UPDATE session
        SET model = '{"providerID":"opencode"}'
        WHERE id = 'ses_sqlite_demo';
        """, at: dbURL)
        let unknownPreview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertNil(unknownPreview.model)
        let unknownFull = try XCTUnwrap(
            OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")
        )
        XCTAssertNil(unknownFull.model)

        try executeSQLite("""
        UPDATE session
        SET model = '{"id":'
        WHERE id = 'ses_sqlite_demo';
        """, at: dbURL)
        XCTAssertNil(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first?.model)
        XCTAssertNil(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")?.model)

        try executeSQLite("""
        UPDATE session
        SET title = 'New session - 2026-09-15T06:53:15.144Z'
        WHERE id = 'ses_sqlite_demo';
        """, at: dbURL)

        // Keep the first user message beyond the existing 20-record model
        // probe. Generated-title recognition must continue until it finds it.
        let assistantPrelude = (0..<21).map { index in
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES ('msg_prelude_\(index)', 'ses_sqlite_demo', \(1776369990000 + index), \(1776369990000 + index), '{"role":"assistant"}');
            """
        }.joined(separator: "\n")
        try executeSQLite(assistantPrelude, at: dbURL)

        let generatedPreview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertNil(generatedPreview.customTitle)
        XCTAssertEqual(generatedPreview.lightweightTitle, "Hello from SQLite")
        XCTAssertEqual(generatedPreview.listTitle, "Hello from SQLite")

        let generatedFull = try XCTUnwrap(
            OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")
        )
        XCTAssertNil(generatedFull.customTitle)
        XCTAssertEqual(generatedFull.lightweightTitle, "Hello from SQLite")
        XCTAssertEqual(generatedFull.listTitle, "Hello from SQLite")

        try executeSQLite("""
        DELETE FROM part WHERE id = 'prt_user_text_sqlite';
        UPDATE message
        SET data = '{"role":"user","summary":{"title":"   ","body":"SQLite summary fallback"}}'
        WHERE id = 'msg_user_sqlite';
        """, at: dbURL)
        let summaryFallbackPreview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertEqual(summaryFallbackPreview.listTitle, "SQLite summary fallback")
    }

    func testOpenCodeSqliteReaderFindsLegacyModelBeyondQuickProbe() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-LegacyModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("opencode.db")
        try createOpenCodeSQLiteFixture(at: dbURL)

        let noModelMessages = (0..<21).map { index in
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data)
            VALUES ('msg_legacy_padding_\(index)', 'ses_sqlite_demo', \(1776370004000 + index), \(1776370004000 + index), '{"role":"assistant"}');
            """
        }.joined(separator: "\n")
        try executeSQLite(noModelMessages, at: dbURL)
        try executeSQLite("""
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_legacy_model_after_probe', 'ses_sqlite_demo', 1776370005000, 1776370005000,
                '{"role":"assistant","modelID":"legacy-model-beyond-probe","providerID":"opencode"}');
        """, at: dbURL)

        let preview = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertEqual(preview.model, "legacy-model-beyond-probe")
        let full = try XCTUnwrap(
            OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_sqlite_demo")
        )
        XCTAssertEqual(full.model, "legacy-model-beyond-probe")
    }

    func testOpenCodeSQLiteSearchIngestTracksIdentityUpdatesAndRemoval() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenCode-SearchIngest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("opencode.db")
        try createOpenCodeSQLiteFixture(at: dbURL)
        try executeSQLite("""
        INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
        VALUES ('ses_sqlite_second', 'proj_sqlite', NULL, 'sqlite-second', '/tmp/repo', 'SQLite second', '1.4.6', 1776370010000, 1776370012000, NULL);
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_second', 'ses_sqlite_second', 1776370010000, 1776370012000, '{"role":"assistant","modelID":"big-pickle","providerID":"opencode"}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('prt_second', 'msg_second', 'ses_sqlite_second', 1776370010000, 1776370012000, '{"type":"text","text":"Second identity marker","time":{"start":1776370010000,"end":1776370012000}}');
        """, at: dbURL)

        let baselineStat = try XCTUnwrap(SessionFileStat.from(dbURL))
        func refs() -> [SearchIngestService.FileRef] {
            OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).map { session in
                SearchIngestService.FileRef(
                    path: dbURL.path,
                    mtime: baselineStat.mtime,
                    size: baselineStat.size,
                    sessionID: session.id,
                    contentRevision: SearchIngestService.contentRevision(for: session)
                )
            }
        }
        func identitySnapshot() -> SearchIngestService.IdentitySnapshot {
            SearchIngestService.IdentitySnapshot(
                storagePaths: [dbURL.path],
                sessionIDs: Set(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).map(\.id))
            )
        }

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: indexDB)
        let progress = try await service.ingest(source: .opencode,
                                                files: refs(),
                                                toolIOEnabled: false,
                                                identitySnapshot: identitySnapshot(),
                                                quietSeconds: 0,
                                                reingestCooldownOverride: 0)
        XCTAssertEqual(progress.processed, 2)
        try await indexDB.begin()
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()
        let initialAnalyticsUpdates = try await indexDB.findSessionsNeedingDayUpdate(
            source: SessionSource.opencode.rawValue
        )
        XCTAssertTrue(initialAnalyticsUpdates.isEmpty)

        // The logical extent is the second half of the identity revision. Change it
        // without changing the session timestamp or the caller-supplied shared DB stat.
        try executeSQLite("""
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('msg_second_same_time', 'ses_sqlite_second', 1776370011000, 1776370012000, '{"role":"assistant","modelID":"big-pickle","providerID":"opencode"}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('prt_second_same_time', 'msg_second_same_time', 'ses_sqlite_second', 1776370011000, 1776370012000, '{"type":"text","text":"Same timestamp extent marker","time":{"start":1776370011000,"end":1776370012000}}');
        """, at: dbURL)
        let extentProgress = try await service.ingest(source: .opencode,
                                                      files: refs(),
                                                      toolIOEnabled: false,
                                                      identitySnapshot: identitySnapshot(),
                                                      quietSeconds: 0,
                                                      reingestCooldownOverride: 0)
        XCTAssertEqual(extentProgress.processed, 1)
        XCTAssertEqual(extentProgress.skipped, 1)
        let extentAnalyticsUpdates = try await indexDB.findSessionsNeedingDayUpdate(source: SessionSource.opencode.rawValue)
        XCTAssertEqual(extentAnalyticsUpdates, ["ses_sqlite_second"])
        try await indexDB.begin()
        let extentDays = try await indexDB.populateSessionDaysFromMetaIncremental(
            sessionIDs: extentAnalyticsUpdates,
            source: SessionSource.opencode.rawValue
        )
        try await indexDB.recomputeRollupsForDays(extentDays, source: SessionSource.opencode.rawValue)
        try await indexDB.commit()

        // A provider read failure is represented by a nil snapshot. Empty current
        // files in that state must preserve the last healthy corpus.
        _ = try await service.ingest(source: .opencode,
                                     files: [],
                                     toolIOEnabled: false,
                                     identitySnapshot: nil,
                                     quietSeconds: 0,
                                     reingestCooldownOverride: 0)
        let rowsAfterFailedRead = try await indexDB.rowCountForTesting(table: "session_search",
                                                                       source: "opencode")
        XCTAssertEqual(rowsAfterFailedRead, 2)

        var matches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue],
            model: nil,
            repoSubstr: nil,
            pathSubstr: nil,
            dateFrom: nil,
            dateTo: nil,
            query: "SQLite response",
            includeSystemProbes: true,
            limit: 10
        )
        XCTAssertEqual(matches, ["ses_sqlite_demo"])

        matches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue], model: nil, repoSubstr: nil,
            pathSubstr: nil, dateFrom: nil, dateTo: nil, query: "Second identity marker",
            includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(matches, ["ses_sqlite_second"])

        // Change only one logical session while continuing to report the exact same
        // shared-database file stat, as can happen while SQLite changes live in the WAL.
        try executeSQLite("""
        UPDATE session SET time_updated = 1776370022000 WHERE id = 'ses_sqlite_demo';
        UPDATE part SET data = '{"type":"text","text":"Updated response","time":{"start":1776370001000,"end":1776370022000}}',
                        time_updated = 1776370022000
        WHERE id = 'prt_assistant_text_sqlite';
        """, at: dbURL)
        let updateProgress = try await service.ingest(source: .opencode,
                                                      files: refs(),
                                                      toolIOEnabled: false,
                                                      identitySnapshot: identitySnapshot(),
                                                      quietSeconds: 0,
                                                      reingestCooldownOverride: 0)
        XCTAssertEqual(updateProgress.processed, 1)
        XCTAssertEqual(updateProgress.skipped, 1)
        let analyticsUpdates = try await indexDB.findSessionsNeedingDayUpdate(source: SessionSource.opencode.rawValue)
        XCTAssertEqual(analyticsUpdates, ["ses_sqlite_demo"],
                       "a per-session revision must invalidate analytics even when the shared DB stat is unchanged")
        matches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue], model: nil, repoSubstr: nil,
            pathSubstr: nil, dateFrom: nil, dateTo: nil, query: "Updated response",
            includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(matches, ["ses_sqlite_demo"])

        // Archive one identity without removing the shared database path. Its FTS row
        // must be pruned so it cannot consume the SQL result limit ahead of live rows.
        try executeSQLite("UPDATE session SET time_archived = 1776370030000 WHERE id = 'ses_sqlite_second';",
                          at: dbURL)
        _ = try await service.ingest(source: .opencode,
                                     files: refs(),
                                     toolIOEnabled: false,
                                     identitySnapshot: identitySnapshot(),
                                     quietSeconds: 0,
                                     reingestCooldownOverride: 0)
        matches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue], model: nil, repoSubstr: nil,
            pathSubstr: nil, dateFrom: nil, dateTo: nil, query: "Second identity marker",
            includeSystemProbes: true, limit: 10
        )
        XCTAssertTrue(matches.isEmpty)

        // Exercise the empty-input reconciliation used when the final DB identity
        // disappears. Seed derived analytics first so the assertion covers the whole
        // identity lifecycle, not only the FTS tables.
        try await indexDB.begin()
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()
        try executeSQLite("UPDATE session SET time_archived = 1776370040000 WHERE id = 'ses_sqlite_demo';",
                          at: dbURL)
        _ = try await service.ingest(source: .opencode,
                                     files: [],
                                     toolIOEnabled: false,
                                     identitySnapshot: .authoritativeEmpty(storagePath: dbURL.path),
                                     quietSeconds: 0,
                                     reingestCooldownOverride: 0)

        let searchRows = try await indexDB.rowCountForTesting(table: "session_search", source: "opencode")
        let metaRows = try await indexDB.rowCountForTesting(table: "session_meta", source: "opencode")
        let dayRows = try await indexDB.rowCountForTesting(table: "session_days", source: "opencode")
        let rollupRows = try await indexDB.rowCountForTesting(table: "rollups_daily", source: "opencode")
        XCTAssertEqual(searchRows, 0)
        XCTAssertEqual(metaRows, 0)
        XCTAssertEqual(dayRows, 0)
        XCTAssertEqual(rollupRows, 0)
    }

    func testOpenCodeSQLiteSearchIngestMovesSameRevisionToPinnedArchiveThenRetiresIt() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenCode-PinnedArchive-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }

        let liveRoot = root.appendingPathComponent("live", isDirectory: true)
        let archiveRoot = root.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let liveDBURL = liveRoot.appendingPathComponent("opencode.db")
        let archiveDBURL = archiveRoot.appendingPathComponent("opencode.db")
        try createOpenCodeSQLiteFixture(at: liveDBURL)
        try fm.copyItem(at: liveDBURL, to: archiveDBURL)

        let liveSession = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: liveDBURL.path).first)
        let sharedStat = try XCTUnwrap(SessionFileStat.from(liveDBURL))
        let liveRef = SearchIngestService.FileRef(
            path: liveDBURL.path,
            mtime: sharedStat.mtime,
            size: sharedStat.size,
            sessionID: liveSession.id,
            contentRevision: SearchIngestService.contentRevision(for: liveSession)
        )
        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: indexDB)

        let liveProgress = try await service.ingest(
            source: .opencode,
            files: [liveRef],
            toolIOEnabled: false,
            identitySnapshot: SearchIngestService.IdentitySnapshot(
                storagePaths: [liveDBURL.path],
                sessionIDs: [liveSession.id]
            ),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(liveProgress.processed, 1)

        // The same identity and revision moves to a pinned archive while the provider's
        // live database becomes authoritatively empty. Supply the exact same physical
        // stat so only FileRef path + snapshot authority can invalidate the clean pass.
        try executeSQLite(
            "UPDATE session SET time_archived = 1776370040000 WHERE id = 'ses_sqlite_demo';",
            at: liveDBURL
        )
        let archivedSession = try XCTUnwrap(
            OpenCodeSqliteReader.listSessions(customRoot: archiveDBURL.path).first
        )
        let archiveRevision = SearchIngestService.contentRevision(for: archivedSession)
        let liveRevision = try XCTUnwrap(liveRef.contentRevision)
        XCTAssertEqual(archiveRevision, liveRevision)
        let archiveRef = SearchIngestService.FileRef(
            path: archiveDBURL.path,
            mtime: sharedStat.mtime,
            size: sharedStat.size,
            sessionID: archivedSession.id,
            contentRevision: archiveRevision
        )
        let archiveProgress = try await service.ingest(
            source: .opencode,
            files: [archiveRef],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(archiveProgress.processed, 1,
                       "same-revision path moves must re-ingest instead of aggregate/readiness skipping")

        let matches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue],
            model: nil,
            repoSubstr: nil,
            pathSubstr: nil,
            dateFrom: nil,
            dateTo: nil,
            query: "SQLite response",
            includeSystemProbes: true,
            limit: 10
        )
        XCTAssertEqual(matches, ["ses_sqlite_demo"],
                       "live identity cleanup must preserve a pinned archive DB fallback")
        let persistedPaths = try await indexDB.fetchSessionMetaPaths(for: SessionSource.opencode.rawValue)
        XCTAssertEqual(persistedPaths, [archiveDBURL.path])
        let ownedPaths = try await indexDB.searchIdentityStoragePaths(source: SessionSource.opencode.rawValue)
        XCTAssertEqual(ownedPaths, [liveDBURL.path, archiveDBURL.path])

        // Seed every identity-dependent surface, then unpin the archive. The previous
        // owned-path marker must retire it even though it is absent from current FileRefs.
        try await indexDB.begin()
        try await indexDB.upsertSessionToolIO(
            sessionID: archivedSession.id,
            source: SessionSource.opencode.rawValue,
            mtime: archiveRevision.updatedMillis,
            size: archiveRevision.extent,
            refTS: Int64(Date().timeIntervalSince1970),
            text: "archived tool marker"
        )
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()

        _ = try await service.ingest(
            source: .opencode,
            files: [],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )

        for table in ["session_search", "session_meta", "session_tool_io",
                      "session_days", "rollups_daily"] {
            let count = try await indexDB.rowCountForTesting(table: table, source: "opencode")
            XCTAssertEqual(count, 0, "unpinning the archive must clear \(table)")
        }
        let retainedFiles = try await indexDB.rowCountForTesting(table: "files", source: "opencode")
        XCTAssertEqual(retainedFiles, 2, "identity cleanup must retain both shared database file rows")
        let finalOwnedPaths = try await indexDB.searchIdentityStoragePaths(source: SessionSource.opencode.rawValue)
        XCTAssertEqual(finalOwnedPaths, [liveDBURL.path])
    }

    func testOpenCodeSQLiteSearchIngestRootOverrideRetiresPreviouslyOwnedDifferentIdentity() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenCode-RootOverride-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let oldDBURL = root.appendingPathComponent("old/opencode.db")
        let newDBURL = root.appendingPathComponent("new/opencode.db")
        try fm.createDirectory(at: oldDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: newDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenCodeSQLiteFixture(at: oldDBURL)
        try createOpenCodeSQLiteFixture(at: newDBURL)
        try executeSQLite("""
        UPDATE part
        SET data = replace(data, 'SQLite response', 'Old root unique marker');
        """, at: oldDBURL)
        try executeSQLite("""
        UPDATE part
        SET session_id = 'ses_sqlite_new_root',
            data = replace(data, 'SQLite response', 'New root unique marker');
        UPDATE message SET session_id = 'ses_sqlite_new_root';
        UPDATE session SET id = 'ses_sqlite_new_root', title = 'New root';
        """, at: newDBURL)

        func ref(for session: Session, at url: URL) throws -> SearchIngestService.FileRef {
            let stat = try XCTUnwrap(SessionFileStat.from(url))
            return SearchIngestService.FileRef(
                path: url.path,
                mtime: stat.mtime,
                size: stat.size,
                sessionID: session.id,
                contentRevision: SearchIngestService.contentRevision(for: session)
            )
        }

        let oldSession = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: oldDBURL.path).first)
        let newSession = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: newDBURL.path).first)
        XCTAssertNotEqual(oldSession.id, newSession.id)

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let firstService = SearchIngestService(db: indexDB)
        let oldProgress = try await firstService.ingest(
            source: .opencode,
            files: [try ref(for: oldSession, at: oldDBURL)],
            toolIOEnabled: false,
            identitySnapshot: SearchIngestService.IdentitySnapshot(
                storagePaths: [oldDBURL.path], sessionIDs: [oldSession.id]
            ),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(oldProgress.processed, 1)

        let oldRevision = SearchIngestService.contentRevision(for: oldSession)
        try await indexDB.begin()
        try await indexDB.upsertSessionToolIO(
            sessionID: oldSession.id,
            source: SessionSource.opencode.rawValue,
            mtime: oldRevision.updatedMillis,
            size: oldRevision.extent,
            refTS: Int64(Date().timeIntervalSince1970),
            text: "old root tool marker"
        )
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()

        // A fresh service proves the old root comes from persisted authority, not actor memory.
        let secondService = SearchIngestService(db: indexDB)
        let newProgress = try await secondService.ingest(
            source: .opencode,
            files: [try ref(for: newSession, at: newDBURL)],
            toolIOEnabled: false,
            identitySnapshot: SearchIngestService.IdentitySnapshot(
                storagePaths: [newDBURL.path], sessionIDs: [newSession.id]
            ),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(newProgress.processed, 1)

        let searchIDs = Set(try await indexDB.indexedSessionIDs(sources: [SessionSource.opencode.rawValue]))
        XCTAssertEqual(searchIDs, [newSession.id])
        let oldMetaIDs = try await indexDB.sessionIDs(
            source: SessionSource.opencode.rawValue,
            storagePaths: [oldDBURL.path]
        )
        let newMetaIDs = try await indexDB.sessionIDs(
            source: SessionSource.opencode.rawValue,
            storagePaths: [newDBURL.path]
        )
        XCTAssertTrue(oldMetaIDs.isEmpty)
        XCTAssertEqual(newMetaIDs, [newSession.id])
        let toolIDs = try await indexDB.toolIOSessionIDs(sources: [SessionSource.opencode.rawValue])
        XCTAssertFalse(toolIDs.contains(oldSession.id))
        let clearedDayCount = try await indexDB.rowCountForTesting(table: "session_days", source: "opencode")
        let clearedRollupCount = try await indexDB.rowCountForTesting(table: "rollups_daily", source: "opencode")
        XCTAssertEqual(clearedDayCount, 0)
        XCTAssertEqual(clearedRollupCount, 0)

        let oldMatches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue], model: nil, repoSubstr: nil,
            pathSubstr: nil, dateFrom: nil, dateTo: nil, query: "Old root unique marker",
            includeSystemProbes: true, limit: 10
        )
        let newMatches = try await indexDB.searchSessionIDsFTS(
            sources: [SessionSource.opencode.rawValue], model: nil, repoSubstr: nil,
            pathSubstr: nil, dateFrom: nil, dateTo: nil, query: "New root unique marker",
            includeSystemProbes: true, limit: 10
        )
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches, [newSession.id])

        try await indexDB.begin()
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()
        let rebuiltDayCount = try await indexDB.rowCountForTesting(table: "session_days", source: "opencode")
        let rebuiltRollupCount = try await indexDB.rowCountForTesting(table: "rollups_daily", source: "opencode")
        let finalOwnedPaths = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        let retainedFileCount = try await indexDB.rowCountForTesting(table: "files", source: "opencode")
        XCTAssertEqual(rebuiltDayCount, 1)
        XCTAssertEqual(rebuiltRollupCount, 1)
        XCTAssertEqual(finalOwnedPaths, [newDBURL.path])
        XCTAssertEqual(retainedFileCount, 2)
    }

    func testOpenCodeSQLiteFailedLiveReadPersistsArchiveAuthorityWithoutDeletingLiveRows() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenCode-FailedLiveRead-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let liveDBURL = root.appendingPathComponent("live/opencode.db")
        let archiveDBURL = root.appendingPathComponent("archive/opencode.db")
        let corruptArchiveDBURL = root.appendingPathComponent("corrupt-archive/opencode.db")
        try fm.createDirectory(at: liveDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: corruptArchiveDBURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenCodeSQLiteFixture(at: liveDBURL)
        try createOpenCodeSQLiteFixture(at: archiveDBURL)
        try writeText("not a sqlite database", to: corruptArchiveDBURL)
        try executeSQLite("""
        UPDATE part
        SET session_id = 'ses_sqlite_archive_only',
            data = replace(data, 'SQLite response', 'Archive-only response');
        UPDATE message SET session_id = 'ses_sqlite_archive_only';
        UPDATE session SET id = 'ses_sqlite_archive_only', title = 'Archive only';
        """, at: archiveDBURL)

        func ref(for session: Session, at url: URL) throws -> SearchIngestService.FileRef {
            let stat = try XCTUnwrap(SessionFileStat.from(url))
            return SearchIngestService.FileRef(
                path: url.path, mtime: stat.mtime, size: stat.size,
                sessionID: session.id,
                contentRevision: SearchIngestService.contentRevision(for: session)
            )
        }
        let liveSession = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: liveDBURL.path).first)
        let archiveSession = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: archiveDBURL.path).first)
        let corruptStat = try XCTUnwrap(SessionFileStat.from(corruptArchiveDBURL))
        let corruptArchiveRef = SearchIngestService.FileRef(
            path: corruptArchiveDBURL.path,
            mtime: corruptStat.mtime,
            size: corruptStat.size,
            sessionID: "ses_corrupt_archive",
            contentRevision: SearchIngestService.ContentRevision(
                updatedMillis: SearchIngestService.contentRevision(for: archiveSession).updatedMillis,
                extent: 1
            )
        )

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let firstService = SearchIngestService(db: indexDB)
        _ = try await firstService.ingest(
            source: .opencode,
            files: [try ref(for: liveSession, at: liveDBURL)],
            toolIOEnabled: false,
            identitySnapshot: SearchIngestService.IdentitySnapshot(
                storagePaths: [liveDBURL.path], sessionIDs: [liveSession.id]
            ),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )

        // nil represents a failed live enumeration. The pinned archive remains a
        // trustworthy FileRef, but the prior live path must not be reconciled away.
        let failedReadProgress = try await firstService.ingest(
            source: .opencode,
            files: [try ref(for: archiveSession, at: archiveDBURL), corruptArchiveRef],
            toolIOEnabled: false,
            identitySnapshot: nil,
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(failedReadProgress.processed, 1)
        XCTAssertEqual(failedReadProgress.skipped, 1)
        let IDsAfterFailure = Set(try await indexDB.indexedSessionIDs(sources: ["opencode"]))
        let pathsAfterFailure = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(IDsAfterFailure, [liveSession.id, archiveSession.id],
                       "failed live reads must not delete the prior healthy live corpus")
        XCTAssertEqual(pathsAfterFailure,
                       [liveDBURL.path, archiveDBURL.path, corruptArchiveDBURL.path],
                       "every current archive FileRef path must survive a sibling parse failure and service restart")

        // After restart, a healthy authoritative-empty live read plus no archive FileRef
        // retires both the now-empty live identity and the no-longer-pinned archive.
        let restartedService = SearchIngestService(db: indexDB)
        _ = try await restartedService.ingest(
            source: .opencode,
            files: [],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        let remainingSearch = try await indexDB.rowCountForTesting(table: "session_search", source: "opencode")
        let remainingMeta = try await indexDB.rowCountForTesting(table: "session_meta", source: "opencode")
        let finalOwnedPaths = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(remainingSearch, 0)
        XCTAssertEqual(remainingMeta, 0)
        XCTAssertEqual(finalOwnedPaths, [liveDBURL.path])
    }

    func testOpenCodeSQLiteHealthySnapshotReconcilesUnrelatedArchiveDespiteMovedIdentityParseFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenCode-MixedArchiveFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        let liveDBURL = root.appendingPathComponent("live/opencode.db")
        let oldMovedDBURL = root.appendingPathComponent("old-moved/opencode.db")
        let staleArchiveDBURL = root.appendingPathComponent("stale-archive/opencode.db")
        let currentValidDBURL = root.appendingPathComponent("current-valid/opencode.db")
        let failedMovedDBURL = root.appendingPathComponent("failed-moved/opencode.db")
        for directory in [liveDBURL, oldMovedDBURL, staleArchiveDBURL,
                          currentValidDBURL, failedMovedDBURL].map({ $0.deletingLastPathComponent() }) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try createOpenCodeSQLiteFixture(at: oldMovedDBURL)
        try createOpenCodeSQLiteFixture(at: staleArchiveDBURL)
        try createOpenCodeSQLiteFixture(at: currentValidDBURL)
        try writeText("not a sqlite database", to: failedMovedDBURL)
        try executeSQLite("""
        UPDATE part
        SET session_id = 'ses_moved_current',
            data = replace(data, 'SQLite response', 'Protected moved marker');
        UPDATE message SET session_id = 'ses_moved_current';
        UPDATE session SET id = 'ses_moved_current', title = 'Moved current';
        """, at: oldMovedDBURL)
        try executeSQLite("""
        UPDATE part
        SET session_id = 'ses_unrelated_stale',
            data = replace(data, 'SQLite response', 'Unrelated stale marker');
        UPDATE message SET session_id = 'ses_unrelated_stale';
        UPDATE session SET id = 'ses_unrelated_stale', title = 'Unrelated stale';
        """, at: staleArchiveDBURL)
        try executeSQLite("""
        UPDATE part
        SET session_id = 'ses_current_valid',
            data = replace(data, 'SQLite response', 'Current valid marker');
        UPDATE message SET session_id = 'ses_current_valid';
        UPDATE session SET id = 'ses_current_valid', title = 'Current valid';
        """, at: currentValidDBURL)

        func ref(for session: Session, at url: URL) throws -> SearchIngestService.FileRef {
            let stat = try XCTUnwrap(SessionFileStat.from(url))
            return SearchIngestService.FileRef(
                path: url.path, mtime: stat.mtime, size: stat.size,
                sessionID: session.id,
                contentRevision: SearchIngestService.contentRevision(for: session)
            )
        }

        let oldMovedSession = try XCTUnwrap(
            OpenCodeSqliteReader.listSessions(customRoot: oldMovedDBURL.path).first
        )
        let staleSession = try XCTUnwrap(
            OpenCodeSqliteReader.listSessions(customRoot: staleArchiveDBURL.path).first
        )
        let currentValidSession = try XCTUnwrap(
            OpenCodeSqliteReader.listSessions(customRoot: currentValidDBURL.path).first
        )
        let failedMovedStat = try XCTUnwrap(SessionFileStat.from(failedMovedDBURL))
        let failedMovedRef = SearchIngestService.FileRef(
            path: failedMovedDBURL.path,
            mtime: failedMovedStat.mtime,
            size: failedMovedStat.size,
            sessionID: oldMovedSession.id,
            contentRevision: SearchIngestService.contentRevision(for: oldMovedSession)
        )

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: indexDB)

        let initialProgress = try await service.ingest(
            source: .opencode,
            files: [try ref(for: oldMovedSession, at: oldMovedDBURL),
                    try ref(for: staleSession, at: staleArchiveDBURL)],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(initialProgress.processed, 2)

        let staleRevision = SearchIngestService.contentRevision(for: staleSession)
        try await indexDB.begin()
        try await indexDB.upsertSessionToolIO(
            sessionID: staleSession.id,
            source: SessionSource.opencode.rawValue,
            mtime: staleRevision.updatedMillis,
            size: staleRevision.extent,
            refTS: Int64(Date().timeIntervalSince1970),
            text: "unrelated stale tool marker"
        )
        _ = try await indexDB.populateSessionDaysFromMeta(for: SessionSource.opencode.rawValue)
        try await indexDB.recomputeAllRollups(for: SessionSource.opencode.rawValue)
        try await indexDB.commit()

        // The provider snapshot is authoritative even though one current archive fails
        // to parse. X moved from oldMovedDBURL to failedMovedDBURL, so its last good row
        // and old path must remain protected. The absent unrelated stale archive is safe
        // to retire, while the current valid sibling still ingests normally.
        let mixedProgress = try await service.ingest(
            source: .opencode,
            files: [try ref(for: currentValidSession, at: currentValidDBURL), failedMovedRef],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        XCTAssertEqual(mixedProgress.processed, 1)
        XCTAssertEqual(mixedProgress.skipped, 1)
        let indexedAfterFailure = Set(try await indexDB.indexedSessionIDs(sources: ["opencode"]))
        XCTAssertEqual(indexedAfterFailure, [oldMovedSession.id, currentValidSession.id])
        let oldMovedIDs = try await indexDB.sessionIDs(
            source: "opencode", storagePaths: [oldMovedDBURL.path]
        )
        let staleIDs = try await indexDB.sessionIDs(
            source: "opencode", storagePaths: [staleArchiveDBURL.path]
        )
        let failedMovedIDs = try await indexDB.sessionIDs(
            source: "opencode", storagePaths: [failedMovedDBURL.path]
        )
        XCTAssertEqual(oldMovedIDs, [oldMovedSession.id],
                       "a failed moved identity must retain its last good persisted row")
        XCTAssertTrue(staleIDs.isEmpty,
                      "a sibling parse failure must not preserve an unrelated absent identity")
        XCTAssertTrue(failedMovedIDs.isEmpty,
                      "the failed destination must not claim a metadata row before a successful parse")
        let ownedAfterFailure = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(ownedAfterFailure,
                       [liveDBURL.path, oldMovedDBURL.path,
                        currentValidDBURL.path, failedMovedDBURL.path])
        XCTAssertFalse(ownedAfterFailure.contains(staleArchiveDBURL.path))
        let toolIDs = try await indexDB.toolIOSessionIDs(sources: ["opencode"])
        XCTAssertFalse(toolIDs.contains(staleSession.id))
        let remainingDayCount = try await indexDB.rowCountForTesting(
            table: "session_days", source: "opencode"
        )
        let remainingRollupCount = try await indexDB.rowCountForTesting(
            table: "rollups_daily", source: "opencode"
        )
        XCTAssertEqual(remainingDayCount, 1)
        XCTAssertEqual(remainingRollupCount, 1)

        let restartedService = SearchIngestService(db: indexDB)
        _ = try await restartedService.ingest(
            source: .opencode,
            files: [],
            toolIOEnabled: false,
            identitySnapshot: .authoritativeEmpty(storagePath: liveDBURL.path),
            quietSeconds: 0,
            reingestCooldownOverride: 0
        )
        let remainingSearch = try await indexDB.rowCountForTesting(table: "session_search", source: "opencode")
        let remainingMeta = try await indexDB.rowCountForTesting(table: "session_meta", source: "opencode")
        let remainingDays = try await indexDB.rowCountForTesting(table: "session_days", source: "opencode")
        let remainingRollups = try await indexDB.rowCountForTesting(table: "rollups_daily", source: "opencode")
        let finalOwnedPaths = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(remainingSearch, 0)
        XCTAssertEqual(remainingMeta, 0)
        XCTAssertEqual(remainingDays, 0)
        XCTAssertEqual(remainingRollups, 0)
        XCTAssertEqual(finalOwnedPaths, [liveDBURL.path])
    }

    func testOpenCodeSQLiteSearchIngestRebuildPurgeInvalidatesCleanAggregate() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenCode-PurgeGeneration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("opencode.db")
        try createOpenCodeSQLiteFixture(at: dbURL)
        let session = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        let stat = try XCTUnwrap(SessionFileStat.from(dbURL))
        let fileRef = SearchIngestService.FileRef(
            path: dbURL.path, mtime: stat.mtime, size: stat.size,
            sessionID: session.id,
            contentRevision: SearchIngestService.contentRevision(for: session)
        )
        let snapshot = SearchIngestService.IdentitySnapshot(
            storagePaths: [dbURL.path], sessionIDs: [session.id]
        )

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let service = SearchIngestService(db: indexDB)
        let initial = try await service.ingest(
            source: .opencode, files: [fileRef], toolIOEnabled: false,
            identitySnapshot: snapshot, quietSeconds: 0, reingestCooldownOverride: 0
        )
        XCTAssertEqual(initial.processed, 1)

        try await indexDB.purgeSource(SessionSource.opencode.rawValue)
        let purgedSearchCount = try await indexDB.rowCountForTesting(table: "session_search", source: "opencode")
        let purgedAuthority = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(purgedSearchCount, 0)
        XCTAssertTrue(purgedAuthority.isEmpty)

        let rebuilt = try await service.ingest(
            source: .opencode, files: [fileRef], toolIOEnabled: false,
            identitySnapshot: snapshot, quietSeconds: 0, reingestCooldownOverride: 0
        )
        XCTAssertEqual(rebuilt.processed, 1,
                       "the real purge path must invalidate the in-memory clean aggregate")
        let rebuiltSearchCount = try await indexDB.rowCountForTesting(table: "session_search", source: "opencode")
        let rebuiltAuthority = try await indexDB.searchIdentityStoragePaths(source: "opencode")
        XCTAssertEqual(rebuiltSearchCount, 1)
        XCTAssertEqual(rebuiltAuthority, [dbURL.path])

        let steadyState = try await service.ingest(
            source: .opencode, files: [fileRef], toolIOEnabled: false,
            identitySnapshot: snapshot, quietSeconds: 0, reingestCooldownOverride: 0
        )
        let earlyOutCount = await service.earlyOutHitCountForTesting
        XCTAssertEqual(steadyState.processed, 0)
        XCTAssertEqual(steadyState.skipped, 1)
        XCTAssertEqual(earlyOutCount, 1,
                       "the rebuilt corpus should restore the normal unchanged-input early-out")
    }

    func testCodexDiscoveryFindsRolloutFilesInDateHierarchy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let dayDir = root
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("03", isDirectory: true)
            .appendingPathComponent("02", isDirectory: true)
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let sessionURL = dayDir.appendingPathComponent("rollout-2026-03-02T01-00-00-abc123.jsonl")
        try writeText(#"{"type":"session_meta"}"# + "\n", to: sessionURL)
        try writeText("ignore", to: dayDir.appendingPathComponent("notes.txt"))

        let discovery = CodexSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, sessionURL.lastPathComponent)
    }

    func testCodexDiscoveryUsesInjectedCodexHomeBeforeDefault() {
        let home = URL(fileURLWithPath: "/Users/codex-demo", isDirectory: true)
        let codexHome = URL(fileURLWithPath: "/Volumes/codex-data", isDirectory: true)

        let discovery = CodexSessionDiscovery(
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: home
        )

        XCTAssertEqual(
            discovery.sessionsRoot().path,
            codexHome.appendingPathComponent("sessions").path
        )
    }

    func testCodexDiscoveryCustomRootPrecedesInjectedCodexHome() {
        let customRoot = "/Volumes/custom-codex/sessions"
        let discovery = CodexSessionDiscovery(
            customRoot: customRoot,
            environment: ["CODEX_HOME": "/Volumes/codex-data"],
            homeDirectory: URL(fileURLWithPath: "/Users/codex-demo", isDirectory: true)
        )

        XCTAssertEqual(discovery.sessionsRoot().path, customRoot)
    }

    func testCodexRunwayDefaultRootUsesConfiguredOverride() {
        let suiteName = "CodexRunwayDefaultRootTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let customRoot = URL(fileURLWithPath: "/Volumes/custom-codex/sessions", isDirectory: true)
        defaults.set(customRoot.path, forKey: PreferencesKey.Paths.codexSessionsRootOverride)

        let resolved = CodexRunwayRecentSessionScanner.defaultRoot(
            defaults: defaults,
            environment: ["CODEX_HOME": "/Volumes/codex-data"],
            homeDirectory: URL(fileURLWithPath: "/Users/codex-demo", isDirectory: true)
        )

        XCTAssertEqual(resolved.path, customRoot.path)
    }

    func testCodexDiscoveryFindsSiblingArchivedSessionsForSessionsRoot() throws {
        let fm = FileManager.default
        let codexHome = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex-Archived-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: codexHome) }

        let activeDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
            .appendingPathComponent("26", isDirectory: true)
        let archivedDir = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: activeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        let activeURL = activeDir.appendingPathComponent("rollout-2026-04-26T01-00-00-active.jsonl")
        let archivedURL = archivedDir.appendingPathComponent("rollout-2026-04-25T01-00-00-archived.jsonl")
        try writeText(#"{"type":"session_meta"}"# + "\n", to: activeURL)
        try writeText(#"{"type":"session_meta"}"# + "\n", to: archivedURL)

        let found = CodexSessionDiscovery(customRoot: codexHome.appendingPathComponent("sessions").path).discoverSessionFiles()
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), Set([activeURL.lastPathComponent, archivedURL.lastPathComponent]))
    }

    func testCodexRecentDeltaFindsMovedArchivedSessionForSessionsRoot() throws {
        let fm = FileManager.default
        let codexHome = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex-ArchivedDelta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: codexHome) }

        let calendar = Calendar(identifier: .gregorian)
        let oldRolloutDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: Date()))
        let comps = calendar.dateComponents([.year, .month, .day], from: oldRolloutDate)
        let year = try XCTUnwrap(comps.year)
        let month = try XCTUnwrap(comps.month)
        let day = try XCTUnwrap(comps.day)

        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let activeDir = sessionsRoot
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        let archivedDir = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: activeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        let filename = String(format: "rollout-%04d-%02d-%02dT01-00-00-moved.jsonl", year, month, day)
        let activeURL = activeDir.appendingPathComponent(filename)
        let archivedURL = archivedDir.appendingPathComponent(filename)
        let unrelatedArchivedURL = archivedDir.appendingPathComponent(String(format: "rollout-%04d-%02d-%02dT02-00-00-unrelated.jsonl", year, month, day))
        try writeText(#"{"type":"session_meta"}"# + "\n", to: activeURL)
        try writeText(#"{"type":"session_meta"}"# + "\n", to: unrelatedArchivedURL)
        let previousStat = try XCTUnwrap(SessionFileStat.from(activeURL))
        try fm.moveItem(at: activeURL, to: archivedURL)

        let delta = CodexSessionDiscovery(customRoot: sessionsRoot.path)
            .discoverDelta(previousByPath: [activeURL.path: previousStat], scope: .recent)

        let normalizedArchivedPath = archivedURL.resolvingSymlinksInPath().path
        let normalizedActivePath = activeURL.resolvingSymlinksInPath().path
        XCTAssertEqual(delta.changedFiles.map { $0.resolvingSymlinksInPath().path }, [normalizedArchivedPath])
        XCTAssertEqual(delta.removedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [normalizedActivePath])
        XCTAssertTrue(delta.currentByPath.keys.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == normalizedArchivedPath })

        let archivedStat = try XCTUnwrap(SessionFileStat.from(archivedURL))
        try fm.removeItem(at: archivedURL)
        let deletionDelta = CodexSessionDiscovery(customRoot: sessionsRoot.path)
            .discoverDelta(previousByPath: [archivedURL.path: archivedStat], scope: .recent)
        XCTAssertEqual(deletionDelta.removedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [normalizedArchivedPath])
    }

    func testCodexRecentDeltaFindsPreviouslyKnownOldSessionChanges() throws {
        let fm = FileManager.default
        let codexHome = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex-OldChanged-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: codexHome) }

        let calendar = Calendar(identifier: .gregorian)
        let oldRolloutDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: Date()))
        let comps = calendar.dateComponents([.year, .month, .day], from: oldRolloutDate)
        let year = try XCTUnwrap(comps.year)
        let month = try XCTUnwrap(comps.month)
        let day = try XCTUnwrap(comps.day)

        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let oldDir = sessionsRoot
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)

        let filename = String(format: "rollout-%04d-%02d-%02dT01-00-00-restored.jsonl", year, month, day)
        let sessionURL = oldDir.appendingPathComponent(filename)
        try writeText(#"{"type":"session_meta","payload":{"id":"old-restored"}}"# + "\n", to: sessionURL)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10_000)], ofItemAtPath: sessionURL.path)
        let previousStat = try XCTUnwrap(SessionFileStat.from(sessionURL))

        try writeText(#"{"type":"event_msg","payload":{"message":"victoroyyb@gmail.com"}}"# + "\n", to: sessionURL)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: sessionURL.path)

        let delta = CodexSessionDiscovery(customRoot: sessionsRoot.path)
            .discoverDelta(previousByPath: [sessionURL.path: previousStat], scope: .recent)

        let normalizedPath = sessionURL.resolvingSymlinksInPath().path
        XCTAssertEqual(delta.changedFiles.map { $0.resolvingSymlinksInPath().path }, [normalizedPath])
        XCTAssertTrue(delta.removedPaths.isEmpty)
        XCTAssertTrue(delta.currentByPath.keys.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == normalizedPath })
    }

    func testCodexDiscoveryCustomNonSessionsRootDoesNotScanSiblingArchivedSessions() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Codex-Custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: parent) }

        let customRoot = parent.appendingPathComponent("custom-root", isDirectory: true)
        let archivedDir = parent.appendingPathComponent("archived_sessions", isDirectory: true)
        try fm.createDirectory(at: customRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: archivedDir, withIntermediateDirectories: true)

        let activeURL = customRoot.appendingPathComponent("rollout-2026-04-26T01-00-00-active.jsonl")
        let archivedURL = archivedDir.appendingPathComponent("rollout-2026-04-25T01-00-00-archived.jsonl")
        try writeText(#"{"type":"session_meta"}"# + "\n", to: activeURL)
        try writeText(#"{"type":"session_meta"}"# + "\n", to: archivedURL)

        let found = CodexSessionDiscovery(customRoot: customRoot.path).discoverSessionFiles()
        XCTAssertEqual(found.map(\.lastPathComponent), [activeURL.lastPathComponent])
    }

    func testCodexAdditionalChangedFilesIncludesMissingHydratedRecentFile() {
        let pathA = "/tmp/codex-a.jsonl"
        let pathB = "/tmp/codex-b.jsonl"

        let currentByPath: [String: SessionFileStat] = [
            pathA: SessionFileStat(mtime: 100, size: 10),
            pathB: SessionFileStat(mtime: 100, size: 10)
        ]
        let existing = Set([pathA])

        let missing = SessionIndexer.additionalChangedFilesForMissingHydratedSessions(
            currentByPath: currentByPath,
            existingSessionPaths: existing,
            changedFiles: []
        )

        XCTAssertEqual(Set(missing.map(\.path)), Set([pathB]))
    }

    func testCodexAdditionalChangedFilesSkipsHydratedAndAlreadyChangedPaths() {
        let pathA = "/tmp/codex-a.jsonl"
        let pathB = "/tmp/codex-b.jsonl"
        let pathC = "/tmp/codex-c.jsonl"

        let currentByPath: [String: SessionFileStat] = [
            pathA: SessionFileStat(mtime: 100, size: 10),
            pathB: SessionFileStat(mtime: 100, size: 10),
            pathC: SessionFileStat(mtime: 100, size: 10)
        ]
        let existing = Set([pathA])
        let changed = [URL(fileURLWithPath: pathB)]

        let missing = SessionIndexer.additionalChangedFilesForMissingHydratedSessions(
            currentByPath: currentByPath,
            existingSessionPaths: existing,
            changedFiles: changed
        )

        XCTAssertEqual(Set(missing.map(\.path)), Set([pathC]))
    }

    // MARK: - DirectorySignatureSnapshot

    func testDirectorySignatureSnapshot_emptyInputProducesEmpty() {
        let snapshot = DirectorySignatureSnapshot.from([])
        XCTAssertEqual(snapshot, DirectorySignatureSnapshot.empty)
        XCTAssertEqual(snapshot.fileCount, 0)
        XCTAssertNil(snapshot.newestModifiedAt)
    }

    func testDirectorySignatureSnapshot_identicalInputsProduceEqualSnapshots() {
        let date = Date(timeIntervalSince1970: 1000)
        let input: [(path: String, modifiedAt: Date)] = [
            (path: "/a.jsonl", modifiedAt: date),
            (path: "/b.jsonl", modifiedAt: date)
        ]
        let a = DirectorySignatureSnapshot.from(input)
        let b = DirectorySignatureSnapshot.from(input)
        XCTAssertEqual(a, b)
    }

    func testDirectorySignatureSnapshot_changedMtimeProducesDifferentSnapshot() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let original: [(path: String, modifiedAt: Date)] = [
            (path: "/a.jsonl", modifiedAt: date1),
            (path: "/b.jsonl", modifiedAt: date1)
        ]
        let modified: [(path: String, modifiedAt: Date)] = [
            (path: "/a.jsonl", modifiedAt: date1),
            (path: "/b.jsonl", modifiedAt: date2)
        ]
        XCTAssertNotEqual(DirectorySignatureSnapshot.from(original),
                          DirectorySignatureSnapshot.from(modified))
    }

    func testDirectorySignatureSnapshot_orderDoesNotMatter() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)
        let forward: [(path: String, modifiedAt: Date)] = [
            (path: "/a.jsonl", modifiedAt: date1),
            (path: "/b.jsonl", modifiedAt: date2)
        ]
        let reversed: [(path: String, modifiedAt: Date)] = [
            (path: "/b.jsonl", modifiedAt: date2),
            (path: "/a.jsonl", modifiedAt: date1)
        ]
        XCTAssertEqual(DirectorySignatureSnapshot.from(forward),
                       DirectorySignatureSnapshot.from(reversed))
    }

    func testDirectorySignatureSnapshot_newestModifiedAtIsCorrect() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let snapshot = DirectorySignatureSnapshot.from([
            (path: "/a.jsonl", modifiedAt: older),
            (path: "/b.jsonl", modifiedAt: newer)
        ])
        XCTAssertEqual(snapshot.newestModifiedAt, newer)
        XCTAssertEqual(snapshot.fileCount, 2)
    }

    // MARK: - CoreIndexingProgress aggregation

    func testAggregateProgress_idleSourcesDoNotInflateTotals() {
        let snapshots: [UnifiedSessionIndexer.CoreProviderSnapshot] = [
            .init(source: .codex, enabled: true, indexing: false, processed: 100, total: 100),
            .init(source: .claude, enabled: true, indexing: true, processed: 10, total: 50)
        ]
        let progress = UnifiedSessionIndexer.aggregateProgress(from: snapshots)
        XCTAssertEqual(progress.processed, 10)
        XCTAssertEqual(progress.total, 50)
        XCTAssertEqual(progress.activeSources, 1)
        XCTAssertEqual(progress.totalSources, 2)
    }

    func testAggregateProgress_allIdleReturnsEmpty() {
        let snapshots: [UnifiedSessionIndexer.CoreProviderSnapshot] = [
            .init(source: .codex, enabled: true, indexing: false, processed: 100, total: 100),
            .init(source: .claude, enabled: true, indexing: false, processed: 50, total: 50)
        ]
        let progress = UnifiedSessionIndexer.aggregateProgress(from: snapshots)
        XCTAssertEqual(progress, UnifiedSessionIndexer.CoreIndexingProgress.empty)
    }

    func testAggregateProgress_multipleActiveSourcesCombine() {
        let snapshots: [UnifiedSessionIndexer.CoreProviderSnapshot] = [
            .init(source: .codex, enabled: true, indexing: true, processed: 20, total: 40),
            .init(source: .claude, enabled: true, indexing: true, processed: 30, total: 60)
        ]
        let progress = UnifiedSessionIndexer.aggregateProgress(from: snapshots)
        XCTAssertEqual(progress.processed, 50)
        XCTAssertEqual(progress.total, 100)
        XCTAssertEqual(progress.activeSources, 2)
    }

    func testClaudeDiscoveryUsesProjectsSubtreeWhenPresent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let projectsDir = root.appendingPathComponent("projects/demo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let sessionURL = projectsDir.appendingPathComponent("session.jsonl")
        try writeText(#"{"type":"user","message":{"content":"hi"}}"# + "\n", to: sessionURL)

        let rootJSONL = root.appendingPathComponent("history.jsonl")
        try writeText(#"{"type":"meta"}"# + "\n", to: rootJSONL)

        let discovery = ClaudeSessionDiscovery(customRoot: root.path, includeDesktopRoots: false)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map(canonicalPath), canonicalPath(sessionURL))
    }

    func testClaudeDiscoveryIncludesDesktopRootsWithCustomRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-CustomDesktop-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let customProjectsDir = root.appendingPathComponent("custom/.claude/projects/custom", isDirectory: true)
        try fm.createDirectory(at: customProjectsDir, withIntermediateDirectories: true)
        let customSessionURL = customProjectsDir.appendingPathComponent("custom.jsonl")
        try writeText(#"{"type":"user","message":{"content":"custom"}}"# + "\n", to: customSessionURL)

        let desktopRoot = root.appendingPathComponent("Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
        let desktopProjectsDir = desktopRoot
            .appendingPathComponent("account/workspace/local_abc/.claude/projects/-desktop", isDirectory: true)
        try fm.createDirectory(at: desktopProjectsDir, withIntermediateDirectories: true)
        let desktopSessionURL = desktopProjectsDir.appendingPathComponent("desktop.jsonl")
        try writeText(#"{"type":"user","message":{"content":"desktop"}}"# + "\n", to: desktopSessionURL)

        let discovery = ClaudeSessionDiscovery(
            customRoot: root.appendingPathComponent("custom/.claude", isDirectory: true).path,
            desktopLocalAgentRoot: desktopRoot
        )
        let found = Set(discovery.discoverSessionFiles().map(canonicalPath))
        XCTAssertEqual(found, [canonicalPath(customSessionURL), canonicalPath(desktopSessionURL)])

        let desktopOnly = ClaudeSessionDiscovery(
            customRoot: root.appendingPathComponent("missing/.claude", isDirectory: true).path,
            desktopLocalAgentRoot: desktopRoot
        )
        XCTAssertTrue(desktopOnly.hasDiscoverableSessionsRoot())
    }

    func testClaudeSessionScanRootsIncludeDesktopLocalAgentProjects() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeScanRoots-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let customConfigRoot = root.appendingPathComponent("custom/.claude", isDirectory: true)
        let customProjectsRoot = customConfigRoot.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: customProjectsRoot, withIntermediateDirectories: true)

        let desktopRoot = root.appendingPathComponent("Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
        let desktopProjectsRoot = desktopRoot
            .appendingPathComponent("account/workspace/local_abc/.claude/projects", isDirectory: true)
        try fm.createDirectory(at: desktopProjectsRoot, withIntermediateDirectories: true)

        let discovery = ClaudeSessionDiscovery(
            customRoot: customConfigRoot.path,
            desktopLocalAgentRoot: desktopRoot
        )
        let roots = Set(discovery.sessionScanRoots().map(canonicalPath))

        XCTAssertEqual(roots, [canonicalPath(customProjectsRoot), canonicalPath(desktopProjectsRoot)])
    }

    func testClaudeParserEnrichesDesktopLocalAgentTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktop-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let localDir = root
            .appendingPathComponent("local-agent-mode-sessions/account/workspace/local_abc", isDirectory: true)
        let projectsDir = localDir
            .appendingPathComponent(".claude/projects/-sessions-demo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let metadataURL = localDir.deletingPathExtension().appendingPathExtension("json")
        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"11111111-1111-4111-8111-111111111111","cwd":"/sessions/demo","originCwd":"/Users/test/Repo","createdAt":1770000000000,"lastActivityAt":1770000100000,"model":"claude-sonnet-test","title":"Desktop metadata title","isArchived":false}"#,
            to: metadataURL
        )

        let transcriptURL = projectsDir.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try writeText(
            #"{"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/sessions/demo","version":"2.1.126","message":{"role":"user","content":"hi"}}"# + "\n",
            to: transcriptURL
        )

        let session = try XCTUnwrap(ClaudeSessionParser.parseFile(at: transcriptURL))
        XCTAssertEqual(session.source, .claude)
        XCTAssertEqual(session.surface, .desktop)
        XCTAssertEqual(session.originator, "Claude Desktop")
        XCTAssertEqual(session.originSource, "local-agent-mode")
        XCTAssertEqual(session.codexInternalSessionIDHint, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(session.lightweightCwd, "/Users/test/Repo")
        XCTAssertEqual(session.model, "claude-sonnet-test")
        XCTAssertEqual(session.lightweightTitle, "hi")
        XCTAssertEqual(session.startTime?.timeIntervalSince1970, 1770000000)
        XCTAssertEqual(session.endTime?.timeIntervalSince1970, 1770000100)
    }

    func testClaudeParserMarksDesktopEntrypointTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktopEntrypoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let projectsDir = root.appendingPathComponent(".claude/projects/-Users-test-Repo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let transcriptURL = projectsDir.appendingPathComponent("5d607a99-541f-4a7a-a4bb-c9fe5e763e4e.jsonl")
        try writeText(
            #"{"type":"user","sessionId":"5d607a99-541f-4a7a-a4bb-c9fe5e763e4e","entrypoint":"claude-desktop","cwd":"/Users/test/Repo","version":"2.1.119","message":{"role":"user","content":"create TEST 2 session"}}"# + "\n",
            to: transcriptURL
        )

        let session = try XCTUnwrap(ClaudeSessionParser.parseFile(at: transcriptURL))
        XCTAssertEqual(session.source, .claude)
        XCTAssertEqual(session.surface, .desktop)
        XCTAssertEqual(session.originator, "Claude Desktop")
        XCTAssertEqual(session.originSource, "claude-desktop")
        XCTAssertEqual(session.codexInternalSessionIDHint, "5d607a99-541f-4a7a-a4bb-c9fe5e763e4e")
    }

    func testClaudeParserUsesDesktopMetadataTitleWhenTranscriptTitleIsFallback() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktopTitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let localDir = root
            .appendingPathComponent("local-agent-mode-sessions/account/workspace/local_abc", isDirectory: true)
        let projectsDir = localDir
            .appendingPathComponent(".claude/projects/-sessions-demo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let metadataURL = localDir.deletingPathExtension().appendingPathExtension("json")
        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"11111111-1111-4111-8111-111111111111","title":"Desktop metadata title"}"#,
            to: metadataURL
        )

        let transcriptURL = projectsDir.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try writeText(
            #"{"type":"system","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/sessions/demo"}"# + "\n",
            to: transcriptURL
        )

        let session = try XCTUnwrap(ClaudeSessionParser.parseFile(at: transcriptURL))
        XCTAssertEqual(session.surface, .desktop)
        XCTAssertEqual(session.lightweightTitle, "Desktop metadata title")
    }

    func testClaudeParserIgnoresDesktopMetadataForDifferentTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktopMismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let localDir = root
            .appendingPathComponent("local-agent-mode-sessions/account/workspace/local_abc", isDirectory: true)
        let projectsDir = localDir
            .appendingPathComponent(".claude/projects/-sessions-demo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let metadataURL = localDir.deletingPathExtension().appendingPathExtension("json")
        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","cwd":"/sessions/demo","originCwd":"/Users/test/Repo","createdAt":1770000000000,"lastActivityAt":1770000100000,"model":"claude-sonnet-test","title":"Wrong metadata","isArchived":false}"#,
            to: metadataURL
        )

        let transcriptURL = projectsDir.appendingPathComponent("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jsonl")
        try writeText(
            #"{"type":"user","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","cwd":"/sessions/demo","message":{"role":"user","content":"hi"}}"# + "\n",
            to: transcriptURL
        )

        let session = try XCTUnwrap(ClaudeSessionParser.parseFile(at: transcriptURL))
        XCTAssertNil(session.surface)
        XCTAssertNil(session.originator)
        XCTAssertNil(session.originSource)
        XCTAssertEqual(session.lightweightCwd, "/sessions/demo")
        XCTAssertNil(session.model)
    }

    func testClaudeDiscoveryDeltaTracksDesktopMetadataChanges() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktopDelta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let desktopRoot = root.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let localDir = desktopRoot.appendingPathComponent("account/workspace/local_abc", isDirectory: true)
        let projectsDir = localDir.appendingPathComponent(".claude/projects/-sessions-demo", isDirectory: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let metadataURL = localDir.deletingPathExtension().appendingPathExtension("json")
        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"11111111-1111-4111-8111-111111111111","title":"Before"}"#,
            to: metadataURL
        )
        let transcriptURL = projectsDir.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try writeText(
            #"{"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","message":{"role":"user","content":"hi"}}"# + "\n",
            to: transcriptURL
        )

        let discovery = ClaudeSessionDiscovery(
            customRoot: root.appendingPathComponent("missing/.claude", isDirectory: true).path,
            desktopLocalAgentRoot: desktopRoot
        )
        let initial = discovery.discoverDelta(previousByPath: [:], scope: .full)
        XCTAssertEqual(initial.changedFiles.map(canonicalPath), [canonicalPath(transcriptURL)])

        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"11111111-1111-4111-8111-111111111111","title":"After metadata edit with more bytes"}"#,
            to: metadataURL
        )

        let delta = discovery.discoverDelta(previousByPath: initial.currentByPath, scope: .full)
        XCTAssertEqual(delta.changedFiles.map(canonicalPath), [canonicalPath(transcriptURL)])
    }

    func testCopilotDiscoveryAcceptsConfigRootOverride() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionStateDir = root.appendingPathComponent("session-state", isDirectory: true)
        try fm.createDirectory(at: sessionStateDir, withIntermediateDirectories: true)
        let sessionURL = sessionStateDir.appendingPathComponent("abc123.jsonl")
        try writeText(#"{"type":"session"}"# + "\n", to: sessionURL)

        let discovery = CopilotSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map(canonicalPath), canonicalPath(sessionURL))
    }

    func testCopilotDiscoveryFindsSubdirectoryEventsLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionStateDir = root.appendingPathComponent("session-state", isDirectory: true)
        let uuidDir = sessionStateDir.appendingPathComponent("aaaabbbb-1111-2222-3333-ccccddddeeee", isDirectory: true)
        try fm.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let eventsURL = uuidDir.appendingPathComponent("events.jsonl")
        try writeText(#"{"type":"session.start","data":{"sessionId":"aaaabbbb-1111-2222-3333-ccccddddeeee"}}"# + "\n", to: eventsURL)

        let discovery = CopilotSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map(canonicalPath), canonicalPath(eventsURL))
    }

    func testCopilotDiscoveryFindsBothFlatAndSubdirectoryLayouts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionStateDir = root.appendingPathComponent("session-state", isDirectory: true)
        try fm.createDirectory(at: sessionStateDir, withIntermediateDirectories: true)

        // Legacy flat file
        let flatURL = sessionStateDir.appendingPathComponent("legacy-session.jsonl")
        try writeText(#"{"type":"session"}"# + "\n", to: flatURL)

        // Current subdirectory layout
        let uuidDir = sessionStateDir.appendingPathComponent("aaaabbbb-1111-2222-3333-ccccddddeeee", isDirectory: true)
        try fm.createDirectory(at: uuidDir, withIntermediateDirectories: true)
        let eventsURL = uuidDir.appendingPathComponent("events.jsonl")
        try writeText(#"{"type":"session.start","data":{"sessionId":"aaaabbbb-1111-2222-3333-ccccddddeeee"}}"# + "\n", to: eventsURL)

        let discovery = CopilotSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        let paths = Set(found.map(canonicalPath))
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(paths.contains(canonicalPath(flatURL)))
        XCTAssertTrue(paths.contains(canonicalPath(eventsURL)))
    }

    func testCopilotFallbackIDUsesParentDirForEventsFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-FallbackID-\(UUID().uuidString)", isDirectory: true)
        let uuidDir = root.appendingPathComponent("aaaabbbb-1111-2222-3333-ccccddddeeee", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: uuidDir, withIntermediateDirectories: true)

        // Write a session without sessionId in session.start so fallbackID is used
        let eventsURL = uuidDir.appendingPathComponent("events.jsonl")
        try writeText(#"{"type":"user.message","data":{"content":"hello"},"timestamp":"2025-01-01T00:00:00Z"}"# + "\n", to: eventsURL)

        let session = CopilotSessionParser.parseFile(at: eventsURL)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "aaaabbbb-1111-2222-3333-ccccddddeeee")
    }

    /// Builds a directory-layout Copilot session with the given `workspace.yaml`
    /// and returns the `customTitle` the parser derives from it.
    private func copilotCustomTitle(workspaceYAML: String) throws -> String? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-WorkspaceName-\(UUID().uuidString)", isDirectory: true)
        let uuidDir = root.appendingPathComponent("aaaabbbb-1111-2222-3333-ccccddddeeee", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: uuidDir, withIntermediateDirectories: true)

        let eventsURL = uuidDir.appendingPathComponent("events.jsonl")
        try writeText(#"{"type":"user.message","data":{"content":"hello"},"timestamp":"2025-01-01T00:00:00Z"}"# + "\n", to: eventsURL)
        try writeText(workspaceYAML, to: uuidDir.appendingPathComponent("workspace.yaml"))

        return CopilotSessionParser.parseFile(at: eventsURL)?.customTitle
    }

    func testCopilotWorkspaceNameReadsBlockScalarTitle() throws {
        // Shape Copilot actually writes for a multi-line title: the `name:` line carries
        // only the block indicator, and the title starts on the next indented line.
        let yaml = """
        id: aaaabbbb-1111-2222-3333-ccccddddeeee
        cwd: /tmp/repo
        client_name: github/cli
        name: |-
          List the files in the current directory, then say hello in one sentence.

          Include this exact marker in your final answer: AGENT_WATCH_PREBUMP_ffd32f46
        user_named: false
        summary_count: 0
        """

        let title = try copilotCustomTitle(workspaceYAML: yaml)
        XCTAssertEqual(title, "List the files in the current directory, then say hello in one sentence.")
        XCTAssertNotEqual(title, "|-", "Block indicator must never leak through as the title")
    }

    func testCopilotWorkspaceNameReadsAllBlockScalarHeaderForms() throws {
        for header in ["|", "|-", "|+", ">", ">-", ">+", "|2", "|2-", "|-2"] {
            let yaml = """
            name: \(header)
              Block title
            user_named: false
            """
            XCTAssertEqual(try copilotCustomTitle(workspaceYAML: yaml), "Block title",
                           "Failed for block scalar header `\(header)`")
        }
    }

    func testCopilotWorkspaceNameKeepsPlainScalarTitles() throws {
        XCTAssertEqual(try copilotCustomTitle(workspaceYAML: "name: Run ls.\nuser_named: false\n"), "Run ls.")
        XCTAssertEqual(try copilotCustomTitle(workspaceYAML: "name: \"Quoted title\"\n"), "Quoted title")
        XCTAssertEqual(try copilotCustomTitle(workspaceYAML: "name: 'Quoted title'\n"), "Quoted title")
        // `client_name` must not be mistaken for the top-level `name` key.
        XCTAssertNil(try copilotCustomTitle(workspaceYAML: "client_name: github/cli\nuser_named: false\n"))
        XCTAssertNil(try copilotCustomTitle(workspaceYAML: "id: abc\ncwd: /tmp/repo\n"))
    }

    func testCopilotWorkspaceNameTreatsEmptyBlockScalarAsNoTitle() throws {
        // Block indicator with no indented content: the next top-level key ends the block.
        XCTAssertNil(try copilotCustomTitle(workspaceYAML: "name: |-\nuser_named: false\n"))
        // Block indicator at end of file.
        XCTAssertNil(try copilotCustomTitle(workspaceYAML: "id: abc\nname: |-\n"))
    }

    func testCopilotWorkspaceNameIgnoredForLegacyFlatLayout() throws {
        let fm = FileManager.default
        let sessionStateDir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Copilot-FlatWorkspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: sessionStateDir) }
        try fm.createDirectory(at: sessionStateDir, withIntermediateDirectories: true)

        // A shared workspace.yaml beside legacy flat files must not title every session.
        try writeText("name: |-\n  Shared workspace title\n", to: sessionStateDir.appendingPathComponent("workspace.yaml"))
        let flatURL = sessionStateDir.appendingPathComponent("legacy-session.jsonl")
        try writeText(#"{"type":"user.message","data":{"content":"hello"},"timestamp":"2025-01-01T00:00:00Z"}"# + "\n", to: flatURL)

        XCTAssertNil(CopilotSessionParser.parseFile(at: flatURL)?.customTitle)
    }

    func testDroidDiscoveryIncludesSessionStoreAndStreamJSON() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Droid-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let sessionStoreDir = sessionsRoot.appendingPathComponent("projA", isDirectory: true)
        let streamDir = projectsRoot.appendingPathComponent("projA", isDirectory: true)
        try fm.createDirectory(at: sessionStoreDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: streamDir, withIntermediateDirectories: true)

        let storeURL = sessionStoreDir.appendingPathComponent("store.jsonl")
        try writeText(#"{"type":"session_start","session_id":"s1"}"# + "\n", to: storeURL)

        let streamURL = streamDir.appendingPathComponent("stream.jsonl")
        try writeText(
            """
            {"type":"system","session_id":"s_stream","message":"ok"}
            {"type":"message","session_id":"s_stream","role":"user","text":"hello"}
            {"type":"completion","session_id":"s_stream","finalText":"done"}
            """,
            to: streamURL
        )

        let noiseURL = streamDir.appendingPathComponent("noise.jsonl")
        try writeText(#"{"type":"random"}"# + "\n", to: noiseURL)

        let discovery = DroidSessionDiscovery(customSessionsRoot: sessionsRoot.path, customProjectsRoot: projectsRoot.path)
        let found = Set(discovery.discoverSessionFiles().map(canonicalPath))
        XCTAssertTrue(found.contains(canonicalPath(storeURL)))
        XCTAssertTrue(found.contains(canonicalPath(streamURL)))
        XCTAssertFalse(found.contains(canonicalPath(noiseURL)))
    }

    func testAntigravityDiscoveryFindsBrainArtifactsOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Antigravity-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let conversation = root.appendingPathComponent("conv-123", isDirectory: true)
        let oldAntigravityProject = root.appendingPathComponent("radio4j/chats", isDirectory: true)
        try fm.createDirectory(at: conversation, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldAntigravityProject, withIntermediateDirectories: true)

        let task = conversation.appendingPathComponent("task.md")
        let walkthrough = conversation.appendingPathComponent("walkthrough.md")
        let oldAntigravitySession = oldAntigravityProject.appendingPathComponent("session-1.json")
        let unrelatedMarkdown = conversation.appendingPathComponent("notes.md")

        try writeText("# Build plan\n", to: task)
        try writeText("# Walkthrough\n", to: walkthrough)
        try writeText("{}", to: oldAntigravitySession)
        try writeText("# Notes\n", to: unrelatedMarkdown)

        let discovery = AntigravitySessionDiscovery(customRoot: root.path)
        let found = Set(discovery.discoverSessionFiles().map(canonicalPath))

        XCTAssertTrue(found.contains(canonicalPath(task)))
        XCTAssertTrue(found.contains(canonicalPath(walkthrough)))
        XCTAssertTrue(found.contains(canonicalPath(unrelatedMarkdown)))
        XCTAssertFalse(found.contains(canonicalPath(oldAntigravitySession)))
    }

    func testAntigravityMarkdownArtifactParsesConversationIDAndTitle() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Antigravity-Parser-\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conv-abc", isDirectory: true)
        try fm.createDirectory(at: conversation, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let url = conversation.appendingPathComponent("task.md")
        try writeText("""
        # Replace unsupported provider

        Use agy for this conversation.
        """, to: url)

        guard let preview = AntigravitySessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .antigravity)
        XCTAssertEqual(preview.id, "conv-abc#task")
        XCTAssertEqual(AntigravitySessionIDHelper.deriveSessionID(from: preview), "conv-abc")
        XCTAssertEqual(preview.title, "Replace unsupported provider")
        XCTAssertEqual(preview.eventCount, 1)
        XCTAssertTrue(preview.events.isEmpty)

        guard let full = AntigravitySessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .antigravity)
        XCTAssertEqual(full.id, "conv-abc#task")
        XCTAssertEqual(AntigravitySessionIDHelper.deriveSessionID(from: full), "conv-abc")
        XCTAssertEqual(full.events.count, 1)
        XCTAssertEqual(full.events.first?.kind, .assistant)
        XCTAssertTrue(full.events.first?.text?.contains("Use agy") == true)
    }

    func testAntigravityMarkdownArtifactInfersProjectFromLocalFileLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Antigravity-Project-\(UUID().uuidString)", isDirectory: true)
        let brain = root.appendingPathComponent("brain/conv-project", isDirectory: true)
        let repo = root.appendingPathComponent("ExampleProject", isDirectory: true)
        let sourceDir = repo.appendingPathComponent("Sources", isDirectory: true)
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sourceFile = sourceDir.appendingPathComponent("Feature.swift")
        try writeText("struct Feature {}\n", to: sourceFile)

        let task = brain.appendingPathComponent("task.md")
        try writeText("""
        # Update feature

        See [Feature.swift](file://\(sourceFile.path)).
        """, to: task)

        guard let session = AntigravitySessionParser.parseFile(at: task) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.cwd, repo.path)
        XCTAssertEqual(session.rowRepoName, "ExampleProject")
    }

    func testAntigravityMarkdownArtifactInfersProjectFromSiblingLocalFileLink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Antigravity-SiblingProject-\(UUID().uuidString)", isDirectory: true)
        let brain = root.appendingPathComponent("brain/conv-project", isDirectory: true)
        let repo = root.appendingPathComponent("SiblingProject", isDirectory: true)
        let docsDir = repo.appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let doc = docsDir.appendingPathComponent("index.html")
        try writeText("<h1>Docs</h1>\n", to: doc)

        let task = brain.appendingPathComponent("task.md")
        let walkthrough = brain.appendingPathComponent("walkthrough.md")
        try writeText("# Task without links\n", to: task)
        try writeText("""
        # Walkthrough

        Open `file://\(doc.path)` in the browser.
        """, to: walkthrough)

        guard let session = AntigravitySessionParser.parseFile(at: task) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.cwd, repo.path)
        XCTAssertEqual(session.rowRepoName, "SiblingProject")
    }

    func testAntigravityArtifactsInSameConversationHaveUniqueSessionIDs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Antigravity-IDs-\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conv-shared", isDirectory: true)
        try fm.createDirectory(at: conversation, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let task = conversation.appendingPathComponent("task.md")
        let walkthrough = conversation.appendingPathComponent("walkthrough.md")
        try writeText("# Task\n", to: task)
        try writeText("# Walkthrough\n", to: walkthrough)

        let sessions = [task, walkthrough].compactMap { AntigravitySessionParser.parseFile(at: $0) }
        XCTAssertEqual(Set(sessions.map(\.id)), ["conv-shared#task", "conv-shared#walkthrough"])
        XCTAssertEqual(Set(sessions.compactMap { AntigravitySessionIDHelper.deriveSessionID(from: $0) }), ["conv-shared"])
    }

    func testOpenClawDiscoveryFindsAgentSessionFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionsDir = root.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let live = sessionsDir.appendingPathComponent("live.jsonl")
        let trajectory = sessionsDir.appendingPathComponent("live.trajectory.jsonl")
        let lock = sessionsDir.appendingPathComponent("live.jsonl.lock")
        let deleted = sessionsDir.appendingPathComponent("live.jsonl.deleted.1")
        try writeText(#"{"type":"session"}"# + "\n", to: live)
        try writeText(#"{"type":"trajectory"}"# + "\n", to: trajectory)
        try writeText("", to: lock)
        try writeText("", to: deleted)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path, includeDeleted: false)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map(canonicalPath), canonicalPath(live))
    }

    func testOpenClawDiscoveryIncludesDeletedByDefault() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DefaultDeleted-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionsDir = root.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let active = sessionsDir.appendingPathComponent("active.jsonl")
        let deleted = sessionsDir.appendingPathComponent("old.jsonl.deleted.1704067200")
        try writeText("", to: active)
        try writeText("", to: deleted)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 2, "Default discovery should include both active and deleted sessions")
    }

    func testOpenClawDiscoveryFindsAgentDatabases() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DBDiscovery-(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let mainDB = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        let otherDB = root.appendingPathComponent("agents/other/agent/openclaw-agent.sqlite")
        let ignored = root.appendingPathComponent("agents/main/sessions/openclaw-agent.sqlite")
        try fm.createDirectory(at: mainDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: otherDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: ignored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeText("", to: mainDB)
        try writeText("", to: otherDB)
        try writeText("", to: ignored)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath),
                       [canonicalPath(mainDB), canonicalPath(otherDB)])
    }

    func testOpenClawDiscoveryFindsConfiguredExternalAgentDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-ExternalDB-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let externalAgentDir = root.appendingPathComponent("custom/worker-state", isDirectory: true)
        let database = externalAgentDir.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalAgentDir, withIntermediateDirectories: true)
        try writeText("", to: database)

        let discovery = OpenClawSessionDiscovery(
            customRoot: root.path,
            configuredAgentDirectories: [
                .init(agentID: "worker", path: externalAgentDir.path)
            ])
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: database), "worker")
    }

    func testOpenClawDiscoveryResolvesJSON5IncludesForExternalAgentDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-JSON5Config-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let externalAgentDir = root.appendingPathComponent("configured-agent", isDirectory: true)
        let database = externalAgentDir.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalAgentDir, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try writeText("""
        {
          // Valid OpenClaw JSON5 syntax.
          agents: {
            entries: {
              local: { agentDir: '\(externalAgentDir.path)', },
            },
          },
        }
        """, to: root.appendingPathComponent("included.json5"))
        try writeText("""
        {
          $include: './included.json5',
          agents: {
            entries: {},
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: database), "local")
    }

    func testOpenClawDiscoveryFailsClosedWhenIncludedSymlinkRetargetsDuringValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-IncludeSymlinkTOCTOU-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("first-agent", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second-agent", isDirectory: true)
        try fm.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(
            at: firstDirectory.appendingPathComponent("openclaw-agent.sqlite"))
        try createOpenClawSQLiteFixture(
            at: secondDirectory.appendingPathComponent("openclaw-agent.sqlite"))

        let firstInclude = root.appendingPathComponent("included-first.json5")
        let secondInclude = root.appendingPathComponent("included-second.json5")
        let lexicalInclude = root.appendingPathComponent("included.json5")
        try writeText("""
        { agents: { entries: { first: { agentDir: '\(firstDirectory.path)' } } } }
        """, to: firstInclude)
        try writeText("""
        { agents: { entries: { second: { agentDir: '\(secondDirectory.path)' } } } }
        """, to: secondInclude)
        try fm.createSymbolicLink(at: lexicalInclude, withDestinationURL: firstInclude)
        try writeText("{ $include: './included.json5' }", to: root.appendingPathComponent("openclaw.json"))

        let validator = root.appendingPathComponent("validator.sh")
        try writeText("""
        #!/bin/sh
        root=$(dirname "$OPENCLAW_CONFIG_PATH")
        ln -sf "$root/included-second.json5" "$root/included.json5"
        printf '%s\\n' '{"valid":true}'
        """, to: validator)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validator.path)

        let defaults = UserDefaults.standard
        let overrideKey = PreferencesKey.Paths.openClawBinaryOverride
        let previousOverride = defaults.string(forKey: overrideKey)
        defaults.set(validator.path, forKey: overrideKey)
        defer {
            if let previousOverride {
                defaults.set(previousOverride, forKey: overrideKey)
            } else {
                defaults.removeObject(forKey: overrideKey)
            }
        }

        try withProcessEnvironment(["OPENCLAW_CONFIG_PATH": nil]) {
            let result = OpenClawSessionDiscovery(customRoot: root.path)
                .discoverSessionDatabaseResult()
            XCTAssertTrue(result.databases.isEmpty)
            XCTAssertFalse(result.isAuthoritative,
                           "validation must not bless a different include target")
        }
    }

    func testOpenClawDiscoveryFiltersBlockedWorkspaceDotEnvKeysBeforeValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-WorkspaceDotEnv-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let agentDirectory = state.appendingPathComponent("worker", isDirectory: true)
        try fm.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(
            at: agentDirectory.appendingPathComponent("openclaw-agent.sqlite"))

        let allowedVariable = "AGENT_SESSIONS_WORKSPACE_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        try writeText("""
        OPENAI_API_KEY=blocked-secret
        CODEX_API_KEY=blocked-codex-secret
        ANTHROPIC_ADMIN_API_KEY=blocked-admin-secret
        PLUGIN_CREDENTIALS=blocked-plugin-secret
        PROJECT_API_BASE_URL=blocked-route
        NODE_OPTIONS=--require /tmp/workspace-payload.cjs
        NODE_PATH=/tmp/workspace-node-modules
        NODE_EXTRA_CA_CERTS=/tmp/workspace-ca.pem
        ACME_AUTH=blocked-plugin-auth
        BASH_ENV=/tmp/workspace-shell
        OPENSSL_CONF=/tmp/workspace-openssl.cnf
        NPM_CONFIG_REGISTRY=https://workspace.example.invalid
        DYLD_INSERT_LIBRARIES=/tmp/workspace-injected.dylib
        \(allowedVariable)=\(agentDirectory.path)
        """, to: workspace.appendingPathComponent(".env"))
        try writeText("""
        {
          agents: {
            entries: {
              worker: { agentDir: '${\(allowedVariable)}' },
            },
          },
        }
        """, to: state.appendingPathComponent("openclaw.json"))

        let validator = root.appendingPathComponent("validator.sh")
        try writeText("""
        #!/bin/sh
        if [ -n "$OPENAI_API_KEY" ] || [ -n "$CODEX_API_KEY" ] || \
           [ -n "$ANTHROPIC_ADMIN_API_KEY" ] || [ -n "$PLUGIN_CREDENTIALS" ] || \
           [ -n "$PROJECT_API_BASE_URL" ] || [ -n "$NODE_OPTIONS" ] || \
           [ -n "$NODE_PATH" ] || [ -n "$NODE_EXTRA_CA_CERTS" ] || \
           [ -n "$ACME_AUTH" ] || \
           [ -n "$BASH_ENV" ] || [ -n "$OPENSSL_CONF" ] || \
           [ -n "$NPM_CONFIG_REGISTRY" ] || \
           [ -n "$DYLD_INSERT_LIBRARIES" ]; then
            printf '%s\\n' '{"valid":false}'
            exit 1
        fi
        printf '%s\\n' '{"valid":true}'
        """, to: validator)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validator.path)

        let defaults = UserDefaults.standard
        let overrideKey = PreferencesKey.Paths.openClawBinaryOverride
        let previousOverride = defaults.string(forKey: overrideKey)
        defaults.set(validator.path, forKey: overrideKey)
        let previousDirectory = fm.currentDirectoryPath
        XCTAssertTrue(fm.changeCurrentDirectoryPath(workspace.path))
        defer {
            _ = fm.changeCurrentDirectoryPath(previousDirectory)
            if let previousOverride {
                defaults.set(previousOverride, forKey: overrideKey)
            } else {
                defaults.removeObject(forKey: overrideKey)
            }
        }

        try withProcessEnvironment([
            "OPENCLAW_CONFIG_PATH": nil,
            "OPENAI_API_KEY": nil,
            "CODEX_API_KEY": nil,
            "ANTHROPIC_ADMIN_API_KEY": nil,
            "PLUGIN_CREDENTIALS": nil,
            "PROJECT_API_BASE_URL": nil,
            "NODE_OPTIONS": nil,
            "NODE_PATH": nil,
            "NODE_EXTRA_CA_CERTS": nil,
            "ACME_AUTH": nil,
            "BASH_ENV": nil,
            "OPENSSL_CONF": nil,
            "NPM_CONFIG_REGISTRY": nil,
            "DYLD_INSERT_LIBRARIES": nil
        ]) {
            let result = OpenClawSessionDiscovery(customRoot: state.path)
                .discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [
                canonicalPath(agentDirectory.appendingPathComponent("openclaw-agent.sqlite"))
            ])
            XCTAssertTrue(result.isAuthoritative,
                          "ordinary workspace variables remain usable while blocked keys stay out of validation")
        }
    }

    func testOpenClawDiscoveryBoundsValidatorThatIgnoresTermination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ValidatorTimeout-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let state = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(
            at: state.appendingPathComponent("agents/main/agent", isDirectory: true),
            withIntermediateDirectories: true)
        try writeText("{ agents: { entries: {} } }",
                      to: state.appendingPathComponent("openclaw.json"))

        let validator = root.appendingPathComponent("validator.sh")
        try writeText("""
        #!/bin/sh
        trap '' TERM
        while :; do :; done
        """, to: validator)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validator.path)

        let defaults = UserDefaults.standard
        let overrideKey = PreferencesKey.Paths.openClawBinaryOverride
        let previousOverride = defaults.string(forKey: overrideKey)
        defaults.set(validator.path, forKey: overrideKey)
        defer {
            if let previousOverride {
                defaults.set(previousOverride, forKey: overrideKey)
            } else {
                defaults.removeObject(forKey: overrideKey)
            }
        }

        let started = Date()
        let result = OpenClawSessionDiscovery(customRoot: state.path)
            .discoverSessionDatabaseResult()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative)
        XCTAssertLessThan(elapsed, 4.0,
                          "a validator that ignores SIGTERM must not block discovery")
    }

    func testOpenClawDiscoveryDrainsValidatorPipesBeforeWaiting() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ValidatorPipeDrain-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let state = root.appendingPathComponent("state", isDirectory: true)
        try fm.createDirectory(
            at: state.appendingPathComponent("agents/main/agent", isDirectory: true),
            withIntermediateDirectories: true)
        try writeText("{ agents: { entries: {} } }",
                      to: state.appendingPathComponent("openclaw.json"))

        let validator = root.appendingPathComponent("validator.sh")
        try writeText("""
        #!/bin/sh
        dd if=/dev/zero bs=262144 count=1 2>/dev/null
        dd if=/dev/zero bs=262144 count=1 1>&2 2>/dev/null
        exit 0
        """, to: validator)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: validator.path)

        let defaults = UserDefaults.standard
        let overrideKey = PreferencesKey.Paths.openClawBinaryOverride
        let previousOverride = defaults.string(forKey: overrideKey)
        defaults.set(validator.path, forKey: overrideKey)
        defer {
            if let previousOverride {
                defaults.set(previousOverride, forKey: overrideKey)
            } else {
                defaults.removeObject(forKey: overrideKey)
            }
        }

        let started = Date()
        let result = OpenClawSessionDiscovery(customRoot: state.path)
            .discoverSessionDatabaseResult()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative)
        XCTAssertLessThan(elapsed, 4.0,
                          "validator output larger than a pipe buffer must not deadlock discovery")
    }

    func testOpenClawDiscoveryResolvesLegacyAgentListExternalDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-LegacyAgentList-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let externalAgentDir = root.appendingPathComponent("legacy-agent", isDirectory: true)
        let database = externalAgentDir.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalAgentDir, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try writeText("""
        {
          agents: {
            list: [
              { id: 'legacy', agentDir: '\(externalAgentDir.path)', },
            ],
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: database), "legacy")
    }

    func testOpenClawDiscoveryExpandsEnvironmentVariableExternalDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-EnvironmentAgentDirectory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let externalAgentDir = root.appendingPathComponent("environment-agent", isDirectory: true)
        let database = externalAgentDir.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalAgentDir, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        let variable = "AGENT_SESSIONS_OPENCLAW_AGENT_DIR_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(variable, externalAgentDir.path, 1)
        defer { unsetenv(variable) }
        try writeText("""
        {
          agents: {
            entries: {
              environment: { agentDir: '${\(variable)}', },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: database), "environment")
    }

    func testOpenClawDiscoveryConcatenatesIncludedLegacyAgentLists() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-IncludedAgentLists-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("first-agent", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second-agent", isDirectory: true)
        let firstDatabase = firstDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let secondDatabase = secondDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        try writeText("""
        {
          agents: { list: [{ id: 'first', agentDir: '\(firstDirectory.path)' }] },
        }
        """, to: root.appendingPathComponent("first.json5"))
        try writeText("""
        {
          agents: { list: [{ id: 'second', agentDir: '\(secondDirectory.path)' }] },
        }
        """, to: root.appendingPathComponent("second.json5"))
        try writeText("""
        {
          $include: ['./first.json5', './second.json5'],
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        XCTAssertEqual(discovery.discoverSessionDatabases().map(canonicalPath),
                       [canonicalPath(firstDatabase), canonicalPath(secondDatabase)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: firstDatabase), "first")
        XCTAssertEqual(discovery.agentID(forDatabaseURL: secondDatabase), "second")
    }

    func testOpenClawDiscoveryMarksUnresolvedConfiguredDirectoryNonAuthoritative() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-UnresolvedAgentDirectory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let validDirectory = root.appendingPathComponent("valid-agent", isDirectory: true)
        let validDatabase = validDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: validDatabase)
        let variable = "AGENT_SESSIONS_OPENCLAW_UNRESOLVED_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(variable)
        defer { unsetenv(variable) }
        try writeText("""
        {
          agents: {
            entries: {
              valid: { agentDir: '\(validDirectory.path)' },
              unresolved: { agentDir: '${\(variable)}' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let result = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(validDatabase)])
        XCTAssertFalse(result.isAuthoritative)
    }

    func testOpenClawDiscoveryMarksMalformedAgentRosterNonAuthoritative() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-MalformedAgentRoster-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent("valid-agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try writeText("""
        {
          agents: {
            entries: {
              valid: 'not-an-agent-object',
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let result = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertFalse(result.isAuthoritative)
        XCTAssertTrue(result.databases.isEmpty)
    }

    func testOpenClawDiscoverySupportsJSON5HexEscapeInAgentDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-HexEscape-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let externalAgentDir = root.appendingPathComponent("hex-agent", isDirectory: true)
        let database = externalAgentDir.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalAgentDir, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        let json5Path = externalAgentDir.path.replacingOccurrences(of: "/", with: "\\x2f")
        try writeText("""
        {
          agents: {
            entries: {
              hex: { agentDir: '\(json5Path)' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let result = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(result.agentID(forDatabaseURL: database), "hex")
        XCTAssertTrue(result.isAuthoritative)
    }

    func testOpenClawDiscoveryKeepsDatabaseOwnerFromOneSnapshot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-SnapshotOwner-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("first-agent", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second-agent", isDirectory: true)
        let firstDatabase = firstDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let secondDatabase = secondDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        let config = root.appendingPathComponent("openclaw.json")
        try writeText("""
        { agents: { entries: { first: { agentDir: '\(firstDirectory.path)' } } } }
        """, to: config)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        let snapshot = discovery.discoverSessionDatabaseResult()
        try writeText("""
        { agents: { entries: { second: { agentDir: '\(secondDirectory.path)' } } } }
        """, to: config)

        XCTAssertEqual(snapshot.agentID(forDatabaseURL: firstDatabase), "first")
        XCTAssertEqual(snapshot.databases.map(canonicalPath), [canonicalPath(firstDatabase)])
        XCTAssertEqual(discovery.agentID(forDatabaseURL: secondDatabase), "second")
    }

    func testOpenClawDiscoveryConfiguredOwnerOverridesLayoutInference() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ConfiguredOwner-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let inferredDirectory = root.appendingPathComponent("agents/legacy/agent", isDirectory: true)
        let database = inferredDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: inferredDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try writeText("""
        {
          agents: {
            entries: {
              configured: { agentDir: '\(inferredDirectory.path)' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let result = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(result.agentID(forDatabaseURL: database), "configured")
        XCTAssertTrue(result.isAuthoritative)
    }

    func testOpenClawConfiguredAgentDirectoryReplacesObsoleteDefaultStore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ConfiguredStoreWins-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let defaultDirectory = root.appendingPathComponent("agents/worker/agent", isDirectory: true)
        let configuredDirectory = root.appendingPathComponent("external/worker", isDirectory: true)
        let defaultDatabase = defaultDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let configuredDatabase = configuredDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configuredDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: defaultDatabase)
        try createOpenClawSQLiteFixture(at: configuredDatabase)
        try writeText("""
        { agents: { entries: { WORKER: { agentDir: '\(configuredDirectory.path)' } } } }
        """, to: root.appendingPathComponent("openclaw.json"))

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        let configuredResult = discovery.discoverSessionDatabaseResult()
        XCTAssertEqual(configuredResult.databases.map(canonicalPath), [canonicalPath(configuredDatabase)])
        XCTAssertEqual(configuredResult.agentID(forDatabaseURL: configuredDatabase), "worker")
        XCTAssertTrue(configuredResult.isAuthoritative)

        try fm.removeItem(at: configuredDatabase)
        let missingConfiguredResult = discovery.discoverSessionDatabaseResult()
        XCTAssertTrue(missingConfiguredResult.databases.isEmpty)
        XCTAssertFalse(missingConfiguredResult.isAuthoritative,
                       "a missing configured replacement must not authorize retirement of the inferred store")
    }

    func testOpenClawConfiguredExternalStoreMoveFailsClosedBeforeReplacementAppears() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ExternalStoreMove-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("external/first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("external/second", isDirectory: true)
        let firstDatabase = firstDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let config = root.appendingPathComponent("openclaw.json")
        try fm.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try writeText("""
        { agents: { entries: { worker: { agentDir: '\(firstDirectory.path)' } } } }
        """, to: config)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        let initial = discovery.discoverSessionDatabaseResult()
        XCTAssertEqual(initial.databases.map(canonicalPath), [canonicalPath(firstDatabase)])
        XCTAssertTrue(initial.isAuthoritative)

        try writeText("""
        { agents: { entries: { worker: { agentDir: '\(secondDirectory.path)' } } } }
        """, to: config)
        let duringMove = discovery.discoverSessionDatabaseResult()
        XCTAssertTrue(duringMove.databases.isEmpty)
        XCTAssertFalse(duringMove.isAuthoritative,
                       "an external A-to-B move must not retire A while B is absent")
    }

    @MainActor
    func testOpenClawIndexerUsesConfiguredStoreDuringProductionRefresh() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-IndexerConfiguredStore-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let defaultDatabase = root.appendingPathComponent(
            "agents/worker/agent/openclaw-agent.sqlite")
        let configuredDatabase = root.appendingPathComponent(
            "external/worker/openclaw-agent.sqlite")
        try fm.createDirectory(at: defaultDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: configuredDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: defaultDatabase)
        try createOpenClawSQLiteFixture(at: configuredDatabase)
        try writeText("""
        {
          agents: {
            ownership: 'explicit',
            entries: {
              worker: { agentDir: '\(configuredDatabase.deletingLastPathComponent().path)' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)

            let fixtureSessions = indexer.allSessions.filter { $0.filePath.hasPrefix(root.path) }
            XCTAssertEqual(fixtureSessions.map(\.id), ["openclaw:worker:sqlite-demo"])
            XCTAssertEqual(fixtureSessions.first?.filePath, configuredDatabase.path,
                           "the production indexer must replace the inferred default store with the configured store")
            XCTAssertFalse(indexer.allSessions.contains { $0.filePath == defaultDatabase.path })
        }
    }

    @MainActor
    func testOpenClawFinalRefreshPreservesSearchPublicationAfterEpochBaseline() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-FinalRefreshSearchRace-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(discovery: discovery)
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)

            let finalProofReached = expectation(description: "final-refresh token proof captured")
            let releaseFinalProof = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeFinalPublicationHookForTesting {
                finalProofReached.fulfill()
                if releaseFinalProof.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("final-refresh token proof gate timed out before explicit release")
                }
            }
            defer {
                releaseFinalProof.signal()
                indexer.setRefreshBeforeFinalPublicationHookForTesting(nil)
            }

            let searchPublished = expectation(description: "search publication survives final refresh")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                        $0.text == "search race publication"
                    } == true
                }
                .prefix(1)
                .sink { _ in searchPublished.fulfill() }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [finalProofReached], timeout: 5)

            // Commit after the final token sample. The search publication below
            // must prove and preserve this newer SQLite snapshot instead of
            // being downgraded by the stale final candidate.
            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"database write publication"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let parsed = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))
            var replacedEvent = false
            var updatedEvents = parsed.events.map { event -> SessionEvent in
                guard !replacedEvent, event.text != nil else { return event }
                replacedEvent = true
                return SessionEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    kind: event.kind,
                    role: event.role,
                    text: "search race publication",
                    toolName: event.toolName,
                    toolInput: event.toolInput,
                    toolOutput: event.toolOutput,
                    messageID: event.messageID,
                    parentID: event.parentID,
                    isDelta: event.isDelta,
                    rawJSON: event.rawJSON)
            }
            XCTAssertTrue(replacedEvent)
            var searchSession = Session(
                id: parsed.id,
                source: .openclaw,
                startTime: parsed.startTime,
                endTime: parsed.endTime,
                model: parsed.model,
                filePath: parsed.filePath,
                fileSizeBytes: parsed.fileSizeBytes,
                eventCount: updatedEvents.count,
                events: updatedEvents)
            searchSession.sourceStorageIdentity = parsed.sourceStorageIdentity
            searchSession.sourceStorageRevision = parsed.sourceStorageRevision
            indexer.updateSession(searchSession)

            wait(for: [searchPublished], timeout: 5)
            cancellable?.cancel()
            releaseFinalProof.signal()
            waitForOpenClawIndexerQuiescence(indexer)

            XCTAssertTrue(indexer.allSessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                $0.text == "search race publication"
            } == true,
            "a search publication made after the final epoch baseline must not be clobbered")
        }
    }

    @MainActor
    func testOpenClawFinalRefreshPreservesHydrationPublicationAndTranscriptCache() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-HydrationFinalRefreshRace-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let parsed = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            var replacedEvent = false
            let updatedEvents = parsed.events.map { event -> SessionEvent in
                guard !replacedEvent, event.text != nil else { return event }
                replacedEvent = true
                return SessionEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    kind: event.kind,
                    role: event.role,
                    text: "hydration race publication",
                    toolName: event.toolName,
                    toolInput: event.toolInput,
                    toolOutput: event.toolOutput,
                    messageID: event.messageID,
                    parentID: event.parentID,
                    isDelta: event.isDelta,
                    rawJSON: event.rawJSON)
            }
            XCTAssertTrue(replacedEvent)
            var searchSession = Session(
                id: parsed.id,
                source: .openclaw,
                startTime: parsed.startTime,
                endTime: parsed.endTime,
                model: parsed.model,
                filePath: parsed.filePath,
                fileSizeBytes: parsed.fileSizeBytes,
                eventCount: updatedEvents.count,
                events: updatedEvents)
            searchSession.sourceStorageIdentity = parsed.sourceStorageIdentity
            searchSession.sourceStorageRevision = parsed.sourceStorageRevision

            let initialFullPublished = expectation(description: "full search publication is cached before refresh")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                        $0.text == "hydration race publication"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialFullPublished.fulfill() }
            indexer.updateSession(searchSession)
            wait(for: [initialFullPublished], timeout: 5)
            initialCancellable?.cancel()

            let hydrationWindowEvents = searchSession.events.map { event -> SessionEvent in
                guard event.text == "hydration race publication" else { return event }
                return SessionEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    kind: event.kind,
                    role: event.role,
                    text: "hydration window publication",
                    toolName: event.toolName,
                    toolInput: event.toolInput,
                    toolOutput: event.toolOutput,
                    messageID: event.messageID,
                    parentID: event.parentID,
                    isDelta: event.isDelta,
                    rawJSON: event.rawJSON)
            }
            var hydrationWindowSession = Session(
                id: searchSession.id,
                source: searchSession.source,
                startTime: searchSession.startTime,
                endTime: searchSession.endTime,
                model: searchSession.model,
                filePath: searchSession.filePath,
                fileSizeBytes: searchSession.fileSizeBytes,
                eventCount: hydrationWindowEvents.count,
                events: hydrationWindowEvents)
            hydrationWindowSession.sourceStorageIdentity = searchSession.sourceStorageIdentity
            hydrationWindowSession.sourceStorageRevision = searchSession.sourceStorageRevision

            // This refresh starts with a fully loaded current row. Hydration
            // must not downgrade it before the final scan gets a chance to
            // decide whether the database revision is still current.
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let retainedBeforeRace = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(retainedBeforeRace.events.contains { $0.text == "hydration race publication" })
            let retainedTranscript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: retainedBeforeRace,
                filters: .current(showTimestamps: false, showMeta: false),
                mode: .normal)
            XCTAssertEqual(indexer.searchTranscriptCache.getCached(baselineSession.id), retainedTranscript)

            let hydrationStarted = expectation(description: "hydration reaches publication gate")
            let releaseHydration = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeHydrationPublicationHookForTesting {
                hydrationStarted.fulfill()
                if releaseHydration.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("hydration publication gate timed out before explicit release")
                }
            }
            defer {
                releaseHydration.signal()
                indexer.setRefreshBeforeHydrationPublicationHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [hydrationStarted], timeout: 3)

            let searchPublished = expectation(description: "search publication is visible before hydration release")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                        $0.text == "hydration window publication"
                    } == true
                }
                .prefix(1)
                .sink { _ in searchPublished.fulfill() }
            indexer.updateSession(hydrationWindowSession)
            wait(for: [searchPublished], timeout: 5)
            cancellable?.cancel()

            releaseHydration.signal()
            waitForOpenClawIndexerQuiescence(indexer)

            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(finalSession.events.contains { $0.text == "hydration window publication" },
                          "the final lightweight row must not replace a newer hydration-window publication")
            let expectedTranscript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: finalSession,
                filters: .current(showTimestamps: false, showMeta: false),
                mode: .normal)
            XCTAssertEqual(indexer.searchTranscriptCache.getCached(baselineSession.id), expectedTranscript,
                           "the final handoff must preserve the transcript cache for the retained full row")
        }
    }

    @MainActor
    func testOpenClawFinalRefreshDoesNotRepromoteStalePreview() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-StalePreviewFinalRefresh-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "full preview race baseline is published")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let finalProofReached = expectation(description: "final token proof captured")
            let releaseFinalProof = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeFinalPublicationHookForTesting {
                finalProofReached.fulfill()
                if releaseFinalProof.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("final token proof gate timed out before explicit release")
                }
            }
            defer {
                releaseFinalProof.signal()
                indexer.setRefreshBeforeFinalPublicationHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [finalProofReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"stale preview update"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            indexer.refreshPreview(id: baselineSession.id)

            let stalePreviewReached = expectation(description: "preview marks full row stale")
            var stalePreviewCancellable: AnyCancellable?
            stalePreviewCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in stalePreviewReached.fulfill() }
            wait(for: [stalePreviewReached], timeout: 5)
            stalePreviewCancellable?.cancel()
            releaseFinalProof.signal()
            waitForOpenClawIndexerQuiescence(indexer)

            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(finalSession.events.isEmpty,
                          "a stale preview must not be republished as a proven full row")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "downgrading a stale full row must evict its transcript cache")
        }
    }

    @MainActor
    func testOpenClawFinalRefreshDoesNotRepromoteStaleJSONLPreview() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-StaleJSONLFinalRefresh-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent(
            "agents/main/sessions/jsonl-session.jsonl")
        try fm.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = #"{"type":"session","version":3,"id":"jsonl-session","timestamp":"2026-04-16T00:00:00.000Z","cwd":"/tmp/openclaw"}"#
        let user = #"{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"JSONL fixture"}]}}"#
        let assistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"record-model","content":[{"type":"text","text":"fixture response"}]}}"#
        try writeText([header, user, assistant].joined(separator: "\n") + "\n", to: sessionURL)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSessionParser.parseFileFull(
                    at: sessionURL,
                    forcedID: baselineSession.id))

            let fullPublished = expectation(description: "JSONL preview baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            try writeText([header, user,
                           #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"record-model","content":[{"type":"text","text":"updated JSONL response"}]}}"#]
                .joined(separator: "\n") + "\n", to: sessionURL)

            let staleReached = expectation(description: "JSONL preview marks full row stale")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in staleReached.fulfill() }
            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [staleReached], timeout: 5)
            staleCancellable?.cancel()

            let previewRefreshDowngraded = expectation(description: "stale JSONL refresh preview is downgraded")
            var previewRefreshCancellable: AnyCancellable?
            previewRefreshCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == true
                }
                .prefix(1)
                .sink { _ in previewRefreshDowngraded.fulfill() }
            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [previewRefreshDowngraded], timeout: 5)
            previewRefreshCancellable?.cancel()
            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "a JSONL refresh preview must not clear an accepted stale verdict")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "a JSONL refresh preview must not reinstall the stale transcript")

            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(finalSession.events.isEmpty,
                          "a stale JSONL preview must not be republished as a full row")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "downgrading a stale JSONL row must evict its transcript cache")
        }
    }

    @MainActor
    func testOpenClawFinalRefreshDoesNotBindNewJSONLStatToOlderPublication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-JSONLStatHandoff-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionURL = root.appendingPathComponent(
            "agents/main/sessions/jsonl-stat-session.jsonl")
        try fm.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = #"{"type":"session","version":3,"id":"jsonl-stat-session","timestamp":"2026-04-16T00:00:00.000Z","cwd":"/tmp/openclaw"}"#
        let user = #"{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"JSONL stat fixture"}]}}"#
        let assistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"record-model","content":[{"type":"text","text":"old JSONL response"}]}}"#
        try writeText([header, user, assistant].joined(separator: "\n") + "\n", to: sessionURL)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSessionParser.parseFileFull(
                    at: sessionURL,
                    forcedID: baselineSession.id))

            let fullPublished = expectation(description: "JSONL stat baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let statsReached = expectation(description: "final refresh stat sample is delayed")
            let releaseStats = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeFinalStatsHookForTesting {
                statsReached.fulfill()
                if releaseStats.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("final refresh stats gate timed out before explicit release")
                }
            }
            defer {
                releaseStats.signal()
                indexer.setRefreshBeforeFinalStatsHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [statsReached], timeout: 5)

            let updatedAssistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"record-model","content":[{"type":"text","text":"new JSONL response"}]}}"#
            try writeText([header, user, updatedAssistant].joined(separator: "\n") + "\n", to: sessionURL)
            releaseStats.signal()
            waitForOpenClawIndexerQuiescence(indexer)

            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(finalSession.events.isEmpty,
                          "final refresh must not pair the new JSONL stat with the older full transcript")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "final refresh must evict the transcript when its file proof no longer matches")
        }
    }

    @MainActor
    func testOpenClawReloadRejectsAliasRetargetAroundStableJSONLParse() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-JSONLAliasABA-\(UUID().uuidString)",
            isDirectory: true)
        let targetRoot = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-JSONLAliasABATargets-\(UUID().uuidString)",
            isDirectory: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: targetRoot)
        }

        let aliasURL = root.appendingPathComponent(
            "agents/main/sessions/alias-session.jsonl")
        let firstURL = targetRoot.appendingPathComponent("first.jsonl")
        let secondURL = targetRoot.appendingPathComponent("second.jsonl")
        try fm.createDirectory(at: aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"jsonl-alias-session","timestamp":"2026-04-16T00:00:00.000Z","cwd":"/tmp/openclaw"}"#
        let user = #"{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"alias fixture"}]}}"#
        let firstAssistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"first-model","content":[{"type":"text","text":"first target"}]}}"#
        let secondAssistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"second-model","content":[{"type":"text","text":"second target"}]}}"#
        try writeText([header, user, firstAssistant].joined(separator: "\n") + "\n", to: firstURL)
        try writeText([header, user, secondAssistant].joined(separator: "\n") + "\n", to: secondURL)
        try fm.createSymbolicLink(at: aliasURL, withDestinationURL: firstURL)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(
                indexer.allSessions.first(where: {
                    $0.filePath.hasSuffix("/agents/main/sessions/alias-session.jsonl")
                }))
            XCTAssertTrue(baselineSession.events.isEmpty,
                          "alias ABA regression must start from a lightweight row")
            XCTAssertTrue(baselineSession.filePath.hasSuffix(
                "/agents/main/sessions/alias-session.jsonl"),
                          "alias ABA regression must reload through the lexical symlink")

            let reloadHookReached = expectation(description: "alias reload reaches parse gate")
            indexer.setReloadBeforeParseHookForTesting {
                try? fm.removeItem(at: aliasURL)
                try? fm.createSymbolicLink(at: aliasURL, withDestinationURL: secondURL)
                reloadHookReached.fulfill()
            }
            let parserHookReached = expectation(description: "parser reaches descriptor proof gate")
            OpenClawSessionParser.setFullParseBeforeEndStatHookForTesting {
                try? fm.removeItem(at: aliasURL)
                try? fm.createSymbolicLink(at: aliasURL, withDestinationURL: firstURL)
                parserHookReached.fulfill()
            }
            let reloadTerminalReached = expectation(description: "alias reload reaches terminal handoff")
            indexer.setReloadTerminalHookForTesting {
                reloadTerminalReached.fulfill()
            }
            defer {
                indexer.setReloadBeforeParseHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
                OpenClawSessionParser.setFullParseBeforeEndStatHookForTesting(nil)
            }

            indexer.reloadSession(id: baselineSession.id,
                                  force: true,
                                  reason: .manualRefresh)
            wait(for: [reloadHookReached, parserHookReached, reloadTerminalReached], timeout: 5)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: aliasURL.path), firstURL.path,
                           "the parser proof hook must restore the original alias target")
            waitForOpenClawIndexerQuiescence(indexer)

            let current = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(current.events.isEmpty,
                          "a stable parse through a retargeted alias must not publish the wrong target")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "an alias-retargeted parse must not install a transcript cache")
        }
    }

    @MainActor
    func testOpenClawLightweightPreviewRejectsAliasRetargetBetweenOuterStats() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-JSONLLightAliasABA-\(UUID().uuidString)",
            isDirectory: true)
        let targetRoot = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-JSONLLightAliasABATargets-\(UUID().uuidString)",
            isDirectory: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: targetRoot)
        }

        let aliasURL = root.appendingPathComponent(
            "agents/main/sessions/alias-session.jsonl")
        let firstURL = targetRoot.appendingPathComponent("first.jsonl")
        let secondURL = targetRoot.appendingPathComponent("second.jsonl")
        try fm.createDirectory(at: aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"jsonl-light-alias-session","timestamp":"2026-04-16T00:00:00.000Z","cwd":"/tmp/openclaw"}"#
        let user = #"{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"alias fixture"}]}}"#
        let firstAssistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"first-model","content":[{"type":"text","text":"first target"}]}}"#
        let secondAssistant = #"{"type":"message","id":"assistant-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"assistant","model":"second-model","content":[{"type":"text","text":"second target"}]}}"#
        try writeText([header, user, firstAssistant].joined(separator: "\n") + "\n", to: firstURL)
        try writeText([header, user, secondAssistant].joined(separator: "\n") + "\n", to: secondURL)
        try fm.createSymbolicLink(at: aliasURL, withDestinationURL: firstURL)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(
                indexer.allSessions.first(where: {
                    $0.filePath.hasSuffix("/agents/main/sessions/alias-session.jsonl")
                }))
            XCTAssertEqual(baselineSession.model, "first-model")

            let beforeOpenReached = expectation(description: "lightweight parser opens after outer stat")
            let beforeEndReached = expectation(description: "lightweight parser reaches proof gate")
            let previewTerminalReached = expectation(description: "lightweight preview reaches terminal handoff")
            let hookLock = NSLock()
            var beforeOpenDidFulfill = false
            var beforeEndDidFulfill = false
            OpenClawSessionParser.setLightParseBeforeOpenStatHookForTesting {
                try? fm.removeItem(at: aliasURL)
                try? fm.createSymbolicLink(at: aliasURL, withDestinationURL: secondURL)
                hookLock.lock()
                let shouldFulfill = !beforeOpenDidFulfill
                beforeOpenDidFulfill = true
                hookLock.unlock()
                if shouldFulfill { beforeOpenReached.fulfill() }
            }
            OpenClawSessionParser.setLightParseBeforeEndStatHookForTesting {
                try? fm.removeItem(at: aliasURL)
                try? fm.createSymbolicLink(at: aliasURL, withDestinationURL: firstURL)
                hookLock.lock()
                let shouldFulfill = !beforeEndDidFulfill
                beforeEndDidFulfill = true
                hookLock.unlock()
                if shouldFulfill { beforeEndReached.fulfill() }
            }
            indexer.setRefreshPreviewTerminalHookForTesting {
                previewTerminalReached.fulfill()
            }
            defer {
                OpenClawSessionParser.setLightParseBeforeOpenStatHookForTesting(nil)
                OpenClawSessionParser.setLightParseBeforeEndStatHookForTesting(nil)
                indexer.setRefreshPreviewTerminalHookForTesting(nil)
            }

            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [beforeOpenReached, beforeEndReached, previewTerminalReached], timeout: 5)

            let current = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertEqual(current.model, "first-model",
                           "a lightweight parse through a retargeted alias must not publish B metadata")
            XCTAssertTrue(current.events.isEmpty,
                          "the lightweight preview must remain lightweight after proof rejection")
        }
    }

    @MainActor
    func testOpenClawHydrationDoesNotClearStalePreviewVerdict() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-HydrationStalePreview-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))
            let fullPublished = expectation(description: "hydration stale baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let hydrationReached = expectation(description: "hydration publication is delayed")
            let releaseHydration = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeHydrationPublicationHookForTesting {
                hydrationReached.fulfill()
                if releaseHydration.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("hydration stale gate timed out before explicit release")
                }
            }
            defer {
                releaseHydration.signal()
                indexer.setRefreshBeforeHydrationPublicationHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [hydrationReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hydration stale preview"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let staleReached = expectation(description: "hydration stale verdict is visible")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in staleReached.fulfill() }
            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [staleReached], timeout: 5)
            staleCancellable?.cancel()

            releaseHydration.signal()
            waitForOpenClawIndexerQuiescence(indexer)
            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "hydration must not clear an accepted stale preview verdict")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "hydration must not reinstall a stale transcript")
        }
    }

    @MainActor
    func testOpenClawOlderPreviewStalenessCannotClearNewerStalePreviewProof() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-PreviewStalenessRace-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "preview staleness baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let oldProofReached = expectation(description: "older preview proof is delayed")
            let oldProofSettled = expectation(description: "older preview proof settled")
            let releaseOldProof = DispatchSemaphore(value: 0)
            indexer.setPreviewStalenessBeforePublicationHookForTesting {
                oldProofReached.fulfill()
                if releaseOldProof.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("older preview proof gate timed out before explicit release")
                }
            }
            indexer.setPreviewStalenessTerminalHookForTesting {
                oldProofSettled.fulfill()
            }
            defer {
                releaseOldProof.signal()
                indexer.setPreviewStalenessBeforePublicationHookForTesting(nil)
                indexer.setPreviewStalenessTerminalHookForTesting(nil)
            }

            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [oldProofReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"newer stale preview"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let stalePreviewReached = expectation(description: "newer preview proof marks row stale")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in stalePreviewReached.fulfill() }
            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [stalePreviewReached], timeout: 5)
            staleCancellable?.cancel()

            releaseOldProof.signal()
            wait(for: [oldProofSettled], timeout: 2)

            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "an older fresh proof must not clear a newer stale preview verdict")
        }
    }

    @MainActor
    func testOpenClawUnprovableSQLiteStalenessMarksFreshLoadedRowStale() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-UnprovableFreshStaleness-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath.hasSuffix("openclaw-agent.sqlite") }))
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "fresh unprovable baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()
            XCTAssertFalse(indexer.previewStaleByID[baselineSession.id] == true,
                           "the accepted full row must begin fresh")

            try fm.removeItem(at: database)
            let unprovableReached = expectation(description: "fresh unprovable SQLite check reaches publication")
            let unprovableSettled = expectation(description: "fresh unprovable SQLite check settles")
            indexer.setPreviewStalenessBeforePublicationHookForTesting {
                unprovableReached.fulfill()
            }
            indexer.setPreviewStalenessTerminalHookForTesting {
                unprovableSettled.fulfill()
            }
            defer {
                indexer.setPreviewStalenessBeforePublicationHookForTesting(nil)
                indexer.setPreviewStalenessTerminalHookForTesting(nil)
            }

            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [unprovableReached, unprovableSettled], timeout: 5)

            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "an unprovable SQLite revision must mark a fresh loaded row stale")
        }
    }

    @MainActor
    func testOpenClawUnprovableSQLiteStalenessDoesNotClearConfirmedStaleVerdict() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-UnprovableStaleness-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "unprovable staleness baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"confirmed stale revision"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let staleReached = expectation(description: "SQLite revision mismatch marks row stale")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in staleReached.fulfill() }
            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [staleReached], timeout: 5)
            staleCancellable?.cancel()

            // Remove the lexical path so the next revision read is unprovable.
            // The cached SQLite handle must not turn that absence into a fresh verdict.
            try fm.removeItem(at: database)
            let unprovableReached = expectation(description: "unprovable SQLite check reaches publication")
            let unprovableSettled = expectation(description: "unprovable SQLite check settles")
            indexer.setPreviewStalenessBeforePublicationHookForTesting {
                unprovableReached.fulfill()
            }
            indexer.setPreviewStalenessTerminalHookForTesting {
                unprovableSettled.fulfill()
            }
            defer {
                indexer.setPreviewStalenessBeforePublicationHookForTesting(nil)
                indexer.setPreviewStalenessTerminalHookForTesting(nil)
            }

            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [unprovableReached, unprovableSettled], timeout: 5)

            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "an unprovable SQLite revision must not clear a confirmed stale verdict")
        }
    }

    @MainActor
    func testOpenClawNewerRefreshPreviewSupersedesOlderProof() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-RefreshPreviewGeneration-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "refresh preview generation baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let firstProofReached = expectation(description: "first preview proof is delayed")
            let previewsSettled = expectation(description: "competing previews settled")
            let releaseFirstProof = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            var terminalCalls = 0
            var terminalExpectationFulfilled = false
            indexer.setRefreshPreviewAfterProofHookForTesting {
                hookLock.lock()
                hookCalls += 1
                let isFirst = hookCalls == 1
                hookLock.unlock()
                if isFirst {
                    firstProofReached.fulfill()
                    if releaseFirstProof.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("first preview proof gate timed out before explicit release")
                    }
                }
            }
            indexer.setRefreshPreviewTerminalHookForTesting {
                hookLock.lock()
                terminalCalls += 1
                let shouldFulfill = terminalCalls >= 2 && !terminalExpectationFulfilled
                terminalExpectationFulfilled = terminalExpectationFulfilled || shouldFulfill
                hookLock.unlock()
                if shouldFulfill { previewsSettled.fulfill() }
            }
            defer {
                releaseFirstProof.signal()
                indexer.setRefreshPreviewAfterProofHookForTesting(nil)
                indexer.setRefreshPreviewTerminalHookForTesting(nil)
            }

            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [firstProofReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"newer refresh preview"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let stalePreviewReached = expectation(description: "newer preview reports stale")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in stalePreviewReached.fulfill() }
            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [stalePreviewReached], timeout: 5)
            staleCancellable?.cancel()

            releaseFirstProof.signal()
            wait(for: [previewsSettled], timeout: 5)

            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "an older refresh preview must not suppress a newer stale proof")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "the newer stale proof must not leave the old transcript cached")
        }
    }

    @MainActor
    func testOpenClawNewerPreviewStalenessSupersedesOlderRefreshPreview() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-PreviewReverseRace-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))
            let initialPublished = expectation(description: "reverse preview baseline is full")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in initialPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialPublished], timeout: 5)
            initialCancellable?.cancel()

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"first preview revision"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let firstRevision = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))
            let firstRevisionPublished = expectation(description: "first preview revision is full")
            var firstRevisionCancellable: AnyCancellable?
            firstRevisionCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                        $0.text == "first preview revision"
                    } == true
                }
                .prefix(1)
                .sink { _ in firstRevisionPublished.fulfill() }
            indexer.updateSession(firstRevision)
            wait(for: [firstRevisionPublished], timeout: 5)
            firstRevisionCancellable?.cancel()

            let oldPreviewReached = expectation(description: "older refresh preview proof is delayed")
            let oldPreviewSettled = expectation(description: "older refresh preview settled")
            let newerStalenessSettled = expectation(description: "newer staleness proof settled")
            let releaseOldPreview = DispatchSemaphore(value: 0)
            indexer.setRefreshPreviewAfterProofHookForTesting {
                oldPreviewReached.fulfill()
                if releaseOldPreview.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("older refresh preview gate timed out before explicit release")
                }
            }
            indexer.setRefreshPreviewTerminalHookForTesting {
                oldPreviewSettled.fulfill()
            }
            indexer.setPreviewStalenessTerminalHookForTesting {
                newerStalenessSettled.fulfill()
            }
            defer {
                releaseOldPreview.signal()
                indexer.setRefreshPreviewAfterProofHookForTesting(nil)
                indexer.setRefreshPreviewTerminalHookForTesting(nil)
                indexer.setPreviewStalenessTerminalHookForTesting(nil)
            }

            indexer.refreshPreview(id: baselineSession.id)
            wait(for: [oldPreviewReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"second preview revision"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let staleReached = expectation(description: "newer staleness proof is visible")
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$previewStaleByID
                .filter { $0[baselineSession.id] == true }
                .prefix(1)
                .sink { _ in staleReached.fulfill() }
            _ = indexer.isPreviewStale(id: baselineSession.id)
            wait(for: [staleReached], timeout: 5)
            staleCancellable?.cancel()

            releaseOldPreview.signal()
            wait(for: [oldPreviewSettled, newerStalenessSettled], timeout: 5)

            XCTAssertTrue(indexer.previewStaleByID[baselineSession.id] == true,
                          "a newer staleness verdict must invalidate an older fresh preview")
            XCTAssertNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                         "a newer stale verdict must evict the older preview transcript")
        }
    }

    @MainActor
    func testOpenClawFinalRefreshDoesNotDowngradePublicationAfterHandoffSnapshot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-FinalRefreshLatePublication-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let baselineSession = try XCTUnwrap(indexer.allSessions.first)
            let full = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))

            let fullPublished = expectation(description: "late publication baseline is full")
            var fullCancellable: AnyCancellable?
            fullCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in fullPublished.fulfill() }
            indexer.updateSession(full)
            wait(for: [fullPublished], timeout: 5)
            fullCancellable?.cancel()

            let handoffReached = expectation(description: "final handoff snapshot captured")
            let releaseHandoff = DispatchSemaphore(value: 0)
            indexer.setRefreshAfterHandoffSnapshotHookForTesting {
                handoffReached.fulfill()
                if releaseHandoff.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("refresh handoff gate timed out before explicit release")
                }
            }
            defer {
                releaseHandoff.signal()
                indexer.setRefreshAfterHandoffSnapshotHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [handoffReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"late handoff publication"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let newer = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: baselineSession.id))
            let newerPublished = expectation(description: "late newer publication is visible")
            var newerCancellable: AnyCancellable?
            newerCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == baselineSession.id })?.events.contains {
                        $0.text == "late handoff publication"
                    } == true
                }
                .prefix(1)
                .sink { _ in newerPublished.fulfill() }
            indexer.updateSession(newer)
            wait(for: [newerPublished], timeout: 5)
            newerCancellable?.cancel()

            releaseHandoff.signal()
            waitForOpenClawIndexerQuiescence(indexer)

            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == baselineSession.id }))
            XCTAssertTrue(finalSession.events.contains { $0.text == "late handoff publication" },
                          "a publication after handoff validation must not be downgraded")
            XCTAssertNotNil(indexer.searchTranscriptCache.getCached(baselineSession.id),
                            "the retained late publication must keep its transcript cache")
        }
    }

    @MainActor
    func testOpenClawReloadRequestedAfterRefreshGenerationChangeIsNotDropped() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadGeneration-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == database.path })?.id)

            let firstReloadStarted = expectation(description: "first reload reaches parse gate")
            let firstReloadRelease = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                hookCalls += 1
                let isFirst = hookCalls == 1
                hookLock.unlock()
                if isFirst {
                    firstReloadStarted.fulfill()
                    if firstReloadRelease.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("first reload generation gate timed out before explicit release")
                    }
                }
            }
            defer {
                firstReloadRelease.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .focusedSessionMonitor)
            wait(for: [firstReloadStarted], timeout: 3)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"updated transcript"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            // This advances the refresh token while the old reload is still
            // in flight. The second request must replace the obsolete worker,
            // not coalesce into a request that will be rejected as stale.
            let secondReloadFinished = expectation(description: "new-generation reload reaches terminal handoff")
            let terminalLock = NSLock()
            var terminalCount = 0
            indexer.setReloadTerminalHookForTesting {
                terminalLock.lock()
                terminalCount += 1
                let isSecond = terminalCount == 2
                terminalLock.unlock()
                if isSecond {
                    secondReloadFinished.fulfill()
                }
            }
            defer {
                indexer.setReloadTerminalHookForTesting(nil)
            }
            indexer.refresh(mode: .fullReconcile)
            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .selection)
            firstReloadRelease.signal()

            wait(for: [secondReloadFinished], timeout: 20)
            waitForOpenClawIndexerQuiescence(indexer)
            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "updated transcript"
                } == true,
                "a stale final-refresh publication must not clobber the newer reload")
            hookLock.lock()
            let reloadCount = hookCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(reloadCount, 2,
                                        "the reload requested after refresh must run as a separate worker")
        }
    }

    @MainActor
    func testOpenClawIdenticalReloadDuringSourceDriftIsRetried() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadSourceDriftRetry-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialFullPublished = expectation(description: "full baseline is visible before coalescing race")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "fixture response"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialFullPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialFullPublished], timeout: 5)
            initialCancellable?.cancel()

            let firstReloadStarted = expectation(description: "source-drift reload reaches parse gate")
            let releaseFirstReload = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var parseHookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                parseHookCalls += 1
                let isFirst = parseHookCalls == 1
                hookLock.unlock()
                if isFirst {
                    firstReloadStarted.fulfill()
                    if releaseFirstReload.wait(timeout: .now() + 20) == .timedOut {
                        XCTFail("source-drift reload gate timed out before explicit release")
                    }
                }
            }
            let secondReloadFinished = expectation(description: "coalesced source-drift reload is retried")
            let pendingReloadRecorded = expectation(description: "identical reload is recorded as pending")
            let weakerReloadAttemptedDuringTerminalCleanup = expectation(
                description: "weaker reload is attempted before terminal cleanup")
            let terminalLock = NSLock()
            var terminalCount = 0
            let terminalCleanupLock = NSLock()
            var terminalCleanupCount = 0
            indexer.setReloadPendingRecordedHookForTesting {
                pendingReloadRecorded.fulfill()
            }
            indexer.setReloadBeforeTerminalCleanupHookForTesting {
                terminalCleanupLock.lock()
                terminalCleanupCount += 1
                let isFirst = terminalCleanupCount == 1
                terminalCleanupLock.unlock()
                if isFirst {
                    // Exercise the window in which the old implementation had
                    // already removed the strong worker from its map but had
                    // not yet consumed the pending request.
                    indexer.reloadSession(id: sessionID, force: false, reason: .selection)
                    weakerReloadAttemptedDuringTerminalCleanup.fulfill()
                }
            }
            indexer.setReloadTerminalHookForTesting {
                terminalLock.lock()
                terminalCount += 1
                let isSecond = terminalCount == 2
                terminalLock.unlock()
                if isSecond {
                    secondReloadFinished.fulfill()
                }
            }
            defer {
                releaseFirstReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
                indexer.setReloadPendingRecordedHookForTesting(nil)
                indexer.setReloadBeforeTerminalCleanupHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [firstReloadStarted], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"retried source drift"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            // The identical request coalesces with the worker that still
            // carries the pre-write proof. Its pending request must be
            // replayed after that worker rejects the drifted snapshot.
            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [pendingReloadRecorded], timeout: 5)
            releaseFirstReload.signal()

            wait(for: [weakerReloadAttemptedDuringTerminalCleanup, secondReloadFinished], timeout: 20)
            waitForOpenClawIndexerQuiescence(indexer)
            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "retried source drift"
                } == true,
                "a coalesced request must be retried after its worker rejects a drifted proof")
            hookLock.lock()
            let reloadCount = parseHookCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(reloadCount, 2)
        }
    }

    @MainActor
    func testOpenClawPendingReloadSurvivesSupersedingGeneration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-PendingReloadOwner-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialPublished = expectation(description: "full baseline is visible")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "fixture response"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialPublished], timeout: 5)
            initialCancellable?.cancel()

            let firstReloadStarted = expectation(description: "first generation reaches parse gate")
            let secondReloadStarted = expectation(description: "superseding generation reaches parse gate")
            let releaseFirstReload = DispatchSemaphore(value: 0)
            let releaseSecondReload = DispatchSemaphore(value: 0)
            let parseLock = NSLock()
            var parseHookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                parseLock.lock()
                parseHookCalls += 1
                let call = parseHookCalls
                parseLock.unlock()
                if call == 1 {
                    firstReloadStarted.fulfill()
                    if releaseFirstReload.wait(timeout: .now() + 20) == .timedOut {
                        XCTFail("first generation gate timed out before explicit release")
                    }
                } else if call == 2 {
                    secondReloadStarted.fulfill()
                    if releaseSecondReload.wait(timeout: .now() + 20) == .timedOut {
                        XCTFail("second generation gate timed out before explicit release")
                    }
                }
            }

            let pendingRecorded = expectation(description: "pending request is owned by second generation")
            indexer.setReloadPendingRecordedHookForTesting {
                pendingRecorded.fulfill()
            }
            let firstTerminal = expectation(description: "superseded first generation reaches terminal handoff")
            let terminalLock = NSLock()
            var terminalCount = 0
            indexer.setReloadTerminalHookForTesting {
                terminalLock.lock()
                terminalCount += 1
                let isFirst = terminalCount == 1
                terminalLock.unlock()
                if isFirst {
                    firstTerminal.fulfill()
                }
            }
            defer {
                releaseFirstReload.signal()
                releaseSecondReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
                indexer.setReloadPendingRecordedHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [firstReloadStarted], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"generation two baseline"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let generationTwo = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let generationTwoPublished = expectation(description: "second generation baseline is published")
            var generationTwoCancellable: AnyCancellable?
            generationTwoCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "generation two baseline"
                    } == true
                }
                .prefix(1)
                .sink { _ in generationTwoPublished.fulfill() }
            indexer.updateSession(generationTwo)
            wait(for: [generationTwoPublished], timeout: 10)
            generationTwoCancellable?.cancel()

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [secondReloadStarted], timeout: 5)
            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [pendingRecorded], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"generation three retry"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            releaseFirstReload.signal()
            wait(for: [firstTerminal], timeout: 10)

            XCTAssertTrue(
                indexer.pendingReloadIsOwnedByLatestGenerationForTesting(id: sessionID),
                "the superseded first generation must not consume the second generation's pending request")
            parseLock.lock()
            let parseCallsBeforeSecondRelease = parseHookCalls
            parseLock.unlock()
            XCTAssertEqual(
                parseCallsBeforeSecondRelease,
                2,
                "the first generation must not launch the pending request while the second remains blocked")

            let retriedPublication = expectation(description: "second generation pending request is replayed")
            var retriedCancellable: AnyCancellable?
            retriedCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "generation three retry"
                    } == true
                }
                .prefix(1)
                .sink { _ in retriedPublication.fulfill() }
            releaseSecondReload.signal()
            wait(for: [retriedPublication], timeout: 20)
            retriedCancellable?.cancel()
            waitForOpenClawIndexerQuiescence(indexer)

            parseLock.lock()
            let observedParseHookCalls = parseHookCalls
            parseLock.unlock()
            XCTAssertGreaterThanOrEqual(observedParseHookCalls, 3,
                                        "the owned pending request must launch a retry after the superseded worker fails")
            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "generation three retry"
                } == true)
        }
    }

    @MainActor
    func testOpenClawPendingReloadSurvivesRefreshTokenInvalidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-PendingReloadRefreshToken-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialPublished = expectation(description: "full baseline is visible")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "fixture response"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialPublished], timeout: 5)
            initialCancellable?.cancel()

            let firstReloadStarted = expectation(description: "first generation reaches parse gate")
            let secondReloadStarted = expectation(description: "pending request replays under new refresh token")
            let releaseFirstReload = DispatchSemaphore(value: 0)
            let parseLock = NSLock()
            var parseHookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                parseLock.lock()
                parseHookCalls += 1
                let call = parseHookCalls
                parseLock.unlock()
                if call == 1 {
                    firstReloadStarted.fulfill()
                    if releaseFirstReload.wait(timeout: .now() + 20) == .timedOut {
                        XCTFail("first generation gate timed out before explicit release")
                    }
                } else if call == 2 {
                    secondReloadStarted.fulfill()
                }
            }
            let pendingRecorded = expectation(description: "identical request is recorded as pending")
            indexer.setReloadPendingRecordedHookForTesting {
                pendingRecorded.fulfill()
            }
            defer {
                releaseFirstReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
                indexer.setReloadPendingRecordedHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [firstReloadStarted], timeout: 5)
            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [pendingRecorded], timeout: 5)

            // Advancing the refresh token without starting another reload must
            // not let the terminal handoff discard the pending request.
            indexer.refresh(mode: .fullReconcile)
            releaseFirstReload.signal()

            wait(for: [secondReloadStarted], timeout: 20)
            waitForOpenClawIndexerQuiescence(indexer)

            parseLock.lock()
            let observedParseHookCalls = parseHookCalls
            parseLock.unlock()
            XCTAssertGreaterThanOrEqual(
                observedParseHookCalls,
                2,
                "refresh-token invalidation must replay the owned pending reload")
            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "fixture response"
                } == true)
        }
    }

    @MainActor
    func testOpenClawReloadPublicationCommitRejectsLateSupersession() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-LatePublicationSupersession-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialPublished = expectation(description: "full baseline is visible")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "fixture response"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialPublished], timeout: 5)
            initialCancellable?.cancel()
            let baselineTranscript = try XCTUnwrap(
                indexer.searchTranscriptCache.getCached(sessionID))

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"generation one"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let hookLock = NSLock()
            var commitCalls = 0
            var parseCalls = 0
            var terminalCalls = 0
            var mutationError: Error?
            let lateSupersessionInjected = expectation(description: "G2 supersedes G1 after G1's latest check")
            let secondParseStarted = expectation(description: "G2 is held before its publication")
            let releaseSecondParse = DispatchSemaphore(value: 0)
            let firstTerminal = expectation(description: "G1 completes terminal cleanup before G2 publishes")
            let winnerPublished = expectation(description: "G2 publishes the newer revision")
            var stalePublicationCount = 0
            var staleCancellable: AnyCancellable?
            staleCancellable = indexer.$allSessions.sink { sessions in
                guard sessions.first(where: { $0.id == sessionID })?.events.contains(where: {
                    $0.text == "generation one"
                }) == true else { return }
                hookLock.lock()
                stalePublicationCount += 1
                hookLock.unlock()
            }
            var winnerCancellable: AnyCancellable?
            winnerCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "generation two winner"
                    } == true
                }
                .prefix(1)
                .sink { _ in winnerPublished.fulfill() }

            indexer.setReloadBeforePublicationCommitHookForTesting {
                hookLock.lock()
                commitCalls += 1
                let call = commitCalls
                hookLock.unlock()
                if call == 1 {
                    do {
                        try self.executeSQLite("""
                        UPDATE transcript_events
                        SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"generation two winner"}]}}'
                        WHERE session_id = 'sqlite-demo' AND seq = 2;
                        """, at: database)
                    } catch {
                        mutationError = error
                    }
                    // This call is intentionally made from the commit hook:
                    // G1 has passed its earlier latest-generation check, so
                    // the stronger G2 registration lands in the exact window
                    // before publication bookkeeping.
                    indexer.reloadSession(id: sessionID,
                                          force: true,
                                          reason: .manualRefresh)
                    lateSupersessionInjected.fulfill()
                }
            }
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                parseCalls += 1
                let call = parseCalls
                hookLock.unlock()
                if call == 2 {
                    secondParseStarted.fulfill()
                    if releaseSecondParse.wait(timeout: .now() + 20) == .timedOut {
                        XCTFail("G2 parse gate timed out before explicit release")
                    }
                }
            }
            indexer.setReloadTerminalHookForTesting {
                hookLock.lock()
                terminalCalls += 1
                let call = terminalCalls
                hookLock.unlock()
                if call == 1 {
                    firstTerminal.fulfill()
                }
            }
            defer {
                releaseSecondParse.signal()
                staleCancellable?.cancel()
                winnerCancellable?.cancel()
                indexer.setReloadBeforeParseHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
                indexer.setReloadBeforePublicationCommitHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [lateSupersessionInjected], timeout: 10)
            wait(for: [secondParseStarted, firstTerminal], timeout: 10)
            hookLock.lock()
            let observedStalePublicationCount = stalePublicationCount
            hookLock.unlock()
            XCTAssertEqual(
                observedStalePublicationCount,
                0,
                "G1 must not publish even transiently while G2 is held before publication")
            XCTAssertEqual(
                indexer.searchTranscriptCache.getCached(sessionID),
                baselineTranscript,
                "G1 must not overwrite the baseline transcript cache")

            releaseSecondParse.signal()
            wait(for: [winnerPublished], timeout: 20)
            waitForOpenClawIndexerQuiescence(indexer)

            let finalSession = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == sessionID }))
            XCTAssertNil(mutationError, "the late-supersession fixture mutation must succeed")
            XCTAssertTrue(finalSession.events.contains { $0.text == "generation two winner" })
            XCTAssertFalse(finalSession.events.contains { $0.text == "generation one" },
                           "a late-superseded G1 must not publish over G2")
            hookLock.lock()
            let observedCommitCalls = commitCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(observedCommitCalls, 2)
        }
    }

    @MainActor
    func testOpenClawReloadFillsHydratedLightweightRowWithMatchingDatabaseVersion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadHydrationProof-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hydrated proof branch"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)

            let hydrationReached = expectation(description: "refresh reaches hydration publication gate")
            let releaseHydration = DispatchSemaphore(value: 0)
            indexer.setRefreshBeforeHydrationPublicationHookForTesting {
                hydrationReached.fulfill()
                if releaseHydration.wait(timeout: .now() + 20) == .timedOut {
                    XCTFail("hydration publication gate timed out before explicit release")
                }
            }
            let reloadProofReached = expectation(description: "reload proves the current SQLite snapshot")
            let releaseReload = DispatchSemaphore(value: 0)
            indexer.setReloadBeforePublicationHookForTesting {
                reloadProofReached.fulfill()
                if releaseReload.wait(timeout: .now() + 20) == .timedOut {
                    XCTFail("reload publication gate timed out before explicit release")
                }
            }
            let reloadFinished = expectation(description: "reload reaches terminal handoff")
            indexer.setReloadTerminalHookForTesting {
                reloadFinished.fulfill()
            }
            defer {
                releaseHydration.signal()
                releaseReload.signal()
                indexer.setRefreshBeforeHydrationPublicationHookForTesting(nil)
                indexer.setReloadBeforePublicationHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.refresh(mode: .fullReconcile)
            wait(for: [hydrationReached], timeout: 5)

            let lightweightPublished = expectation(description: "hydration publishes a proofed lightweight row")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .dropFirst()
                .filter { sessions in
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return false
                    }
                    return session.events.isEmpty
                        && session.sourceStorageRevision == nil
                        && session.sourceStorageDatabaseVersion != nil
                }
                .prefix(1)
                .sink { _ in lightweightPublished.fulfill() }

            // The refresh token is current while hydration is paused, so the
            // reload must be allowed to fill the row that hydration publishes.
            indexer.reloadSession(id: sessionID, force: true, reason: .manualRefresh)
            wait(for: [reloadProofReached], timeout: 5)
            releaseHydration.signal()
            wait(for: [lightweightPublished], timeout: 10)
            cancellable?.cancel()

            releaseReload.signal()
            wait(for: [reloadFinished], timeout: 10)
            waitForOpenClawIndexerQuiescence(indexer)
            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "hydrated proof branch"
                } == true,
                "a full reload must fill a hydration row when the database-version proof matches")
        }
    }

    @MainActor
    func testOpenClawReloadRejectsSourceChangeAfterProof() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadPublicationProof-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialFullPublished = expectation(description: "initial full transcript is visible")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "fixture response"
                    } == true
                }
                .prefix(1)
                .sink { _ in initialFullPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialFullPublished], timeout: 5)
            initialCancellable?.cancel()

            let proofReached = expectation(description: "reload reaches publication proof gate")
            let reloadFinished = expectation(description: "proof-rejected reload reaches terminal handoff")
            let mutationLock = NSLock()
            var mutationError: Error?
            indexer.setReloadBeforePublicationHookForTesting {
                // This mutation happens after the worker's parse-time proof
                // and before the MainActor publication boundary.
                do {
                    try self.executeSQLite("""
                    UPDATE transcript_events
                    SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"post-proof drift"}]}}'
                    WHERE session_id = 'sqlite-demo' AND seq = 2;
                    """, at: database)
                } catch {
                    mutationLock.lock()
                    mutationError = error
                    mutationLock.unlock()
                }
                proofReached.fulfill()
            }
            indexer.setReloadTerminalHookForTesting {
                reloadFinished.fulfill()
            }
            defer {
                indexer.setReloadBeforePublicationHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [proofReached, reloadFinished], timeout: 10)
            waitForOpenClawIndexerQuiescence(indexer)
            mutationLock.lock()
            let observedMutationError = mutationError
            mutationLock.unlock()
            XCTAssertNil(observedMutationError, "post-proof source mutation must succeed")

            let published = try XCTUnwrap(indexer.allSessions.first(where: { $0.id == sessionID }))
            XCTAssertTrue(published.events.contains { $0.text == "fixture response" },
                          "the prior accepted transcript remains visible after proof rejection")
            XCTAssertFalse(published.events.contains { $0.text == "post-proof drift" },
                           "a source mutation after parse proof must not publish that stale result")
        }
    }

    @MainActor
    func testOpenClawReloadDoesNotOverwriteNewerSameStorePublication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadSameStorePublication-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let proofReached = expectation(description: "reload proves the old snapshot")
            let oldReloadSettled = expectation(description: "old reload handoff settled")
            let releaseReload = DispatchSemaphore(value: 0)
            indexer.setReloadBeforePublicationHookForTesting {
                proofReached.fulfill()
                if releaseReload.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("reload publication gate timed out before explicit release")
                }
            }
            indexer.setReloadTerminalHookForTesting {
                oldReloadSettled.fulfill()
            }
            defer {
                releaseReload.signal()
                indexer.setReloadBeforePublicationHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .selection)
            wait(for: [proofReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"newer same-store publication"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let newer = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))

            let newerPublished = expectation(description: "newer same-store publication is visible")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "newer same-store publication"
                    } == true
                }
                .prefix(1)
                .sink { _ in newerPublished.fulfill() }
            indexer.updateSession(newer)
            wait(for: [newerPublished], timeout: 5)
            cancellable?.cancel()

            releaseReload.signal()
            wait(for: [oldReloadSettled], timeout: 5)

            XCTAssertTrue(
                indexer.allSessions.first(where: { $0.id == sessionID })?.events.contains {
                    $0.text == "newer same-store publication"
                } == true,
                "a reload proved against an older same-store snapshot must not clobber a newer publication")
        }
    }

    @MainActor
    func testOpenClawOlderFullReloadCannotOverwriteNewerLightweightSQLitePublication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadLightweightPublicationRace-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)

            let initialFull = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: database,
                    sessionID: sessionID))
            let initialFullPublished = expectation(description: "R1 full reload is visible")
            var initialCancellable: AnyCancellable?
            initialCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.isEmpty == false
                }
                .prefix(1)
                .sink { _ in initialFullPublished.fulfill() }
            indexer.updateSession(initialFull)
            wait(for: [initialFullPublished], timeout: 5)
            initialCancellable?.cancel()

            let oldProofReached = expectation(description: "R1 full reload reaches publication gate")
            let oldReloadSettled = expectation(description: "R1 full reload reaches terminal handoff")
            let releaseOldReload = DispatchSemaphore(value: 0)
            indexer.setReloadBeforePublicationHookForTesting {
                oldProofReached.fulfill()
                if releaseOldReload.wait(timeout: .now() + 20) == .timedOut {
                    XCTFail("R1 full reload gate timed out before explicit release")
                }
            }
            indexer.setReloadTerminalHookForTesting {
                oldReloadSettled.fulfill()
            }
            defer {
                releaseOldReload.signal()
                indexer.setReloadBeforePublicationHookForTesting(nil)
                indexer.setReloadTerminalHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID, force: true, reason: .manualRefresh)
            wait(for: [oldProofReached], timeout: 5)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"newer lightweight revision"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: database)
            let newerLightweight = try XCTUnwrap(
                OpenClawSqliteReader.listSessionWithProof(
                    databaseURL: database,
                    sessionID: sessionID)?.session)
            let newerRevisionKey = try XCTUnwrap(newerLightweight.sourceStorageRevision)
            XCTAssertTrue(newerLightweight.events.isEmpty)

            let lightweightPublished = expectation(description: "R2 lightweight publication is visible")
            var lightweightCancellable: AnyCancellable?
            lightweightCancellable = indexer.$allSessions
                .filter { sessions in
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return false
                    }
                    return session.events.isEmpty
                        && session.sourceStorageRevision == newerRevisionKey
                }
                .prefix(1)
                .sink { _ in lightweightPublished.fulfill() }
            indexer.updateSession(newerLightweight)
            wait(for: [lightweightPublished], timeout: 25)
            lightweightCancellable?.cancel()

            releaseOldReload.signal()
            wait(for: [oldReloadSettled], timeout: 5)

            let current = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == sessionID }))
            XCTAssertTrue(current.events.isEmpty,
                          "an older full reload must not repopulate a newer lightweight row")
            XCTAssertEqual(current.sourceStorageRevision, newerRevisionKey,
                           "the newer lightweight logical revision must remain authoritative")
        }
    }

    @MainActor
    func testOpenClawReloadRequestedAfterSameRefreshStoreMoveIsNotCoalesced() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-SameRefreshStoreMove-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        let replacementDatabase = root.appendingPathComponent(
            "relocated/main/openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: replacementDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: replacementDatabase)
        try executeSQLite("""
        UPDATE transcript_events
        SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"same-refresh replacement"}]}}'
        WHERE session_id = 'sqlite-demo' AND seq = 2;
        """, at: replacementDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == firstDatabase.path })?.id)

            let firstReloadStarted = expectation(description: "first reload reaches parse gate")
            let firstReloadRelease = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                hookCalls += 1
                let isFirst = hookCalls == 1
                hookLock.unlock()
                if isFirst {
                    firstReloadStarted.fulfill()
                    if firstReloadRelease.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("first reload store-move gate timed out before explicit release")
                    }
                }
            }
            defer {
                firstReloadRelease.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .focusedSessionMonitor)
            wait(for: [firstReloadStarted], timeout: 3)

            // Model a same-refresh discovery publication that has already
            // moved the stable session identity from A to B. The second
            // request must not coalesce with the in-flight A worker merely
            // because the refresh token is unchanged.
            indexer.replaceSessionStoragePathForTesting(
                id: sessionID,
                path: replacementDatabase.path)
            let updated = expectation(description: "same-refresh replacement reload publishes")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return false
                    }
                    return session.filePath == replacementDatabase.path
                        && session.events.contains { $0.text == "same-refresh replacement" }
                }
                .prefix(1)
                .sink { _ in updated.fulfill() }
            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .selection)
            firstReloadRelease.signal()

            wait(for: [updated], timeout: 5)
            cancellable?.cancel()
            hookLock.lock()
            let reloadCount = hookCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(reloadCount, 2,
                                        "a same-refresh store move must start a replacement reload")
            XCTAssertEqual(indexer.allSessions.first(where: { $0.id == sessionID })?.filePath,
                           replacementDatabase.path)
        }
    }

    @MainActor
    func testOpenClawDelayedReloadRegistrationCannotReplaceNewerStorageRequest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-DelayedReloadRegistration-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        let replacementDatabase = root.appendingPathComponent(
            "relocated/main/openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: replacementDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: replacementDatabase)
        try executeSQLite("""
        UPDATE transcript_events
        SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"delayed replacement"}]}}'
        WHERE session_id = 'sqlite-demo' AND seq = 2;
        """, at: replacementDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == firstDatabase.path })?.id)

            let firstSnapshotCaptured = expectation(description: "old reload captures A before registration")
            let releaseFirstRegistration = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            indexer.setReloadBeforeRegistrationHookForTesting {
                hookLock.lock()
                hookCalls += 1
                let isFirst = hookCalls == 1
                hookLock.unlock()
                if isFirst {
                    firstSnapshotCaptured.fulfill()
                    if releaseFirstRegistration.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("first registration gate timed out before explicit release")
                    }
                }
            }
            defer {
                releaseFirstRegistration.signal()
                indexer.setReloadBeforeRegistrationHookForTesting(nil)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                indexer.reloadSession(id: sessionID,
                                      force: true,
                                      reason: .focusedSessionMonitor)
            }
            wait(for: [firstSnapshotCaptured], timeout: 3)

            // B is published and registered while the delayed A caller is
            // paused between its snapshot and in-flight registration. The A
            // caller must retry/coalesce, never overwrite B's request.
            indexer.replaceSessionStoragePathForTesting(
                id: sessionID,
                path: replacementDatabase.path)
            let updated = expectation(description: "newer B request publishes")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return false
                    }
                    return session.filePath == replacementDatabase.path
                        && session.events.contains { $0.text == "delayed replacement" }
                }
                .prefix(1)
                .sink { _ in updated.fulfill() }
            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .selection)
            releaseFirstRegistration.signal()

            wait(for: [updated], timeout: 5)
            cancellable?.cancel()
            hookLock.lock()
            let registrationCount = hookCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(registrationCount, 3,
                                        "the delayed A caller must observe B and retry instead of replacing it")
            XCTAssertEqual(indexer.allSessions.first(where: { $0.id == sessionID })?.filePath,
                           replacementDatabase.path)
        }
    }

    @MainActor
    func testOpenClawReloadRequestsWithDifferentStrengthDoNotCoalesce() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadStrength-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == database.path })?.id)

            let firstReloadStarted = expectation(description: "weaker reload reaches parse gate")
            let secondReloadStarted = expectation(description: "stronger reload reaches parse gate")
            let releaseFirstReload = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                hookCalls += 1
                let call = hookCalls
                hookLock.unlock()
                if call == 1 {
                    firstReloadStarted.fulfill()
                    if releaseFirstReload.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("first reload gate timed out before explicit release")
                    }
                } else if call == 2 {
                    secondReloadStarted.fulfill()
                }
            }
            defer {
                releaseFirstReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .focusedSessionMonitor)
            wait(for: [firstReloadStarted], timeout: 3)

            // A manual refresh has stronger execution semantics than the
            // focused-session shortcut even when path, token, and revision
            // are identical. It must replace the weaker in-flight request.
            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .manualRefresh)
            releaseFirstReload.signal()

            wait(for: [secondReloadStarted], timeout: 5)
            hookLock.lock()
            let observedHookCalls = hookCalls
            hookLock.unlock()
            XCTAssertGreaterThanOrEqual(observedHookCalls, 2,
                                        "a stronger manual refresh must not coalesce into a focused-session reload")
        }
    }

    @MainActor
    func testOpenClawWeakerReloadDoesNotSupersedeManualRefresh() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ReloadStrengthInverse-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try executeSQLite("""
        UPDATE transcript_events
        SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"manual refresh wins"}]}}'
        WHERE session_id = 'sqlite-demo' AND seq = 2;
        """, at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == database.path })?.id)

            let manualReloadStarted = expectation(description: "manual reload reaches parse gate")
            let manualReloadPublished = expectation(description: "manual reload still publishes")
            let releaseManualReload = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var hookCalls = 0
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                hookCalls += 1
                hookLock.unlock()
                manualReloadStarted.fulfill()
                if releaseManualReload.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("manual reload gate timed out before explicit release")
                }
            }
            defer {
                releaseManualReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "manual refresh wins"
                    } == true
                }
                .prefix(1)
                .sink { _ in manualReloadPublished.fulfill() }

            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .manualRefresh)
            wait(for: [manualReloadStarted], timeout: 3)

            // A normal selection request is weaker and must leave the
            // already-running forced manual refresh as the latest generation.
            indexer.reloadSession(id: sessionID,
                                  force: false,
                                  reason: .selection)
            releaseManualReload.signal()

            wait(for: [manualReloadPublished], timeout: 5)
            cancellable?.cancel()
            hookLock.lock()
            let observedHookCalls = hookCalls
            hookLock.unlock()
            XCTAssertEqual(observedHookCalls, 1,
                           "a weaker selection reload must not supersede a forced manual refresh")
        }
    }

    @MainActor
    func testOpenClawReloadDoesNotResurrectOldSQLiteAlias() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-CanonicalAlias-\(UUID().uuidString)",
            isDirectory: true)
        let canonicalRoot = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-CanonicalTarget-\(UUID().uuidString)",
            isDirectory: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: canonicalRoot)
        }

        let canonicalDatabase = canonicalRoot.appendingPathComponent(
            "agent/openclaw-agent.sqlite")
        let aliasDatabase = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: canonicalDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: canonicalDatabase)
        try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: canonicalDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)
            XCTAssertEqual(indexer.allSessions.first?.filePath, canonicalDatabase.path,
                           "discovery should publish the canonical SQLite target")

            // Start an old reload through the lexical symlink alias. Then
            // model discovery publishing the canonical target while it parses.
            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"canonical alias reload"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: canonicalDatabase)
            indexer.replaceSessionStoragePathForTesting(id: sessionID,
                                                        path: aliasDatabase.path)

            let oldReloadStarted = expectation(description: "alias reload reaches parse gate")
            let releaseOldReload = DispatchSemaphore(value: 0)
            indexer.setReloadBeforeParseHookForTesting {
                oldReloadStarted.fulfill()
                if releaseOldReload.wait(timeout: .now() + 5) == .timedOut {
                    XCTFail("old reload alias gate timed out before explicit release")
                }
            }
            defer {
                releaseOldReload.signal()
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            let canonicalReloadPublished = expectation(description: "canonical path survives old reload")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    guard let session = sessions.first(where: { $0.id == sessionID }) else {
                        return false
                    }
                    return session.filePath == canonicalDatabase.path
                        && session.events.contains { $0.text == "canonical alias reload" }
                }
                .prefix(1)
                .sink { _ in canonicalReloadPublished.fulfill() }

            indexer.reloadSession(id: sessionID,
                                  force: true,
                                  reason: .focusedSessionMonitor)
            wait(for: [oldReloadStarted], timeout: 3)
            indexer.replaceSessionStoragePathForTesting(id: sessionID,
                                                        path: canonicalDatabase.path)
            releaseOldReload.signal()

            wait(for: [canonicalReloadPublished], timeout: 5)
            cancellable?.cancel()
            XCTAssertEqual(indexer.allSessions.first(where: { $0.id == sessionID })?.filePath,
                           canonicalDatabase.path,
                           "an old lexical alias must not be published over the canonical SQLite path")
        }
    }

    @MainActor
    func testOpenClawSearchUpdatePreservesCanonicalSQLitePath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-SearchCanonicalAlias-\(UUID().uuidString)",
            isDirectory: true)
        let canonicalRoot = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-SearchCanonicalTarget-\(UUID().uuidString)",
            isDirectory: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: canonicalRoot)
        }

        let canonicalDatabase = canonicalRoot.appendingPathComponent(
            "agent/openclaw-agent.sqlite")
        let aliasDatabase = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: canonicalDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: canonicalDatabase)
        try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: canonicalDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let sessionID = try XCTUnwrap(indexer.allSessions.first?.id)
            XCTAssertEqual(indexer.allSessions.first?.filePath, canonicalDatabase.path)

            try executeSQLite("""
            UPDATE transcript_events
            SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"search alias update"}]}}'
            WHERE session_id = 'sqlite-demo' AND seq = 2;
            """, at: canonicalDatabase)
            let parsedThroughAlias = try XCTUnwrap(
                OpenClawSqliteReader.loadFullSession(
                    databaseURL: aliasDatabase,
                    sessionID: sessionID))
            XCTAssertEqual(parsedThroughAlias.filePath, aliasDatabase.path)

            // SearchCoordinator publishes through updateSession after parsing.
            // Discovery has already won with the canonical target, so this
            // equivalent alias must update content without changing identity.
            let updated = expectation(description: "search update publishes")
            var updateCancellable: AnyCancellable?
            updateCancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == sessionID })?.events.contains {
                        $0.text == "search alias update"
                    } == true
                }
                .prefix(1)
                .sink { _ in updated.fulfill() }
            indexer.updateSession(parsedThroughAlias)
            wait(for: [updated], timeout: 5)
            updateCancellable?.cancel()
            let current = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.id == sessionID }))
            XCTAssertEqual(current.filePath, canonicalDatabase.path,
                           "search publication must retain the canonical SQLite path")
            XCTAssertTrue(current.events.contains { $0.text == "search alias update" })
        }
    }

    @MainActor
    func testOpenClawRetiredSessionRejectsLateSearchCachePublication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-RetiredSearchCache-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let retiredSession = try XCTUnwrap(indexer.allSessions.first)

            try fm.removeItem(at: database)
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            XCTAssertFalse(indexer.allSessions.contains { $0.id == retiredSession.id })

            // This simulates SearchCoordinator finishing the parse it started
            // before the authoritative refresh retired the row.
            indexer.updateSession(retiredSession)
            XCTAssertNil(indexer.searchTranscriptCache.getCached(retiredSession.id),
                         "a retired session must not reseed the transcript cache")
        }
    }

    @MainActor
    func testOpenClawPartialPublicationDoesNotInvalidateUnrelatedInFlightReload() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-PartialPublicationReload-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent(
            "agents/first/agent/openclaw-agent.sqlite")
        let secondDatabase = root.appendingPathComponent(
            "agents/second/agent/openclaw-agent.sqlite")
        let replacementFirstDatabase = root.appendingPathComponent(
            "relocated/first/openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: replacementFirstDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        try createOpenClawSQLiteFixture(at: replacementFirstDatabase)
        try executeSQLite("""
        UPDATE transcript_events
        SET event_json = '{"type":"message","id":"user-1","timestamp":"2026-04-16T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"newer second transcript"}]}}'
        WHERE session_id = 'sqlite-demo' AND seq = 2;
        """, at: secondDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            let firstID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == firstDatabase.path })?.id)
            let secondID = try XCTUnwrap(
                indexer.allSessions.first(where: { $0.filePath == secondDatabase.path })?.id)

            let oldSecondSnapshot = expectation(description: "old second reload pauses before registration")
            let releaseOldSecond = DispatchSemaphore(value: 0)
            let newSecondParse = expectation(description: "new second reload reaches parse")
            let releaseNewSecond = DispatchSemaphore(value: 0)
            let hookLock = NSLock()
            var registrationCalls = 0
            var parseCalls = 0
            indexer.setReloadBeforeRegistrationHookForTesting {
                hookLock.lock()
                registrationCalls += 1
                let isFirst = registrationCalls == 1
                hookLock.unlock()
                if isFirst {
                    oldSecondSnapshot.fulfill()
                    if releaseOldSecond.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("old second-session gate timed out before explicit release")
                    }
                }
            }
            indexer.setReloadBeforeParseHookForTesting {
                hookLock.lock()
                parseCalls += 1
                let isFirst = parseCalls == 1
                hookLock.unlock()
                if isFirst {
                    newSecondParse.fulfill()
                    if releaseNewSecond.wait(timeout: .now() + 5) == .timedOut {
                        XCTFail("new second-session gate timed out before explicit release")
                    }
                }
            }
            defer {
                releaseOldSecond.signal()
                releaseNewSecond.signal()
                indexer.setReloadBeforeRegistrationHookForTesting(nil)
                indexer.setReloadBeforeParseHookForTesting(nil)
            }

            // The old B caller has captured its path but has not registered.
            DispatchQueue.global(qos: .userInitiated).async {
                indexer.reloadSession(id: secondID,
                                      force: true,
                                      reason: .focusedSessionMonitor)
            }
            wait(for: [oldSecondSnapshot], timeout: 3)

            // Register a newer B request at the original B storage version.
            // It is held in parsing so an unrelated A publication overlaps it.
            indexer.reloadSession(id: secondID,
                                  force: true,
                                  reason: .focusedSessionMonitor)
            wait(for: [newSecondParse], timeout: 3)

            // This is intentionally a singleton publication. It must update A
            // without pruning B's path/version or invalidating B's request.
            indexer.replaceSessionStoragePathForTesting(
                id: firstID,
                path: replacementFirstDatabase.path)
            let updated = expectation(description: "newer B request publishes")
            var cancellable: AnyCancellable?
            cancellable = indexer.$allSessions
                .filter { sessions in
                    sessions.first(where: { $0.id == secondID })?.events.contains {
                        $0.text == "newer second transcript"
                    } == true
                }
                .prefix(1)
                .sink { _ in updated.fulfill() }
            releaseOldSecond.signal()
            releaseNewSecond.signal()
            wait(for: [updated], timeout: 5)
            cancellable?.cancel()

            hookLock.lock()
            let observedParseCalls = parseCalls
            hookLock.unlock()
            XCTAssertEqual(observedParseCalls, 1,
                           "A's singleton publication must not cause the older B caller to replace the newer B reload")
            XCTAssertEqual(indexer.allSessions.first(where: { $0.id == secondID })?.events.first {
                $0.text == "newer second transcript"
            }?.text, "newer second transcript")
        }
    }

    @MainActor
    func testOpenClawIndexerReconcilesReadableDatabaseWhenSiblingIsUnreadable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-IndexerPartialSnapshot-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let readableDatabase = root.appendingPathComponent(
            "agents/readable/agent/openclaw-agent.sqlite")
        let unreadableDatabase = root.appendingPathComponent(
            "agents/unreadable/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: readableDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: unreadableDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: readableDatabase)
        try createOpenClawSQLiteFixture(at: unreadableDatabase)

        try withIsolatedIndexerStore {
            let indexer = OpenClawSessionIndexer(
                discovery: OpenClawSessionDiscovery(customRoot: root.path))
            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            var fixtureSessions = indexer.allSessions.filter { $0.filePath.hasPrefix(root.path) }
            XCTAssertEqual(
                Set(fixtureSessions.map(\.id)),
                Set(["openclaw:readable:sqlite-demo", "openclaw:unreadable:sqlite-demo"]))

            try executeSQLite(
                "DELETE FROM session_windows WHERE session_id = 'sqlite-demo';",
                at: readableDatabase)
            try Data("not a SQLite database".utf8).write(to: unreadableDatabase, options: .atomic)

            indexer.refresh(mode: .fullReconcile)
            waitForOpenClawIndexerQuiescence(indexer)
            fixtureSessions = indexer.allSessions.filter { $0.filePath.hasPrefix(root.path) }

            XCTAssertEqual(fixtureSessions.map(\.id), ["openclaw:unreadable:sqlite-demo"],
                           "a readable sibling must reconcile independently while an unreadable store remains hydrated")
            XCTAssertEqual(fixtureSessions.first?.filePath, unreadableDatabase.path)
        }
    }

    func testOpenClawDiscoveryCanonicalizesSymlinkAliasesAndRejectsConflictingOwners() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-SymlinkAlias-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let agentDirectory = root.appendingPathComponent("agents/main/agent", isDirectory: true)
        let database = agentDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let aliasesDirectory = root.appendingPathComponent("aliases", isDirectory: true)
        let aliasDirectory = aliasesDirectory.appendingPathComponent("alias", isDirectory: true)
        try fm.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasesDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try fm.createSymbolicLink(at: aliasDirectory, withDestinationURL: agentDirectory)

        try writeText("""
        {
          agents: {
            entries: {
              alias: { agentDir: '\(aliasDirectory.path)' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let aliasResult = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(aliasResult.databases.map(canonicalPath), [canonicalPath(database)])
        XCTAssertEqual(aliasResult.agentID(forDatabaseURL: database), "alias")
        XCTAssertTrue(aliasResult.isAuthoritative)

        try writeText("""
        {
          agents: {
            entries: {
              alias: { agentDir: '\(aliasDirectory.path)' },
              conflict: { agentDir: '\(agentDirectory.path)' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))
        let conflictResult = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(conflictResult.databases.map(canonicalPath), [canonicalPath(database)])
        XCTAssertFalse(conflictResult.isAuthoritative)
        XCTAssertTrue(conflictResult.isOwnershipAmbiguous(forDatabaseURL: database))
        XCTAssertNil(conflictResult.agentID(forDatabaseURL: database),
                     "ambiguous stores must not mint a fresh owner identity")
    }

    func testOpenClawDiscoveryRejectsConflictingInferredSymlinkOwners() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-InferredSymlinkConflict-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent(
            "agents/first/agent/openclaw-agent.sqlite")
        let secondAgentDirectory = root.appendingPathComponent("agents/second/agent")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try fm.createDirectory(at: secondAgentDirectory.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: secondAgentDirectory,
                                  withDestinationURL: firstDatabase.deletingLastPathComponent())

        let result = OpenClawSessionDiscovery(customRoot: root.path)
            .discoverSessionDatabaseResult()
        XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(firstDatabase)])
        XCTAssertFalse(result.isAuthoritative)
        XCTAssertTrue(result.isOwnershipAmbiguous(forDatabaseURL: firstDatabase))
        XCTAssertNil(result.agentID(forDatabaseURL: firstDatabase),
                     "conflicting inferred aliases must not choose an enumeration-order owner")
    }

    func testOpenClawDiscoveryTreatsBrokenAgentDirectorySymlinkAsIndeterminate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-BrokenAgentSymlink-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let agentDirectory = root.appendingPathComponent("agents/main/agent", isDirectory: true)
        let missingTarget = root.appendingPathComponent("moved-agent", isDirectory: true)
        try fm.createDirectory(at: agentDirectory.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: agentDirectory, withDestinationURL: missingTarget)

        let result = OpenClawSessionDiscovery(customRoot: root.path)
            .discoverSessionDatabaseResult()
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative,
                       "a broken agent-directory alias must preserve the prior indexed snapshot")
    }

    func testOpenClawDiscoveryTreatsAgentSymlinkReplacementDuringProbeAsIndeterminate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-AgentSymlinkTransition-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let realAgentDirectory = root.appendingPathComponent("real-agent", isDirectory: true)
        let database = realAgentDirectory.appendingPathComponent(
            "agent/openclaw-agent.sqlite")
        let aliasDirectory = root.appendingPathComponent("agents/main", isDirectory: true)
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try fm.createSymbolicLink(at: aliasDirectory, withDestinationURL: realAgentDirectory)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        discovery.setBeforeDatabaseProbeHookForTesting {
            try? fm.removeItem(at: aliasDirectory)
        }
        defer { discovery.setBeforeDatabaseProbeHookForTesting(nil) }

        let result = discovery.discoverSessionDatabaseResult()
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative,
                       "an agent alias that disappears during probing must not authorize SQLite retirement")
    }

    func testOpenClawDiscoveryTreatsDatabaseDirectorySymlinkReplacementAsIndeterminate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-DatabaseSymlinkTransition-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDirectory = root.appendingPathComponent("first-agent", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second-agent", isDirectory: true)
        let agentDirectory = root.appendingPathComponent("agents/main", isDirectory: true)
        let databaseAlias = agentDirectory.appendingPathComponent("agent", isDirectory: true)
        let firstDatabase = firstDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let secondDatabase = secondDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        try fm.createSymbolicLink(at: databaseAlias, withDestinationURL: firstDirectory)

        let discovery = OpenClawSessionDiscovery(customRoot: root.path)
        discovery.setBeforeDatabaseProbeHookForTesting {
            try? fm.removeItem(at: databaseAlias)
            try? fm.createSymbolicLink(at: databaseAlias, withDestinationURL: secondDirectory)
        }
        defer { discovery.setBeforeDatabaseProbeHookForTesting(nil) }

        let result = discovery.discoverSessionDatabaseResult()
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative,
                       "a database-directory alias retarget must not authorize SQLite retirement")
    }

    func testOpenClawDiscoveryHonorsOpenClawHome() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-Home-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw/agents/home-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryHonorsOpenClawProfile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-Profile-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw-research/agents/profile-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": "research",
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryTreatsDefaultProfileAsUnprofiled() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-DefaultProfile-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw/agents/default-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": "DEFAULT",
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryAcceptsMixedCaseNamedProfile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-MixedCaseProfile-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw-Research/agents/profile-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": "ReSeArCh",
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryDoesNotFallBackWhenOpenClawRootExistsWithoutAgents() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ExistingRoot-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let openClawRoot = home.appendingPathComponent(".openclaw", isDirectory: true)
        let legacyDatabase = home.appendingPathComponent(
            ".clawdbot/agents/legacy-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: openClawRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: legacyDatabase)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertTrue(result.databases.isEmpty)
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryUsesDefaultConfigWhenConfigPathIsBlank() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-BlankConfigPath-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let externalDirectory = home.appendingPathComponent("external-agent", isDirectory: true)
        let database = externalDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        let stateRoot = home.appendingPathComponent(".openclaw", isDirectory: true)
        try fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try writeText("""
        { agents: { entries: { worker: { agentDir: '\(externalDirectory.path)' } } } }
        """, to: stateRoot.appendingPathComponent("openclaw.json"))

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": "   "
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertEqual(result.agentID(forDatabaseURL: database), "worker")
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryTreatsMissingExplicitConfigPathAsNonAuthoritative() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-MissingExplicitConfig-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let inferredDatabase = root.appendingPathComponent(
            "agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: inferredDatabase.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: inferredDatabase)
        let missingConfig = root.appendingPathComponent("selected/openclaw.json")

        try withProcessEnvironment([
            "OPENCLAW_CONFIG_PATH": missingConfig.path
        ]) {
            let result = OpenClawSessionDiscovery(customRoot: root.path)
                .discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(inferredDatabase)])
            XCTAssertFalse(result.isAuthoritative,
                           "a selected config path that disappears must not retire the prior ownership map")
        }
    }

    func testOpenClawDiscoveryRejectsOwnerlessInferredDatabase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-OwnerlessDatabase-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent(
            "agents/!!!/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        let result = OpenClawSessionDiscovery(customRoot: root.path)
            .discoverSessionDatabaseResult()
        XCTAssertTrue(result.databases.isEmpty)
        XCTAssertFalse(result.isAuthoritative,
                       "an inferred store without a normalizable owner must not mint an identity")
        XCTAssertNil(result.agentID(forDatabaseURL: database))
    }

    func testOpenClawDiscoveryFallsBackFromNullHomeToHomeEnvironment() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-NullHome-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw/agents/null-home-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": "null",
            "HOME": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryFallsBackFromMissingHomeToUserProfile() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-UserProfile-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw/agents/user-profile-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": nil,
            "HOME": nil,
            "USERPROFILE": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryRejectsInvalidProfileWithoutTrustingDefaultNamespace() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-InvalidProfile-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".openclaw/agents/invalid-profile-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": "bad.profile",
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertFalse(result.isAuthoritative)
        }
    }

    func testOpenClawNamedProfileDoesNotFallBackToLegacyProfileNamespace() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-NoLegacyProfileFallback-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let legacyDatabase = home.appendingPathComponent(
            ".clawdbot-research/agents/legacy-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: legacyDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: legacyDatabase)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": "research",
            "OPENCLAW_STATE_DIR": nil,
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertTrue(result.databases.isEmpty)
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryResolvesTildeStateDirAgainstOpenClawHome() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-TildeHome-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let database = home.appendingPathComponent(
            ".state/agents/tilde-agent/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)

        try withProcessEnvironment([
            "OPENCLAW_HOME": home.path,
            "OPENCLAW_PROFILE": nil,
            "OPENCLAW_STATE_DIR": "~/.state",
            "OPENCLAW_CONFIG_PATH": nil
        ]) {
            let result = OpenClawSessionDiscovery().discoverSessionDatabaseResult()
            XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(database)])
            XCTAssertTrue(result.isAuthoritative)
        }
    }

    func testOpenClawDiscoveryUsesStateDotEnvBeforeConfigEnvVarsAndHonorsEscapes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-EnvironmentPrecedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let stateDirectory = root.appendingPathComponent("state-agent", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config-agent", isDirectory: true)
        let escapedDirectory = root.appendingPathComponent("escaped-agent", isDirectory: true)
        let stateDatabase = stateDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let configDatabase = configDirectory.appendingPathComponent("openclaw-agent.sqlite")
        let escapedDatabase = escapedDirectory.appendingPathComponent("openclaw-agent.sqlite")
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: stateDatabase)
        try createOpenClawSQLiteFixture(at: configDatabase)
        try createOpenClawSQLiteFixture(at: escapedDatabase)

        let variable = "AGENT_SESSIONS_OPENCLAW_PRECEDENCE_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(variable)
        defer { unsetenv(variable) }
        try writeText("\(variable)=\(stateDirectory.path)\n", to: root.appendingPathComponent(".env"))
        try writeText("""
        {
          env: { vars: { \(variable): '\(configDirectory.path)' } },
          agents: {
            entries: {
              state: { agentDir: '${\(variable)}' },
              fallback: { agentDir: '${MISSING_\(variable):-\(stateDirectory.path)}' },
              escaped: { agentDir: '$${\(variable)}' },
            },
          },
        }
        """, to: root.appendingPathComponent("openclaw.json"))

        let result = OpenClawSessionDiscovery(customRoot: root.path).discoverSessionDatabaseResult()
        XCTAssertEqual(result.databases.map(canonicalPath), [canonicalPath(stateDatabase)])
        // Both `state` and `fallback` resolve to the same physical store with
        // different explicit owners. Discovery must preserve the data but fail
        // closed instead of silently choosing one owner.
        XCTAssertFalse(result.isAuthoritative)
    }

    func testOpenClawReadableDatabaseReconcilesRemovedSessionMeta() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-RemovedIdentity-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try executeSQLite("""
        INSERT INTO session_windows
            (session_id, created_at, updated_at, started_at, ended_at, model, display_name)
        VALUES
            ('sqlite-removed', 1776370005000, 1776370006000, 1776370005000,
             1776370006000, 'removed-model', 'Removed session');
        """, at: database)

        let initialSessions = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        XCTAssertEqual(Set(initialSessions.map(\.id)), [
            "openclaw:main:sqlite-demo",
            "openclaw:main:sqlite-removed"
        ])

        let (indexDB, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        try await indexDB.begin()
        for session in initialSessions {
            try await indexDB.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: session))
        }
        try await indexDB.commit()

        try executeSQLite("DELETE FROM session_windows WHERE session_id = 'sqlite-removed';", at: database)
        let currentSessions = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        XCTAssertEqual(currentSessions.map(\.id), ["openclaw:main:sqlite-demo"])

        try await indexDB.begin()
        let retired = try await indexDB.deleteSessionsNotPresentAtPaths(
            source: SessionSource.openclaw.rawValue,
            currentSessionIDsByPath: [database.path: Set(currentSessions.map(\.id))])
        try await indexDB.commit()

        XCTAssertEqual(retired, ["openclaw:main:sqlite-removed"])
        let hydratedRows = try await indexDB.fetchSessionMeta(for: SessionSource.openclaw.rawValue)
        XCTAssertEqual(hydratedRows.map(\.sessionID), ["openclaw:main:sqlite-demo"])
    }

    func testOpenClawSqliteReaderListsAndScansSessionScopedTelemetry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-SQLite-(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: dbURL)

        let sessions = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL))
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.id, "openclaw:main:sqlite-demo")
        XCTAssertEqual(session.filePath, dbURL.path)
        XCTAssertEqual(session.model, "metadata-model")
        XCTAssertEqual(session.eventCount, 4)
        XCTAssertEqual(SessionInfoQuickFacts(session: session).currentModel.value, "metadata-model")

        let firstRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: session))
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: session))
        XCTAssertGreaterThan(scan.bytesScanned, 0)
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model, "metadata-model")
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertEqual(scan.result.telemetry.usageSummary?.displayTotalTokens, 2)
        XCTAssertNil(scan.result.telemetry.costEstimate)

        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: dbURL, sessionID: session.id))
        XCTAssertEqual(full.id, session.id)
        XCTAssertEqual(full.filePath, dbURL.path)
        XCTAssertEqual(full.model, "metadata-model")
        XCTAssertEqual(full.sourceStorageIdentity, canonicalPath(dbURL))
        let fullRevision = try XCTUnwrap(OpenClawSqliteReader.sessionRevision(for: full))
        XCTAssertNotNil(full.sourceStorageRevision)
        XCTAssertEqual(fullRevision, firstRevision,
                       "full-load provenance must come from the same logical snapshot")
        XCTAssertTrue(full.events.contains { $0.kind == .user && ($0.text ?? "").contains("SQLite fixture") })
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("fixture response") })

        try executeSQLite("UPDATE session_windows SET display_name = 'Renamed SQLite fixture' WHERE session_id = 'sqlite-demo';", at: dbURL)
        let renamed = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        let renamedRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: renamed))
        XCTAssertNotEqual(firstRevision, renamedRevision,
                          "display-name-only edits must invalidate the session revision")

        try executeSQLite("UPDATE session_windows SET display_name = '<null>' WHERE session_id = 'sqlite-demo';", at: dbURL)
        let sentinelName = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        let sentinelRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: sentinelName))
        XCTAssertNotEqual(renamedRevision, sentinelRevision,
                          "SQL NULL and a literal sentinel title must not collide in the revision")

        try executeSQLite("UPDATE session_windows SET updated_at = 1776370005000 WHERE session_id = 'sqlite-demo';", at: dbURL)
        let refreshed = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        let secondRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: refreshed))
        XCTAssertNotEqual(firstRevision, secondRevision)
    }

    func testOpenClawStorageRevisionTokenUsesCapturedPhysicalIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-CapturedStorageToken-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent("first/openclaw-agent.sqlite")
        let secondDatabase = root.appendingPathComponent("second/openclaw-agent.sqlite")
        let aliasDatabase = root.appendingPathComponent("alias/openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: firstDatabase)

        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: aliasDatabase)?.first)
        XCTAssertEqual(session.sourceStorageIdentity, canonicalPath(firstDatabase))
        let firstToken = try XCTUnwrap(OpenClawSqliteReader.storageRevisionToken(for: session))

        try fm.removeItem(at: aliasDatabase)
        try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: secondDatabase)

        let capturedToken = try XCTUnwrap(OpenClawSqliteReader.storageRevisionToken(for: session))
        let secondSession = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: secondDatabase)?.first)
        let secondToken = try XCTUnwrap(OpenClawSqliteReader.storageRevisionToken(for: secondSession))
        XCTAssertEqual(capturedToken, firstToken,
                       "a retargeted lexical alias must continue using the row's captured store identity")
        XCTAssertNotEqual(capturedToken, secondToken,
                          "a token from the retargeted store must not be paired with the old identity")
    }

    func testOpenClawCachedRevisionFailsClosedWhenStoreChangesAtBoundary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-CachedRevisionBoundary-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        let replacement = root.appendingPathComponent("replacement/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try createOpenClawSQLiteFixture(at: replacement)
        try executeSQLite(
            "UPDATE session_windows SET display_name = 'replacement cache database' WHERE session_id = 'sqlite-demo';",
            at: replacement)

        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database)?.first)
        let originalRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: session))

        var mutationError: Error?
        OpenClawSqliteReader.setCacheHitBeforeBoundaryProbeHookForTesting {
            do {
                try fm.removeItem(at: database)
                try fm.moveItem(at: replacement, to: database)
            } catch {
                mutationError = error
            }
        }
        defer { OpenClawSqliteReader.setCacheHitBeforeBoundaryProbeHookForTesting(nil) }

        XCTAssertNil(OpenClawSqliteReader.telemetryRevision(for: session),
                     "a cache hit must fail closed when the store changes before its boundary probe")
        XCTAssertNil(mutationError, "the cache-boundary database replacement must succeed")
        let replacementRevision = try XCTUnwrap(OpenClawSqliteReader.telemetryRevision(for: session))
        XCTAssertNotEqual(originalRevision, replacementRevision,
                          "the next read must establish a revision for the replacement database")
    }

    func testOpenClawListSessionsKeepsReadPathIdentityAcrossAliasRetarget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ListAliasRetarget-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let firstDatabase = root.appendingPathComponent("first/openclaw-agent.sqlite")
        let secondDatabase = root.appendingPathComponent("second/openclaw-agent.sqlite")
        let aliasDatabase = root.appendingPathComponent("alias/openclaw-agent.sqlite")
        try fm.createDirectory(at: firstDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: secondDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: aliasDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: firstDatabase)
        try createOpenClawSQLiteFixture(at: secondDatabase)
        try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: firstDatabase)

        let aliasMutationLock = NSLock()
        var aliasMutationError: Error?
        OpenClawSqliteReader.setListSessionsBeforeMaterializationHookForTesting {
            do {
                try fm.removeItem(at: aliasDatabase)
                try fm.createSymbolicLink(at: aliasDatabase, withDestinationURL: secondDatabase)
            } catch {
                aliasMutationLock.lock()
                aliasMutationError = error
                aliasMutationLock.unlock()
            }
        }
        defer { OpenClawSqliteReader.setListSessionsBeforeMaterializationHookForTesting(nil) }

        let session = try XCTUnwrap(
            OpenClawSqliteReader.listSessions(databaseURL: aliasDatabase, agentID: "alias")?.first)
        OpenClawSqliteReader.setListSessionsBeforeMaterializationHookForTesting(nil)
        aliasMutationLock.lock()
        let observedAliasMutationError = aliasMutationError
        aliasMutationLock.unlock()
        XCTAssertNil(observedAliasMutationError, "the alias retarget must succeed")
        XCTAssertEqual(canonicalPath(aliasDatabase), canonicalPath(secondDatabase),
                       "the lexical alias must point at the replacement database")
        XCTAssertEqual(session.filePath, aliasDatabase.path,
                       "the lexical path remains the published display path")
        XCTAssertEqual(session.sourceStorageIdentity, canonicalPath(firstDatabase),
                       "row metadata must describe the database that was actually read")
    }

    func testOpenClawListSessionsFailsClosedWhenDatabaseIsReplacedDuringRead() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "AgentSessions-OpenClaw-ListReplacement-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let database = root.appendingPathComponent("current/openclaw-agent.sqlite")
        let replacement = root.appendingPathComponent("replacement/openclaw-agent.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: database)
        try createOpenClawSQLiteFixture(at: replacement)
        try executeSQLite(
            "UPDATE session_windows SET display_name = 'replacement database' WHERE session_id = 'sqlite-demo';",
            at: replacement)

        let replacementLock = NSLock()
        var replacementError: Error?
        OpenClawSqliteReader.setListSessionsBeforeMaterializationHookForTesting {
            do {
                try fm.removeItem(at: database)
                try fm.moveItem(at: replacement, to: database)
            } catch {
                replacementLock.lock()
                replacementError = error
                replacementLock.unlock()
            }
        }

        let result = OpenClawSqliteReader.listSessionsWithStorageIdentity(databaseURL: database)
        OpenClawSqliteReader.setListSessionsBeforeMaterializationHookForTesting(nil)
        replacementLock.lock()
        let observedReplacementError = replacementError
        replacementLock.unlock()
        XCTAssertNil(observedReplacementError, "the replacement database must be installed")
        XCTAssertNil(
            result,
            "rows read from the unlinked database must not be paired with the replacement path")

        let replacementSession = try XCTUnwrap(
            OpenClawSqliteReader.listSessions(databaseURL: database)?.first)
        XCTAssertEqual(replacementSession.lightweightTitle, "replacement database")
    }

    func testOpenClawSqliteReaderFailsClosedForCompressedEvents() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Compressed-(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: dbURL, compressed: true)

        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: session))
        XCTAssertGreaterThan(scan.bytesScanned, 0)
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model, "metadata-model")
        XCTAssertTrue(scan.result.telemetry.usageSummary?.unavailableReason?.contains("compressed") == true)
        XCTAssertTrue(scan.result.telemetry.usageEvents.isEmpty)
    }

    func testOpenClawSqliteReaderAcceptsNullableSessionMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-NullableMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: dbURL)
        try executeSQLite("UPDATE session_windows SET model = NULL, display_name = NULL WHERE session_id = 'sqlite-demo';", at: dbURL)

        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        XCTAssertNil(session.model)
        XCTAssertNil(session.lightweightTitle)
        XCTAssertEqual(session.eventCount, 4)
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: session))
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model, "record-model")
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.modelProvenance, .providerChangeRecord)

        let staleSession = Session(
            id: session.id,
            source: session.source,
            startTime: session.startTime,
            endTime: session.endTime,
            model: "stale-model",
            filePath: session.filePath,
            fileSizeBytes: session.fileSizeBytes,
            eventCount: session.eventCount,
            events: session.events,
            cwd: session.cwd,
            repoName: session.repoName,
            lightweightTitle: session.lightweightTitle,
            lightweightCommands: session.lightweightCommands)
        let staleScan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: staleSession))
        XCTAssertEqual(staleScan.result.telemetry.currentConfiguration?.model, "record-model")
        XCTAssertEqual(staleScan.result.telemetry.currentConfiguration?.modelProvenance, .providerChangeRecord)
    }

    func testOpenClawSqliteReaderFailsClosedForColdStoredTranscript() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-ColdStorage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE session_transcript_cold_archives (
            session_id TEXT PRIMARY KEY,
            generation TEXT NOT NULL,
            archive_name TEXT NOT NULL,
            archive_sha256 TEXT NOT NULL,
            event_count INTEGER NOT NULL,
            raw_bytes INTEGER NOT NULL,
            archive_bytes INTEGER NOT NULL,
            last_seq INTEGER NOT NULL,
            archived_at INTEGER NOT NULL,
            storage TEXT NOT NULL,
            archive_blob BLOB
        );
        INSERT INTO session_transcript_cold_archives
            (session_id, generation, archive_name, archive_sha256, event_count, raw_bytes,
             archive_bytes, last_seq, archived_at, storage, archive_blob)
        VALUES ('sqlite-demo', 'generation-1', 'sqlite-demo.cold',
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                4, 1000, 600, 4, 1776370005000, 'sqlite', X'789c01');
        DELETE FROM transcript_events WHERE session_id = 'sqlite-demo';
        """, at: dbURL)

        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        XCTAssertEqual(session.eventCount, 4, "cold metadata must not be presented as an empty transcript")
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: session))
        XCTAssertTrue(scan.result.telemetry.usageSummary?.unavailableReason?.contains("cold storage") == true)
        XCTAssertNil(OpenClawSqliteReader.loadFullSession(databaseURL: dbURL, sessionID: session.id))
        XCTAssertNotNil(OpenClawSqliteReader.telemetryRevision(for: session))
    }

    func testOpenClawSqliteSessionRevisionSeesWALPayloadChanges() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-WALRevision-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try fm.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createOpenClawSQLiteFixture(at: dbURL)
        let session = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: dbURL)?.first)
        let firstRevision = try XCTUnwrap(OpenClawSqliteReader.sessionRevision(for: session))

        try executeSQLite("""
        PRAGMA journal_mode = WAL;
        PRAGMA wal_autocheckpoint = 0;
        UPDATE transcript_events
        SET event_json = '{"type":"message","id":"assistant-1","message":{"role":"assistant","model":"record-model","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"content":[{"type":"text","text":"WAL revision"}]}}'
        WHERE session_id = 'sqlite-demo' AND seq = 3;
        """, at: dbURL)

        let secondRevision = try XCTUnwrap(OpenClawSqliteReader.sessionRevision(for: session))
        XCTAssertNotEqual(firstRevision, secondRevision)
    }

    func testOpenClawTelemetryReadsConfigurationAndUsageWithoutPricing() {
        let lines = [
            #"{"type":"session","version":3,"id":"openclaw-test","timestamp":"2026-08-16T16:00:00.000Z","cwd":"/tmp"}"#,
            #"{"type":"message","id":"assistant-0","timestamp":"2026-08-16T16:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","thinkingLevel":"high","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2},"content":[]}}"#,
            #"{"type":"model_change","modelId":"claude-sonnet-4-5","timestamp":"2026-08-16T16:00:01.000Z"}"#,
            #"{"type":"thinking_level_change","thinkingLevel":"high","timestamp":"2026-08-16T16:00:02.000Z"}"#,
            #"{"type":"message","id":"assistant-1","timestamp":1786896003000,"message":{"role":"assistant","model":"claude-sonnet-4-5","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":4,"totalTokens":154},"content":[]}}"#
        ]

        let telemetry = OpenClawTelemetryProvider.accumulate(lines: lines)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "claude-sonnet-4-5")
        XCTAssertEqual(telemetry.initialConfiguration?.reasoningEffort, "high")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "claude-sonnet-4-5")
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "high")
        XCTAssertEqual(telemetry.configurationChanges, [])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 156)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 156)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["openclaw.message.usage"])
        XCTAssertNil(telemetry.costEstimate)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.last?.contextInputTokens, 134)
    }

    func testOpenClawTelemetryRecordsSameModelSwitchAndDoesNotDoubleCountDuplicate() {
        let lines = [
            #"{"type":"message","id":"assistant-1","timestamp":"2026-08-16T16:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15}}}"#,
            #"{"type":"model_change","modelId":"model-b","timestamp":"2026-08-16T16:00:01.000Z"}"#,
            #"{"type":"message","id":"assistant-2","timestamp":"2026-08-16T16:00:02.000Z","message":{"role":"assistant","model":"model-b","usage":{"input":20,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":25}}}"#,
            #"{"type":"model_change","modelId":"model-a","timestamp":"2026-08-16T16:00:03.000Z"}"#,
            #"{"type":"message","id":"assistant-3","timestamp":"2026-08-16T16:00:04.000Z","message":{"id":"nested-a","role":"assistant","model":"model-a","usage":{"input":30,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":35}}}"#,
            #"{"type":"message","id":"assistant-3","timestamp":"2026-08-16T16:00:04.000Z","message":{"id":"nested-b","role":"assistant","model":"model-a","usage":{"input":30,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":35}}}"#
        ]

        let telemetry = OpenClawTelemetryProvider.accumulate(lines: lines)
        XCTAssertEqual(telemetry.configurationChanges.count, 2)
        XCTAssertEqual(telemetry.configurationChanges[0].field, .model)
        XCTAssertEqual(telemetry.configurationChanges[0].oldValue, "model-a")
        XCTAssertEqual(telemetry.configurationChanges[0].newValue, "model-b")
        XCTAssertEqual(telemetry.configurationChanges[1].field, .model)
        XCTAssertEqual(telemetry.configurationChanges[1].oldValue, "model-b")
        XCTAssertEqual(telemetry.configurationChanges[1].newValue, "model-a")
        XCTAssertEqual(telemetry.currentConfiguration?.model, "model-a")
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 75)
        XCTAssertEqual(telemetry.usageEvents.count, 3)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
    }

    func testOpenClawTelemetryFailsClosedForInconsistentOrConflictingUsage() {
        let inconsistent = [
            #"{"type":"message","id":"assistant-1","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":99}}}"#
        ]
        let inconsistentTelemetry = OpenClawTelemetryProvider.accumulate(lines: inconsistent)
        XCTAssertNotNil(inconsistentTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(inconsistentTelemetry.usageEvents.isEmpty)

        let conflicting = [
            #"{"type":"message","id":"assistant-1","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15}}}"#,
            #"{"type":"message","id":"assistant-1","message":{"role":"assistant","model":"model-b","usage":{"input":11,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":16}}}"#
        ]
        let conflictingTelemetry = OpenClawTelemetryProvider.accumulate(lines: conflicting)
        XCTAssertNotNil(conflictingTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(conflictingTelemetry.usageEvents.isEmpty)
        XCTAssertEqual(conflictingTelemetry.currentConfiguration?.model, "model-a")
        XCTAssertEqual(conflictingTelemetry.configurationChanges, [])
    }

    func testOpenClawTelemetryPreservesOneHourCacheWrites() {
        let lines = [
            #"{"type":"message","id":"assistant-cache","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":10,"cacheWrite1h":4,"totalTokens":27}}}"#
        ]

        let telemetry = OpenClawTelemetryProvider.accumulate(lines: lines)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 27)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheWrite5mTokens, 6)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheWrite1hTokens, 4)
        XCTAssertEqual(telemetry.usageSlices.first?.cacheWrite5mTokens, 6)
        XCTAssertEqual(telemetry.usageSlices.first?.cacheWrite1hTokens, 4)
    }

    func testOpenClawTelemetryUsesExplicitContextUsageWhenPresent() {
        let available = [
            #"{"type":"message","id":"assistant-context","message":{"role":"assistant","model":"model-a","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":4,"totalTokens":154,"contextUsage":{"state":"available","promptTokens":40,"totalTokens":154}}}}"#
        ]
        let availableTelemetry = OpenClawTelemetryProvider.accumulate(lines: available)
        XCTAssertEqual(availableTelemetry.usageEvents.first?.contextInputTokens, 40)

        let unavailable = [
            #"{"type":"message","id":"assistant-context-unavailable","message":{"role":"assistant","model":"model-a","usage":{"input":100,"output":20,"cacheRead":30,"cacheWrite":4,"totalTokens":154,"contextUsage":{"state":"unavailable"}}}}"#
        ]
        let unavailableTelemetry = OpenClawTelemetryProvider.accumulate(lines: unavailable)
        XCTAssertNil(unavailableTelemetry.usageEvents.first?.contextInputTokens)

        let conflicting = [
            #"{"type":"message","id":"assistant-context-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"contextUsage":{"state":"available","promptTokens":10,"totalTokens":15}}}}"#,
            #"{"type":"message","id":"assistant-context-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"contextUsage":{"state":"available","promptTokens":11,"totalTokens":15}}}}"#
        ]
        let conflictingTelemetry = OpenClawTelemetryProvider.accumulate(lines: conflicting)
        XCTAssertNotNil(conflictingTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(conflictingTelemetry.usageEvents.isEmpty)

        let malformed = [
            #"{"type":"message","id":"assistant-context-malformed","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"contextUsage":{"state":"available","promptTokens":20,"totalTokens":15}}}}"#
        ]
        let malformedTelemetry = OpenClawTelemetryProvider.accumulate(lines: malformed)
        XCTAssertNotNil(malformedTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(malformedTelemetry.usageEvents.isEmpty)
    }

    func testOpenClawTelemetryUsesServingResponseModelAndHonestCacheState() {
        let routed = [
            #"{"type":"message","id":"assistant-routed","message":{"role":"assistant","model":"router/auto","responseModel":"provider/served-model","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cacheTelemetry":{"state":"available"}}}}"#
        ]
        let routedTelemetry = OpenClawTelemetryProvider.accumulate(lines: routed)
        XCTAssertEqual(routedTelemetry.currentConfiguration?.model, "router/auto")
        XCTAssertEqual(routedTelemetry.usageEvents.first?.model, "provider/served-model")
        XCTAssertEqual(routedTelemetry.usageSlices.first?.model, "provider/served-model")

        let unavailableCache = [
            #"{"type":"message","id":"assistant-cache-unavailable","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cacheTelemetry":{"state":"unavailable"}}}}"#
        ]
        let unavailableTelemetry = OpenClawTelemetryProvider.accumulate(lines: unavailableCache)
        XCTAssertNotNil(unavailableTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(unavailableTelemetry.usageEvents.isEmpty)

        let malformedCache = [
            #"{"type":"message","id":"assistant-cache-malformed","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cacheTelemetry":{"state":"unknown"}}}}"#
        ]
        let malformedTelemetry = OpenClawTelemetryProvider.accumulate(lines: malformedCache)
        XCTAssertNotNil(malformedTelemetry.usageSummary?.unavailableReason)

        let conflictingCacheProvenance = [
            #"{"type":"message","id":"assistant-cache-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#,
            #"{"type":"message","id":"assistant-cache-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cacheTelemetry":{"state":"available"}}}}"#
        ]
        let conflictingTelemetry = OpenClawTelemetryProvider.accumulate(lines: conflictingCacheProvenance)
        XCTAssertNotNil(conflictingTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(conflictingTelemetry.usageEvents.isEmpty)

        let requestedModelConflict = [
            #"{"type":"message","id":"assistant-requested-model-conflict","message":{"role":"assistant","model":"router/auto-a","responseModel":"provider/served-model","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#,
            #"{"type":"message","id":"assistant-requested-model-conflict","message":{"role":"assistant","model":"router/auto-b","responseModel":"provider/served-model","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#
        ]
        let requestedModelConflictTelemetry = OpenClawTelemetryProvider.accumulate(lines: requestedModelConflict)
        XCTAssertNotNil(requestedModelConflictTelemetry.usageSummary?.unavailableReason)

        let contextTotalConflict = [
            #"{"type":"message","id":"assistant-context-total-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"contextUsage":{"state":"available","promptTokens":5,"totalTokens":15}}}}"#,
            #"{"type":"message","id":"assistant-context-total-conflict","message":{"role":"assistant","model":"model-a","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"contextUsage":{"state":"available","promptTokens":5,"totalTokens":16}}}}"#
        ]
        let contextTotalConflictTelemetry = OpenClawTelemetryProvider.accumulate(lines: contextTotalConflict)
        XCTAssertNotNil(contextTotalConflictTelemetry.usageSummary?.unavailableReason)
    }

    func testOpenClawTelemetryRejectsMalformedUsageBooleansAndOverflow() {
        let mixed = [
            #"{"type":"message","id":"assistant-valid","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#,
            #"{"type":"message","id":"assistant-malformed","message":{"role":"assistant","model":"model-a","usage":true}}"#,
            #"{"type":"message","id":"assistant-after-failure","message":{"role":"assistant","model":"model-c","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#
        ]
        let malformedTelemetry = OpenClawTelemetryProvider.accumulate(lines: mixed)
        XCTAssertNotNil(malformedTelemetry.usageSummary?.unavailableReason)
        XCTAssertNil(malformedTelemetry.usageSummary?.displayTotalTokens)
        XCTAssertTrue(malformedTelemetry.usageSlices.isEmpty)
        XCTAssertTrue(malformedTelemetry.usageEvents.isEmpty)
        XCTAssertEqual(malformedTelemetry.currentConfiguration?.model, "model-c")

        for rawValue in ["true", "false"] {
            let booleanLine = #"{"type":"message","id":"assistant-boolean","message":{"role":"assistant","model":"model-a","usage":{"input":"VALUE","output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":1}}}"#
                .replacingOccurrences(of: "VALUE", with: rawValue)
            let booleanTelemetry = OpenClawTelemetryProvider.accumulate(lines: [booleanLine])
            XCTAssertNotNil(booleanTelemetry.usageSummary?.unavailableReason, rawValue)
            XCTAssertTrue(booleanTelemetry.usageEvents.isEmpty, rawValue)
        }

        let overflow = [
            #"{"type":"message","id":"assistant-overflow","message":{"role":"assistant","model":"model-a","usage":{"input":9223372036854775807,"output":1,"cacheRead":0,"cacheWrite":0}}}"#
        ]
        let overflowTelemetry = OpenClawTelemetryProvider.accumulate(lines: overflow)
        XCTAssertNotNil(overflowTelemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(overflowTelemetry.usageSlices.isEmpty)
        XCTAssertTrue(overflowTelemetry.usageEvents.isEmpty)
    }

    func testOpenClawTelemetryKeepsPostFailureDuplicateIdentityCanonical() {
        let lines = [
            #"{"type":"message","id":"bad","timestamp":"2026-08-16T16:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":[]}}"#,
            #"{"type":"message","id":"same","timestamp":"2026-08-16T16:00:01.000Z","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#,
            #"{"type":"message","id":"same","timestamp":"2026-08-16T16:00:02.000Z","message":{"role":"assistant","model":"model-b","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#
        ]

        let telemetry = OpenClawTelemetryProvider.accumulate(lines: lines)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains("conflicting raw usage evidence") == true)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "model-a")
        XCTAssertEqual(telemetry.currentConfiguration?.model, "model-a")
        XCTAssertTrue(telemetry.configurationChanges.isEmpty)
    }

    func testOpenClawTelemetryCanonicalizesIdentityBeforeSemanticValidation() {
        let lines = [
            #"{"type":"message","id":"same","timestamp":"2026-08-16T16:00:00.000Z","message":{"role":"assistant","model":"model-a","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":99}}}"#,
            #"{"type":"message","id":"same","timestamp":"2026-08-16T16:00:01.000Z","message":{"role":"assistant","model":"model-c","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2}}}"#
        ]

        let telemetry = OpenClawTelemetryProvider.accumulate(lines: lines)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains("conflicting raw usage evidence") == true)
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertNil(telemetry.currentConfiguration)
        XCTAssertTrue(telemetry.configurationChanges.isEmpty)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testClaudeDesktopMetadataPrefersWorktreePathForProjectDisplay() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-ClaudeDesktopWorktree-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let localDir = root
            .appendingPathComponent("local_abc", isDirectory: true)
            .appendingPathComponent(".claude/projects/-Users-test-Repository-Codex-History", isDirectory: true)
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)

        let transcript = localDir.appendingPathComponent("11111111-1111-4111-8111-111111111111.jsonl")
        try writeText(
            #"{"type":"user","sessionId":"local_abc","cwd":"/sessions/demo","message":{"role":"user","content":"hello"},"timestamp":"2026-05-12T18:00:00.000Z"}"# + "\n",
            to: transcript
        )
        let metadata = root.appendingPathComponent("local_abc.json")
        try writeText(
            #"{"sessionId":"local_abc","cliSessionId":"11111111-1111-4111-8111-111111111111","cwd":"/sessions/demo","originCwd":"/Users/test/Repository/Codex-History","worktreePath":"/Users/test/Repository/Codex-History/.claude/worktrees/agitated-tu","worktreeName":"agitated-tu","createdAt":1770000000000,"lastActivityAt":1770000100000,"model":"claude-sonnet-test","title":"Desktop metadata title","isArchived":false}"#,
            to: metadata
        )

        let session = ClaudeSessionParser.parseFileFull(at: transcript)

        XCTAssertEqual(session?.cwd, "/Users/test/Repository/Codex-History/.claude/worktrees/agitated-tu")
        XCTAssertEqual(session?.repoName, "Codex-History")
        XCTAssertEqual(session?.projectWorktreeDisplayName, "agitated-tu")
    }

    func testClaudeTitleSkipsLocalCommandCaveatAndUsesTrailingPrompt() {
        let text = """
        Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.
        <command-name>/clear</command-name>
                    <command-message>clear</command-message>
                    <command-args></command-args>
        <local-command-stdout></local-command-stdout>
        read from docs/LettaCode - Dec18.md how to improve  Brush Cursor needs refinement
        """
        let e = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: text,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 1,
                        events: [e])
        XCTAssertEqual(s.title, "read from docs/LettaCode - Dec18.md how to improve Brush Cursor needs refinement")
    }

    func testClaudeTitleSkipsPureLocalCommandCaveatAndUsesNextPrompt() {
        let caveat = """
        Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.
        <command-name>/model</command-name>
                    <command-message>model</command-message>
                    <command-args></command-args>
        <local-command-stdout>Set model to [1mhaiku (claude-haiku-4-5-20251001)[22m</local-command-stdout>
        """
        let e1 = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: caveat,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let e2 = SessionEvent(
            id: "e2",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "Real prompt after model switch",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 2,
                        events: [e1, e2])
        XCTAssertEqual(s.title, "Real prompt after model switch")
    }

    func testClaudeTitleSkipsTranscriptOnlyUserFragments() {
        let e1 = SessionEvent(
            id: "e1",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "<local-command-stdout></local-command-stdout>",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let e2 = SessionEvent(
            id: "e2",
            timestamp: nil,
            kind: .user,
            role: "user",
            text: "Actual user prompt",
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: "{}"
        )
        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 2,
                        events: [e1, e2])
        XCTAssertEqual(s.title, "Actual user prompt")
    }

    func testClaudeLightweightTitleDoesNotExposeLocalCommandTranscript() {
        let defaults = UserDefaults.standard
        let key = "SkipAgentsPreamble"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: key) // default ON

        let s = Session(id: "sid",
                        source: .claude,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/claude.jsonl",
                        fileSizeBytes: nil,
                        eventCount: 0,
                        events: [],
                        cwd: nil,
                        repoName: nil,
                        lightweightTitle: "<local-command-stdout></local-command-stdout>",
                        lightweightCommands: nil)
        XCTAssertFalse(s.title.contains("<local-command-"))
    }

    func testOpenClawDeletedFileProducesStableID() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DeletedID-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-abc","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"# + "\n"

        let activeFile = sessionsDir.appendingPathComponent("my-session.jsonl")
        try (header + user).write(to: activeFile, atomically: true, encoding: .utf8)

        let deletedFile = sessionsDir.appendingPathComponent("my-session.jsonl.deleted.1704067200")
        try (header + user).write(to: deletedFile, atomically: true, encoding: .utf8)

        let activeSession = OpenClawSessionParser.parseFile(at: activeFile)
        let deletedSession = OpenClawSessionParser.parseFile(at: deletedFile)

        XCTAssertNotNil(activeSession)
        XCTAssertNotNil(deletedSession)
        XCTAssertEqual(activeSession!.id, deletedSession!.id)
        XCTAssertFalse(activeSession!.isDeleted)
        XCTAssertTrue(deletedSession!.isDeleted)
        XCTAssertNil(activeSession!.deletedAt)
        XCTAssertNotNil(deletedSession!.deletedAt)
        XCTAssertEqual(deletedSession!.deletedAt!.timeIntervalSince1970, 1704067200, accuracy: 1)
    }

    func testOpenClawDeletedFullParseMatchesLightweight() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DeletedFull-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-xyz","timestamp":"2026-02-01T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-02-01T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"test"}]}}"# + "\n"

        let deletedFile = sessionsDir.appendingPathComponent("test-session.jsonl.deleted.1706745600")
        try (header + user).write(to: deletedFile, atomically: true, encoding: .utf8)

        let light = OpenClawSessionParser.parseFile(at: deletedFile)
        let full = OpenClawSessionParser.parseFileFull(at: deletedFile)

        XCTAssertNotNil(light)
        XCTAssertNotNil(full)
        XCTAssertEqual(light!.id, full!.id)
        XCTAssertTrue(light!.isDeleted)
        XCTAssertTrue(full!.isDeleted)
    }

    func testOpenClawDeletedISO8601Timestamp() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DeletedISO-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-iso","timestamp":"2026-03-16T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-03-16T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"# + "\n"

        // Real OpenClaw format: colons replaced with dashes in time portion
        let deletedFile = sessionsDir.appendingPathComponent("my-session.jsonl.deleted.2026-03-16T21-20-30.062Z")
        try (header + user).write(to: deletedFile, atomically: true, encoding: .utf8)

        let session = OpenClawSessionParser.parseFile(at: deletedFile)
        XCTAssertNotNil(session)
        XCTAssertTrue(session!.isDeleted)
        XCTAssertNotNil(session!.deletedAt)

        // Verify the active counterpart produces the same ID
        let activeFile = sessionsDir.appendingPathComponent("my-session.jsonl")
        try (header + user).write(to: activeFile, atomically: true, encoding: .utf8)
        let activeSession = OpenClawSessionParser.parseFile(at: activeFile)
        XCTAssertEqual(session!.id, activeSession!.id)
    }

    func testOpenClawParserUsesTelegramPrefixAsProjectOrigin() throws {
        let fm = FileManager.default
        let titleStrategyKey = "OpenClawTitleStrategy"
        let previousTitleStrategy = UserDefaults.standard.string(forKey: titleStrategyKey)
        UserDefaults.standard.set(OpenClawSessionParser.TitleStrategy.originThenPrompt.rawValue, forKey: titleStrategyKey)
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Origin-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: tmp)
            if let previousTitleStrategy {
                UserDefaults.standard.set(previousTitleStrategy, forKey: titleStrategyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: titleStrategyKey)
            }
        }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-telegram","timestamp":"2026-04-24T00:00:00Z","cwd":"/Users/alexm/clawd"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"[Telegram A M (@jazzyalex) id:1108897 2026-04-24 10:00 PST] hi\n[message_id: 1]"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("telegram.jsonl")
        try (header + user).write(to: url, atomically: true, encoding: .utf8)

        let light = OpenClawSessionParser.parseFile(at: url)
        let full = OpenClawSessionParser.parseFileFull(at: url)

        XCTAssertEqual(light?.repoName, "telegram")
        XCTAssertEqual(light?.repoDisplay, "telegram")
        XCTAssertEqual(full?.repoName, "telegram")
        XCTAssertEqual(light?.listTitle, "A M (@jazzyalex) — hi")
        XCTAssertEqual(full?.lightweightTitle, light?.lightweightTitle)
        XCTAssertEqual(full?.listTitle, light?.listTitle)
    }

    func testOpenClawFullParserPreservesFirstToolTitleFallback() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-ToolTitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-tool","timestamp":"2026-04-24T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let assistant = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"README.md"}}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("tool.jsonl")
        try (header + assistant).write(to: url, atomically: true, encoding: .utf8)

        let light = try XCTUnwrap(OpenClawSessionParser.parseFile(at: url))
        let full = try XCTUnwrap(OpenClawSessionParser.parseFileFull(at: url))

        XCTAssertEqual(light.listTitle, "read")
        XCTAssertEqual(full.lightweightTitle, light.lightweightTitle)
        XCTAssertEqual(full.listTitle, light.listTitle)
    }

    func testOpenClawFullParserReadsInputWhenToolCallArgumentsAreAbsent() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-ToolInput-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-tool-input","timestamp":"2026-09-25T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let assistant = #"{"type":"message","id":"m1","timestamp":"2026-09-25T00:01:00Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"exec","input":{"command":"pwd"}}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("tool-input.jsonl")
        try (header + assistant).write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(OpenClawSessionParser.parseFileFull(at: url))
        let toolCall = try XCTUnwrap(session.events.first(where: { $0.kind == .tool_call }))
        let toolInput = try XCTUnwrap(toolCall.toolInput)
        let toolInputData = try XCTUnwrap(toolInput.data(using: .utf8))
        let toolInputObject = try XCTUnwrap(JSONSerialization.jsonObject(with: toolInputData) as? [String: String])

        XCTAssertEqual(toolCall.toolName, "exec")
        XCTAssertEqual(toolInputObject["command"], "pwd")
    }

    func testOpenClawFullParserReadsNestedToolResultContent() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-NestedToolResult-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-tool-result","timestamp":"2026-09-25T00:00:00Z","cwd":"/tmp"}"# + "\n"
        let toolResult = #"{"type":"message","id":"m1","timestamp":"2026-09-25T00:01:00Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"exec","isError":true,"content":[{"type":"toolResult","id":"call-1","toolCallId":"call-1","toolUseId":"call-1","tool_use_id":"call-1","name":"exec","toolName":"exec","text":"permission denied","content":"permission denied"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("nested-tool-result.jsonl")
        try (header + toolResult).write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(OpenClawSessionParser.parseFileFull(at: url))
        let event = try XCTUnwrap(session.events.first(where: { $0.kind == .error }))

        XCTAssertEqual(event.messageID, "call-1")
        XCTAssertEqual(event.toolName, "exec")
        XCTAssertEqual(event.toolOutput, "permission denied")
    }

    func testOpenClawParserUsesCronPrefixAsProjectOrigin() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Cron-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-cron","timestamp":"2026-04-24T00:00:00Z","cwd":"/Users/alexm/clawd"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"[cron:49b981e1-346c-4f72-8584-157bde0416d8 google-form-checker] Check forms"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("cron.jsonl")
        try (header + user).write(to: url, atomically: true, encoding: .utf8)

        let session = OpenClawSessionParser.parseFile(at: url)

        XCTAssertEqual(session?.repoName, "cron")
        XCTAssertEqual(session?.repoDisplay, "cron")
    }

    func testOpenClawParserUsesConversationMetadataAsTelegramOrigin() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-TelegramMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-telegram-metadata","timestamp":"2026-04-24T00:00:00Z","cwd":"/Users/alexm/clawd"}"# + "\n"
        let text = """
        Conversation info (untrusted metadata):
        ```json
        {
          "message_id": "1444",
          "sender_id": "1108897",
          "sender": "A M",
          "timestamp": "Sun 2026-04-12 11:14 PDT"
        }
        ```

        Sender (untrusted metadata):
        ```json
        {
          "label": "A M (1108897)",
          "id": "1108897",
          "name": "A M",
          "username": "jazzyalex"
        }
        ```

        smart cat
        """
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let user = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"\#(escaped)"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("telegram-metadata.jsonl")
        try (header + user).write(to: url, atomically: true, encoding: .utf8)

        let session = OpenClawSessionParser.parseFile(at: url)
        let full = OpenClawSessionParser.parseFileFull(at: url)

        XCTAssertEqual(session?.repoName, "telegram")
        XCTAssertEqual(session?.repoDisplay, "telegram")
        XCTAssertEqual(full?.repoName, "telegram")
    }

    func testOpenClawParserUsesTUIForUnprefixedPromptOrigin() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-TUI-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-tui","timestamp":"2026-04-24T00:00:00Z","cwd":"/Users/alexm/clawd"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"local prompt from the terminal"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("tui.jsonl")
        try (header + user).write(to: url, atomically: true, encoding: .utf8)

        let session = OpenClawSessionParser.parseFile(at: url)

        XCTAssertEqual(session?.repoName, "tui")
        XCTAssertEqual(session?.repoDisplay, "tui")
    }

    func testOpenClawParserUsesSystemOriginForHeartbeatOnlySession() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-System-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let header = #"{"type":"session","version":3,"id":"sess-system","timestamp":"2026-04-24T00:00:00Z","cwd":"/Users/alexm/clawd"}"# + "\n"
        let user = #"{"type":"message","id":"m1","timestamp":"2026-04-24T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"Read HEARTBEAT.md and consider outstanding tasks"}]}}"# + "\n"

        let url = sessionsDir.appendingPathComponent("system.jsonl")
        try (header + user).write(to: url, atomically: true, encoding: .utf8)

        let light = OpenClawSessionParser.parseFile(at: url)
        let full = OpenClawSessionParser.parseFileFull(at: url)

        XCTAssertEqual(light?.repoName, "system")
        XCTAssertEqual(light?.repoDisplay, "system")
        XCTAssertEqual(full?.repoName, "system")
        XCTAssertTrue(light?.isHousekeeping ?? false)
        XCTAssertTrue(full?.isHousekeeping ?? false)
    }

    func testDeletedFlagSurvivesMerge() {
        let light = Session(id: "openclaw:main:test",
                            source: .openclaw,
                            startTime: Date(),
                            endTime: Date(),
                            model: nil,
                            filePath: "/tmp/test.jsonl.deleted.1704067200",
                            eventCount: 1,
                            events: [],
                            cwd: "/tmp",
                            repoName: nil,
                            lightweightTitle: "test",
                            deletedAt: Date(timeIntervalSince1970: 1704067200))
        XCTAssertTrue(light.isDeleted)
        XCTAssertNotNil(light.deletedAt)

        let full = Session(id: "openclaw:main:test",
                           source: .openclaw,
                           startTime: Date(),
                           endTime: Date(),
                           model: "gpt-4",
                           filePath: "/tmp/test.jsonl.deleted.1704067200",
                           eventCount: 3,
                           events: [],
                           cwd: "/tmp",
                           repoName: nil,
                           lightweightTitle: nil,
                           deletedAt: Date(timeIntervalSince1970: 1704067200))
        XCTAssertTrue(full.isDeleted)
        XCTAssertEqual(full.deletedAt!.timeIntervalSince1970, 1704067200, accuracy: 1)
    }

    func testSessionIsDeletedDefaultsFalse() {
        let s = Session(id: "test",
                        source: .openclaw,
                        startTime: nil,
                        endTime: nil,
                        model: nil,
                        filePath: "/tmp/test.jsonl",
                        eventCount: 0,
                        events: [])
        XCTAssertFalse(s.isDeleted)
        XCTAssertNil(s.deletedAt)
    }

    func testHermesParserPreservesRecordedCwdWhenPresent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let nestedDir = repoDir.appendingPathComponent("Sources/App", isDirectory: true)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_repo.json")
        let json = """
        {
          "session_id": "20260423_hermes_repo",
          "model": "gpt-5.4",
          "platform": "cli",
          "session_start": "2026-04-23T10:00:00.000000",
          "last_updated": "2026-04-23T10:05:00.000000",
          "cwd": "\(nestedDir.path)",
          "message_count": 1,
          "messages": [
            { "role": "user", "content": "Open the repo" }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFile(at: url) else {
            return XCTFail("Hermes preview parse returned nil")
        }

        XCTAssertEqual(session.cwd, nestedDir.path)
        XCTAssertEqual(session.repoName, "cli")
    }

    func testHermesFullParsePreservesRecordedCwdWhenEventsLoaded() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let nestedDir = root.appendingPathComponent("repo/Sources/App", isDirectory: true)
        try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_full.json")
        let json = """
        {
          "session_id": "20260424_hermes_full",
          "model": "gpt-5.4",
          "platform": "cli",
          "session_start": "2026-04-24T10:00:00.000000",
          "last_updated": "2026-04-24T10:05:00.000000",
          "cwd": "\(nestedDir.path)",
          "message_count": 2,
          "messages": [
            { "role": "user", "content": "Open the repo" },
            { "role": "assistant", "content": "Loaded." }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFileFull(at: url) else {
            return XCTFail("Hermes full parse returned nil")
        }

        XCTAssertFalse(session.events.isEmpty)
        XCTAssertEqual(session.cwd, nestedDir.path)
        XCTAssertEqual(session.repoName, "cli")
    }

    func testHermesStateDBReaderLoadsCurrentDatabaseLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-StateDB-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)

        let discovery = HermesSessionDiscovery(customRoot: root.path)
        XCTAssertTrue(discovery.hasStateDB())
        XCTAssertEqual(discovery.stateDBURL().path, dbURL.path)

        let sessions = HermesStateDBReader.listSessions(dbURL: dbURL)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "hermes_sqlite_demo")
        XCTAssertEqual(sessions.first?.source, .hermes)
        XCTAssertEqual(sessions.first?.cwd, "/tmp/hermes-repo")
        XCTAssertEqual(sessions.first?.repoName, "cli")
        XCTAssertEqual(sessions.first?.model, "qwen3.5-9b")
        XCTAssertEqual(sessions.first?.eventCount, 3)
        XCTAssertEqual(sessions.first?.lightweightCommands, 1)
        XCTAssertEqual(sessions.first?.title, "Hermes SQLite demo")

        guard let full = HermesStateDBReader.loadFullSession(dbURL: dbURL, sessionID: "hermes_sqlite_demo") else {
            return XCTFail("full Hermes state DB parse returned nil")
        }
        XCTAssertEqual(full.eventCount, 5)
        XCTAssertEqual(full.customTitle, "Hermes SQLite demo")
        // delegate_task rows carry an empty tool_name on disk; the envelope must still be decoded.
        let delegate = try XCTUnwrap(full.events.first { $0.kind == .tool_result && $0.messageID == "call_hermes_2" })
        XCTAssertTrue((delegate.toolOutput ?? "").hasPrefix("Subtask 0 · completed · 23s · 4 API calls\n\n"), delegate.toolOutput ?? "nil")
        XCTAssertTrue((delegate.toolOutput ?? "").contains("\"passed\" : true"), delegate.toolOutput ?? "nil")
        XCTAssertEqual(HermesStateDBReader.sessionActivitySignature(dbURL: dbURL, sessionID: "hermes_sqlite_demo"), "5:1780000003.5")
        XCTAssertEqual(HermesStateDBReader.sessionActivitySignature(dbURL: dbURL, sessionID: "missing"), "0:0.0")
        XCTAssertTrue(full.events.contains { $0.kind == .user && ($0.text ?? "").contains("Hello from Hermes SQLite") })
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("Running pwd.") })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "shell" && $0.messageID == "call_hermes_1" })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result && $0.toolName == "shell" && ($0.toolOutput ?? "").contains("/tmp/hermes-repo") })
        XCTAssertTrue(full.events.contains { $0.kind == .meta && ($0.text ?? "").contains("brief reasoning") })
        let sessionMeta = try XCTUnwrap(full.events.first { $0.kind == .meta && $0.role == "session_meta" })
        XCTAssertNil(sessionMeta.text)
        XCTAssertFalse(sessionMeta.rawJSON.isEmpty)
    }

    func testHermesTelemetryReadsModelUsageWithoutTitleGenerationDoubleCount() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let scan = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session))
        let telemetry = scan.result.telemetry
        XCTAssertGreaterThan(scan.bytesScanned, 0)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "qwen3.5-9b")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen3.5-9b")
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "high")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertEqual(telemetry.configurationChanges, [])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 30)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 30)
        XCTAssertTrue(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 20)
        XCTAssertEqual(telemetry.usageEvents.first?.reasoningOutputTokens, 2)
        XCTAssertEqual(telemetry.usageSlices.first?.model, "qwen3.5-9b")
        XCTAssertEqual(SessionSourceRegistry.descriptor(for: .hermes).telemetry.cost,
                       .unavailable("Hermes native cost is provider-specific and is not shown as an API-equivalent estimate"))
    }

    func testHermesTelemetryKeepsAuxiliaryUsageSeparateFromSessionAggregate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Auxiliary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        INSERT INTO session_model_usage
            (session_id, model, task, api_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES ('hermes_sqlite_demo', 'vision-model', 'vision', 1, 2, 3, 0, 0, 0,
                1780000002.5, 1780000002.5);
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "qwen3.5-9b")
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 35)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertTrue(telemetry.usageSlices.contains { $0.model == "vision-model" })
    }

    func testHermesTelemetryDoesNotFallbackWhenRollupContainsOnlyBookkeepingRows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Bookkeeping-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("DELETE FROM session_model_usage WHERE task = '';", at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
        XCTAssertNil(telemetry.usageSummary?.displayTotalTokens)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains("only bookkeeping rows") == true)
    }

    func testHermesTelemetryLabelsAuxiliaryOnlyRollupWithoutClaimingBookkeeping() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Auxiliary-Only-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        DELETE FROM session_model_usage WHERE task = '';
        INSERT INTO session_model_usage
            (session_id, model, task, api_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES ('hermes_sqlite_demo', 'vision-model', 'vision', 1, 2, 3, 0, 0, 0,
                1780000002.5, 1780000002.5);
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains("no main-loop rollup rows") == true)
        XCTAssertFalse(telemetry.usageSummary?.unavailableReason?.contains("only bookkeeping rows") == true)
    }

    func testHermesTelemetryLegacyAggregateFallbackIsUnattributed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("DROP TABLE session_model_usage;", at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["hermes.sessions"])
        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageEvents.first?.usageFamily, "hermes.sessions")
        XCTAssertNil(telemetry.usageEvents.first?.model)
        XCTAssertNil(telemetry.usageSlices.first?.model)
    }

    func testHermesTelemetryFailsClosedWhenCombinedTopLineOverflows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        UPDATE sessions
        SET input_tokens = 9223372036854775807, output_tokens = 1,
            cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0
        WHERE id = 'hermes_sqlite_demo';
        UPDATE session_model_usage
        SET input_tokens = 9223372036854775807, output_tokens = 1,
            cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0
        WHERE task = '';
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSlices.isEmpty)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, nil)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains("integer range") == true)
    }

    func testHermesLegacyAggregateOverflowKeepsSessionProvenance() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Legacy-Overflow-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        DROP TABLE session_model_usage;
        UPDATE sessions
        SET input_tokens = 9223372036854775807, output_tokens = 1,
            cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0
        WHERE id = 'hermes_sqlite_demo';
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["hermes.sessions"])
        XCTAssertNil(telemetry.usageSummary?.displayTotalTokens)
    }

    func testHermesTelemetryKeepsKnownFirstObservationAheadOfUnknownTimestamp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Ordering-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        UPDATE session_model_usage
        SET model = 'unknown-time-model', first_seen = NULL, last_seen = 1780000003.5,
            input_tokens = 10, output_tokens = 20
        WHERE task = '';
        INSERT INTO session_model_usage
            (session_id, model, task, api_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES ('hermes_sqlite_demo', 'known-time-model', '', 1, 0, 0, 0, 0, 0,
                1780000000.2, 1780000000.2);
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "known-time-model")
        XCTAssertEqual(telemetry.configurationChanges, [])
    }

    func testHermesTelemetryDoesNotInferInitialModelWhenAllFirstObservationsAreUnknown() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Unknown-Ordering-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        UPDATE session_model_usage
        SET model = 'unknown-time-model', first_seen = NULL, last_seen = 1780000003.5
        WHERE task = '';
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "qwen3.5-9b")
    }

    func testHermesTelemetryDoesNotInventModelChangesFromPerModelRollup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-ModelHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("""
        UPDATE sessions
        SET model = 'model-c', input_tokens = 4, output_tokens = 4,
            cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0
        WHERE id = 'hermes_sqlite_demo';
        UPDATE session_model_usage
        SET model = 'model-a', input_tokens = 1, output_tokens = 1,
            cache_read_tokens = 0, cache_write_tokens = 0, reasoning_tokens = 0,
            first_seen = 1780000000.1, last_seen = 1780000000.1
        WHERE task = '';
        INSERT INTO session_model_usage
            (session_id, model, task, api_call_count, input_tokens, output_tokens,
             cache_read_tokens, cache_write_tokens, reasoning_tokens, first_seen, last_seen)
        VALUES
            ('hermes_sqlite_demo', 'model-b', '', 1, 1, 1, 0, 0, 0, 1780000001.0, 1780000001.0),
            ('hermes_sqlite_demo', 'model-a', '', 1, 1, 1, 0, 0, 0, 1780000002.0, 1780000002.0),
            ('hermes_sqlite_demo', 'model-c', '', 1, 1, 1, 0, 0, 0, 1780000003.0, 1780000003.0);
        """, at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)?.result.telemetry)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "model-a")
        XCTAssertEqual(telemetry.currentConfiguration?.model, "model-c")
        XCTAssertEqual(telemetry.configurationChanges, [])
    }

    func testHermesTelemetryRevisionIsSessionScopedAndLogical() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Revision-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)
        let revision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))
        XCTAssertEqual(revision, HermesTelemetryReader.telemetryRevision(for: session))

        try executeSQLite("""
        INSERT INTO sessions
            (id, source, user_id, model, model_config, system_prompt, parent_session_id,
             started_at, ended_at, end_reason, message_count, tool_call_count,
             input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             reasoning_tokens, total_tokens, cost, title, last_activity_at)
        VALUES
            ('hermes_sqlite_other', 'cli', 'user_1', 'qwen3.5-9b', NULL, NULL, NULL,
             1780000010.0, 1780000011.0, 'complete', 0, 0, 0, 0, 0, 0, 0, 0, 0,
             'Other', 1780000010.5);
        """, at: dbURL)
        let other = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first { $0.id == "hermes_sqlite_other" })
        let otherRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: other))
        XCTAssertNotEqual(revision, otherRevision)

        let fractionalRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))
        try executeSQLite("UPDATE sessions SET last_activity_at = 1780000003.9 WHERE id = 'hermes_sqlite_demo';", at: dbURL)
        let changedFractionalRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(fractionalRevision, changedFractionalRevision)

        try executeSQLite("DROP TABLE session_model_usage;", at: dbURL)
        let legacyRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(revision, legacyRevision)
    }

    func testHermesTelemetryFailsClosedForMalformedSQLiteStorageClasses() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Malformed-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let taskRoot = root.appendingPathComponent("task", isDirectory: true)
        try fm.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let taskDBURL = taskRoot.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: taskDBURL)
        try executeSQLite("UPDATE session_model_usage SET task = CAST('vision' AS BLOB) WHERE task = '';", at: taskDBURL)
        let taskSession = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: taskDBURL).first)
        XCTAssertNil(HermesTelemetryReader.loadTelemetry(for: taskSession))
        XCTAssertNil(HermesTelemetryReader.telemetryRevision(for: taskSession))

        let timestampRoot = root.appendingPathComponent("timestamp", isDirectory: true)
        try fm.createDirectory(at: timestampRoot, withIntermediateDirectories: true)
        let timestampDBURL = timestampRoot.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: timestampDBURL)
        try executeSQLite("UPDATE sessions SET last_activity_at = CAST('1780000003.9' AS BLOB) WHERE id = 'hermes_sqlite_demo';", at: timestampDBURL)
        let timestampSession = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: timestampDBURL).first)
        XCTAssertNil(HermesTelemetryReader.loadTelemetry(for: timestampSession))
        XCTAssertNil(HermesTelemetryReader.telemetryRevision(for: timestampSession))
    }

    func testHermesTelemetryFailsClosedForEmbeddedNULInSQLiteText() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Embedded-NUL-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        try executeSQLite("UPDATE session_model_usage SET task = CAST(X'00766973696F6E' AS TEXT) WHERE task = '';", at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)

        XCTAssertNil(HermesTelemetryReader.loadTelemetry(for: session))
        XCTAssertNil(HermesTelemetryReader.telemetryRevision(for: session))
    }

    func testHermesTelemetryRevisionDistinguishesNullAndLiteralNullText() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-Telemetry-Revision-Null-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)
        let nullRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))

        try executeSQLite("UPDATE session_model_usage SET task = '<null>' WHERE task = '';", at: dbURL)
        let literalNullRevision = try XCTUnwrap(HermesTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(nullRevision, literalNullRevision)
    }

    func testHermesParserKeepsOfflinePathMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let nonRepoDir = root.appendingPathComponent("plain-folder", isDirectory: true)
        try fm.createDirectory(at: nonRepoDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_plain.json")
        let json = """
        {
          "session_id": "20260423_hermes_plain",
          "model": "gpt-5.4",
          "platform": "cli",
          "session_start": "2026-04-23T10:00:00.000000",
          "last_updated": "2026-04-23T10:05:00.000000",
          "model_config": { "cwd": "\(nonRepoDir.path)" },
          "message_count": 1,
          "messages": [
            { "role": "user", "content": "Open plain folder" }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFile(at: url) else {
            return XCTFail("Hermes preview parse returned nil")
        }

        XCTAssertEqual(session.cwd, nonRepoDir.path)
        XCTAssertEqual(session.repoName, "cli")
    }

    func testHermesParserPreservesDeepNestedPathsWithoutFilesystemProbe() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let repoDir = root.appendingPathComponent("repo", isDirectory: true)
        let deepDir = repoDir
            .appendingPathComponent("one/two/three/four/five/six/seven/eight", isDirectory: true)
        try fm.createDirectory(at: deepDir, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_deep.json")
        let json = """
        {
          "session_id": "20260423_hermes_deep",
          "model": "gpt-5.4",
          "platform": "cli",
          "session_start": "2026-04-23T10:00:00.000000",
          "last_updated": "2026-04-23T10:05:00.000000",
          "model_config": { "cwd": "\(deepDir.path)" },
          "message_count": 1,
          "messages": [
            { "role": "user", "content": "Open the deep repo path" }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFile(at: url) else {
            return XCTFail("Hermes preview parse returned nil")
        }

        XCTAssertEqual(session.cwd, deepDir.path)
        XCTAssertEqual(session.repoName, "cli")
    }

    func testHermesParserUsesPlatformAsProjectOrigin() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_telegram.json")
        let json = """
        {
          "session_id": "20260424_hermes_telegram",
          "model": "gpt-5.4",
          "platform": "telegram",
          "session_start": "2026-04-24T10:00:00.000000",
          "last_updated": "2026-04-24T10:05:00.000000",
          "message_count": 1,
          "messages": [
            { "role": "user", "content": "Start from Telegram" }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFile(at: url) else {
            return XCTFail("Hermes preview parse returned nil")
        }

        XCTAssertNil(session.cwd)
        XCTAssertEqual(session.repoName, "telegram")
        XCTAssertEqual(session.repoDisplay, "telegram")
    }

    func testHermesParserFallsBackWhenPlatformMissing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("session_hermes_no_platform.json")
        let json = """
        {
          "session_id": "20260424_hermes_no_platform",
          "model": "gpt-5.4",
          "platform": null,
          "session_start": "2026-04-24T10:00:00.000000",
          "last_updated": "2026-04-24T10:05:00.000000",
          "message_count": 1,
          "messages": [
            { "role": "user", "content": "No platform here" }
          ]
        }
        """
        try writeText(json, to: url)

        guard let session = HermesSessionParser.parseFile(at: url) else {
            return XCTFail("Hermes preview parse returned nil")
        }

        XCTAssertNil(session.cwd)
        XCTAssertNil(session.repoName)
        XCTAssertEqual(session.repoDisplay, "—")
    }

    func testCodexInternalSessionIDPrefersOwnIDOverParentPointingSessionID() throws {
        // Newer Codex builds set payload.session_id to the PARENT's UUID on
        // subagent rollouts; payload.id is the thread's own UUID. Resume and
        // hierarchy joins must use the OWN id.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexOwnID-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T17-22-56-019f7ce7-8979-7203-8867-34084576cf0c.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T00:22:56.633Z","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/tmp","source":{"subagent":{"other":"guardian"}}}}"#,
            #"{"timestamp":"2026-07-20T00:22:57.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.codexInternalSessionIDHint, "019f7ce7-8979-7203-8867-34084576cf0c")
    }

    func testCodexAppendParseAddsOnlyNewCompleteLinesAndPreservesMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexAppend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rollout.jsonl")
        let parentID = "019f7ce5-7a52-7e32-8fc5-99c3193aba48"
        let baselineLines = [
            #"{"timestamp":"2026-09-11T10:00:00Z","type":"session_meta","payload":{"id":"child","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/tmp","originator":"codex-tui","source":{"subagent":{"other":"review"}}}}"#,
            #"{"timestamp":"2026-09-11T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"high"}}"#,
            #"{"timestamp":"2026-09-11T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"baseline"}]}}"#
        ]
        try writeText(baselineLines.joined(separator: "\n") + "\n", to: url)

        let indexer = SessionIndexer()
        let baseline = try XCTUnwrap(indexer.parseFileFull(at: url, forcedID: "stable-row-id"))
        let cursor = try XCTUnwrap(indexer.makeAppendCursor(at: url,
                                                            lastLineIndex: baselineLines.count))
        let appendedLines = [
            #"{"timestamp":"2026-09-11T10:00:03Z","type":"turn_context","payload":{"model":"gpt-6-astra","effort":"xhigh"}}"#,
            #"{"timestamp":"2026-09-11T10:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"appended"}]}}"#
        ]
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLines.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        guard case let .appended(updated, nextCursor) = indexer.parseFileAppend(
            at: url,
            existing: baseline,
            cursor: cursor
        ) else {
            return XCTFail("Expected append parse")
        }
        XCTAssertEqual(updated.events.count, baseline.events.count + appendedLines.count)
        XCTAssertEqual(Array(updated.events.prefix(baseline.events.count)), baseline.events)
        XCTAssertEqual(updated.events[baseline.events.count].id,
                       SessionIndexer.eventID(forPath: url.path, index: baselineLines.count + 1))
        XCTAssertEqual(updated.id, "stable-row-id")
        XCTAssertEqual(updated.parentSessionID, parentID)
        XCTAssertEqual(updated.subagentType, "review")
        XCTAssertEqual(updated.codexSurface, .subagent)
        XCTAssertEqual(updated.model, "gpt-6-astra")
        XCTAssertEqual(updated.reasoningEffort, "high")
        XCTAssertEqual(nextCursor.lastLineIndex, baselineLines.count + appendedLines.count)
        XCTAssertEqual(nextCursor.byteOffset, UInt64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
    }

    func testCodexAppendParseDefersPartialLineThenConsumesItOnceComplete() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexPartialAppend-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let baselineLine = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]}}"#
        try writeText(baselineLine + "\n", to: url)
        let indexer = SessionIndexer()
        let baseline = try XCTUnwrap(indexer.parseFileFull(at: url))
        let cursor = try XCTUnwrap(indexer.makeAppendCursor(at: url, lastLineIndex: 1))
        let appendedLine = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}"#
        let split = appendedLine.index(appendedLine.startIndex, offsetBy: appendedLine.count / 2)

        var handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine[..<split].utf8))
        try handle.close()
        guard case .incompleteTail = indexer.parseFileAppend(at: url, existing: baseline, cursor: cursor) else {
            return XCTFail("Expected incomplete tail deferral")
        }

        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(appendedLine[split...]) + "\n").utf8))
        try handle.close()
        guard case let .appended(updated, _) = indexer.parseFileAppend(at: url,
                                                                       existing: baseline,
                                                                       cursor: cursor) else {
            return XCTFail("Expected completed line to append")
        }
        XCTAssertEqual(updated.events.count, 2)
        XCTAssertEqual(updated.events.last?.text, "two")
    }

    func testCodexAppendParseFallsBackForTruncationAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexAppendInvalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("rollout.jsonl")
        let line = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"baseline"}]}}"#
        try writeText(line + "\n", to: url)
        let indexer = SessionIndexer()
        let baseline = try XCTUnwrap(indexer.parseFileFull(at: url))
        let cursor = try XCTUnwrap(indexer.makeAppendCursor(at: url, lastLineIndex: 1))

        guard case .unchanged = indexer.parseFileAppend(at: url,
                                                         existing: baseline,
                                                         cursor: cursor) else {
            return XCTFail("An unchanged cursor must not force a full parse")
        }

        try FileManager.default.setAttributes(
            [.modificationDate: cursor.modifiedAt.addingTimeInterval(1)],
            ofItemAtPath: url.path
        )
        guard case .fallbackToFullParse = indexer.parseFileAppend(at: url,
                                                                  existing: baseline,
                                                                  cursor: cursor) else {
            return XCTFail("A same-size mtime change must invalidate append state")
        }

        try writeText("{}\n", to: url)
        guard case .fallbackToFullParse = indexer.parseFileAppend(at: url,
                                                                  existing: baseline,
                                                                  cursor: cursor) else {
            return XCTFail("Truncation must invalidate append state")
        }

        try FileManager.default.removeItem(at: url)
        try writeText(line + "\n" + line + "\n", to: url)
        guard case .fallbackToFullParse = indexer.parseFileAppend(at: url,
                                                                  existing: baseline,
                                                                  cursor: cursor) else {
            return XCTFail("Replacement must invalidate append state")
        }
    }

    func testFocusedCodexReloadUsesInstalledAppendCursorWithoutSecondFullParse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexReloadAppend-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let baselineLine = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"baseline"}]}}"#
        try writeText(baselineLine + "\n", to: url)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let sessionID = "reload-append-id"
        let lightweight = Session(id: sessionID,
                                  source: .codex,
                                  startTime: nil,
                                  endTime: nil,
                                  model: nil,
                                  filePath: url.path,
                                  fileSizeBytes: size,
                                  eventCount: 1,
                                  events: [],
                                  cwd: "/tmp",
                                  repoName: "tmp",
                                  lightweightTitle: "baseline")
        let indexer = SessionIndexer()
        indexer.installSessionsForReloadTesting([lightweight])

        let hydrated = expectation(description: "initial full hydration")
        var hydrationCancellable: AnyCancellable?
        hydrationCancellable = indexer.$allSessions
            .filter { $0.first?.events.count == 1 }
            .prefix(1)
            .sink { _ in hydrated.fulfill() }
        indexer.reloadSession(id: sessionID, reason: .selection)
        wait(for: [hydrated], timeout: 3)
        hydrationCancellable?.cancel()
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: sessionID, timeout: 1),
                      "Initial publish must finish reload bookkeeping before the monitor tick")
        let afterHydration = indexer.reloadParseInvocationCountsForTesting()

        let appendedLine = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"delta"}]}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLine + "\n").utf8))
        try handle.close()

        let appended = expectation(description: "focused append hydration")
        var appendCancellable: AnyCancellable?
        appendCancellable = indexer.$allSessions
            .filter { $0.first?.events.count == 2 }
            .prefix(1)
            .sink { _ in appended.fulfill() }
        indexer.reloadSession(id: sessionID, force: true, reason: .focusedSessionMonitor)
        wait(for: [appended], timeout: 3)
        appendCancellable?.cancel()

        let afterAppend = indexer.reloadParseInvocationCountsForTesting()
        XCTAssertEqual(afterAppend.full, afterHydration.full,
                       "Focused growth must not invoke parseFileFull again")
        XCTAssertEqual(afterAppend.append, afterHydration.append + 1)
        XCTAssertEqual(indexer.allSessions.first?.events.last?.text, "delta")
    }

    func testFocusedCodexReloadDetectsSameSizeSameMtimeAtomicReplacement() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexReloadReplacement-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let fixedMtime = Date(timeIntervalSince1970: 1_799_999_900)
        let baselineLine = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"baseline"}]}}"#
        let replacementLine = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"replaced"}]}}"#
        XCTAssertEqual(baselineLine.utf8.count, replacementLine.utf8.count)
        try writeText(baselineLine + "\n", to: url)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: url.path)
        let originalInode = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )

        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let sessionID = "reload-replacement-id"
        let lightweight = Session(id: sessionID,
                                  source: .codex,
                                  startTime: nil,
                                  endTime: nil,
                                  model: nil,
                                  filePath: url.path,
                                  fileSizeBytes: size,
                                  eventCount: 1,
                                  events: [])
        let indexer = SessionIndexer()
        indexer.installSessionsForReloadTesting([lightweight])

        let hydrated = expectation(description: "initial replacement-test hydration")
        var cancellable = indexer.$allSessions
            .filter { $0.first?.events.first?.text == "baseline" }
            .prefix(1)
            .sink { _ in hydrated.fulfill() }
        indexer.reloadSession(id: sessionID, reason: .selection)
        wait(for: [hydrated], timeout: 3)
        cancellable.cancel()
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: sessionID, timeout: 1))
        let beforeReplacement = indexer.reloadParseInvocationCountsForTesting()

        try Data((replacementLine + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: url.path)
        let replacementInode = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        XCTAssertNotEqual(replacementInode, originalInode, "Fixture must replace the file identity")

        let replaced = expectation(description: "replacement content published")
        cancellable = indexer.$allSessions
            .filter { $0.first?.events.first?.text == "replaced" }
            .prefix(1)
            .sink { _ in replaced.fulfill() }
        indexer.reloadSession(id: sessionID, force: true, reason: .focusedSessionMonitor)
        wait(for: [replaced], timeout: 3)
        cancellable.cancel()
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: sessionID, timeout: 1))

        let afterReplacement = indexer.reloadParseInvocationCountsForTesting()
        XCTAssertEqual(afterReplacement.append, beforeReplacement.append + 1)
        XCTAssertEqual(afterReplacement.full, beforeReplacement.full + 1,
                       "An identity mismatch must fall back to a full parse even when coarse stats match")
    }

    func testFocusedCodexReloadCoalescesTranscriptCacheBuildsAndPublishesNewestSnapshot() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-CodexCacheCoalesce-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let baselineLine = #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"baseline"}]}}"#
        try writeText(baselineLine + "\n", to: url)
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let sessionID = "reload-cache-coalesce-id"
        let lightweight = Session(id: sessionID,
                                  source: .codex,
                                  startTime: nil,
                                  endTime: nil,
                                  model: nil,
                                  filePath: url.path,
                                  fileSizeBytes: size,
                                  eventCount: 1,
                                  events: [])
        let indexer = SessionIndexer()
        indexer.installSessionsForReloadTesting([lightweight])

        let hydrated = expectation(description: "initial cache-test hydration")
        var cancellable = indexer.$allSessions
            .filter { $0.first?.events.count == 1 }
            .prefix(1)
            .sink { _ in hydrated.fulfill() }
        indexer.reloadSession(id: sessionID, reason: .selection)
        wait(for: [hydrated], timeout: 3)
        cancellable.cancel()
        XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: sessionID, timeout: 1))
        XCTAssertTrue(indexer.waitForTranscriptCacheBuildsToFinishForTesting(id: sessionID, timeout: 3))

        let firstBuildStarted = expectation(description: "first append cache build started")
        let secondBuildStarted = expectation(description: "newest pending cache build started")
        let firstBuildGate = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var buildCount = 0
        indexer.setTranscriptCacheBuildHookForTesting { _ in
            hookLock.lock()
            buildCount += 1
            let ordinal = buildCount
            hookLock.unlock()
            if ordinal == 1 {
                firstBuildStarted.fulfill()
                _ = firstBuildGate.wait(timeout: .now() + 5)
            } else if ordinal == 2 {
                secondBuildStarted.fulfill()
            }
        }
        defer {
            firstBuildGate.signal()
            indexer.setTranscriptCacheBuildHookForTesting(nil)
        }

        func appendAndReload(_ text: String, expectedCount: Int) throws {
            let line = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}}"#
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try handle.close()
            let published = expectation(description: "published \(text)")
            let token = indexer.$allSessions
                .filter { $0.first?.events.count == expectedCount }
                .prefix(1)
                .sink { _ in published.fulfill() }
            indexer.reloadSession(id: sessionID, force: true, reason: .focusedSessionMonitor)
            wait(for: [published], timeout: 3)
            token.cancel()
            XCTAssertTrue(indexer.waitForReloadToFinishForTesting(id: sessionID, timeout: 1))
        }

        try appendAndReload("delta-one", expectedCount: 2)
        wait(for: [firstBuildStarted], timeout: 2)
        try appendAndReload("delta-two", expectedCount: 3)
        hookLock.lock()
        let buildsBeforeRelease = buildCount
        hookLock.unlock()
        XCTAssertEqual(buildsBeforeRelease, 1,
                       "A second builder must not overlap the blocked in-flight build")
        firstBuildGate.signal()
        wait(for: [secondBuildStarted], timeout: 3)
        XCTAssertTrue(indexer.waitForTranscriptCacheBuildsToFinishForTesting(id: sessionID, timeout: 3))

        hookLock.lock()
        let finalBuildCount = buildCount
        hookLock.unlock()
        XCTAssertEqual(finalBuildCount, 2,
                       "The in-flight builder plus one latest pending snapshot should be the only builds")
        let cached = try XCTUnwrap(indexer.searchTranscriptCache.getCached(sessionID))
        XCTAssertTrue(cached.contains("delta-two"), "The newest pending snapshot must win publication")
    }

    // MARK: - 5.3.1 effective row-title search

    func testFilterEngineFindsCustomTitleViaListTitle() throws {
        let session = Session(
            id: "effective-title-filter",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/codex/effective-title-filter.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Generic lightweight fallback",
            customTitle: "ZebraCustomAlpha824"
        )
        // The model-level row title surfaces the custom title.
        XCTAssertTrue(session.listTitle.contains("ZebraCustomAlpha824"))
        let filters = Filters(query: "ZebraCustomAlpha824")
        XCTAssertTrue(FilterEngine.sessionMatches(session, filters: filters, allowTranscriptGeneration: false))
        // An unrelated preamble query must not match through the title path.
        XCTAssertFalse(FilterEngine.sessionMatches(session, filters: Filters(query: "PreambleNoMatchQzx"),
                                                    allowTranscriptGeneration: false))
    }

    func testSearchCoordinatorFindsChangedCustomTitleAbsentFromFTS() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let session = Session(
            id: "changed-custom-title",
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/codex/changed-custom-title.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Old lightweight",
            customTitle: "ZebraChangedBeta512"
        )
        try await db.begin()
        try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "codex")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: session.id, source: "codex", path: session.filePath, mtime: 10, size: 20,
            startTS: 1, endTS: 2, model: nil, cwd: "/tmp/repo", repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        // Byte-current row whose FTS text predates the title change: no reindex.
        try await db.upsertSessionSearch(sessionID: session.id, source: "codex",
                                         mtime: 10, size: 20,
                                         text: "old unrelated body without the new name")
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "ZebraChangedBeta512",
                          filters: Filters(query: "ZebraChangedBeta512"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: [session])
        try await waitForSearchResults(coordinator, expectedIDs: [session.id])
    }

    func testSearchCoordinatorFindsClaudeArchiveDisplayTitleAbsentFromFTS() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let session = Session(
            id: "claude-archive-title",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/claude/claude-archive-title.jsonl",
            eventCount: 0,
            events: [],
            cwd: "/tmp/repo",
            repoName: "repo",
            lightweightTitle: "Generic claude row title"
        )
        try await db.begin()
        try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "claude")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: session.id, source: "claude", path: session.filePath, mtime: 10, size: 20,
            startTS: 1, endTS: 2, model: nil, cwd: "/tmp/repo", repo: "repo",
            title: nil, codexInternalSessionID: nil, isHousekeeping: false,
            messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        try await db.upsertSessionSearch(sessionID: session.id, source: "claude",
                                         mtime: 10, size: 20,
                                         text: "generic archived body without the sidecar name")
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "ZebraSidecarGamma731",
                          filters: Filters(query: "ZebraSidecarGamma731"),
                          allowed: [.claude],
                          enableDeepScan: false,
                          all: [session],
                          effectiveDisplayTitles: [SearchCoordinator.SessionKey(session): "ZebraSidecarGamma731"])
        try await waitForSearchResults(coordinator, expectedIDs: [session.id])
    }

    func testSearchCoordinatorTitleOnlyHonorsSourceAndMetadataFilter() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        func titleSession(id: String, source: SessionSource, model: String?) -> Session {
            Session(
                id: id, source: source, startTime: nil, endTime: nil, model: model,
                filePath: "/tmp/\(source.rawValue)/\(id).jsonl",
                eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
                lightweightTitle: "ZebraHonorDelta441",
                customTitle: "ZebraHonorDelta441"
            )
        }
        let matching = titleSession(id: "title-ok", source: .codex, model: "expected-model")
        let wrongModel = titleSession(id: "title-wrong-model", source: .codex, model: "other-model")
        let wrongSource = titleSession(id: "title-wrong-source", source: .opencode, model: "expected-model")
        let all = [matching, wrongModel, wrongSource]

        try await db.begin()
        for session in all {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: session.source.rawValue)
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: session.source.rawValue, path: session.filePath,
                mtime: 10, size: 20, startTS: 1, endTS: 2, model: session.model,
                cwd: "/tmp/repo", repo: "repo", title: nil, codexInternalSessionID: nil,
                isHousekeeping: false, messages: 1, commands: 0,
                parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            try await db.upsertSessionSearch(sessionID: session.id, source: session.source.rawValue,
                                             mtime: 10, size: 20,
                                             text: "generic body without the title token")
        }
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "ZebraHonorDelta441",
                          filters: Filters(query: "ZebraHonorDelta441", model: "expected-model"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: all)
        try await waitForSearchResults(coordinator, expectedIDs: [matching.id])
    }

    func testSearchCoordinatorDedupesFTSAndTitleWithStableOrder() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        func orderedSession(id: String, title: String) -> Session {
            Session(
                id: id, source: .codex, startTime: nil, endTime: nil, model: nil,
                filePath: "/tmp/codex/\(id).jsonl",
                eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
                lightweightTitle: title, customTitle: title
            )
        }
        let dual = orderedSession(id: "order-dual", title: "ZebraOrderEpsilon918")
        let titleB = orderedSession(id: "order-title-b", title: "ZebraOrderEpsilon918")
        let titleC = orderedSession(id: "order-title-c", title: "ZebraOrderEpsilon918")
        let all = [dual, titleB, titleC]

        try await db.begin()
        for session in all {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "codex")
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: "codex", path: session.filePath,
                mtime: 10, size: 20, startTS: 1, endTS: 2, model: nil,
                cwd: "/tmp/repo", repo: "repo", title: nil, codexInternalSessionID: nil,
                isHousekeeping: false, messages: 1, commands: 0,
                parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            let text = session.id == dual.id
                ? "ZebraOrderEpsilon918 body hit"
                : "generic body without the token"
            try await db.upsertSessionSearch(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20, text: text)
        }
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "ZebraOrderEpsilon918",
                          filters: Filters(query: "ZebraOrderEpsilon918"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: all)
        try await waitForSearchResults(coordinator, expectedIDs: [dual.id, titleB.id, titleC.id])
        XCTAssertEqual(coordinator.results.map(\.id), [dual.id, titleB.id, titleC.id])
        XCTAssertEqual(Set(coordinator.results.map(\.id)).count, 3, "dual FTS+title hit must appear once")
    }

    func testSearchCoordinatorLegacyPathRetainsSeededEffectiveTitles() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        // No rows seeded: hasSearchData is false so the coordinator falls back
        // to legacy search. Seeded effective titles must still be retained.
        let listTitleSession = Session(
            id: "legacy-list-title",
            source: .codex, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/codex/legacy-list-title.jsonl",
            eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
            lightweightTitle: "ZebraLegacyZeta207",
            customTitle: "ZebraLegacyZeta207"
        )
        let overrideSession = Session(
            id: "legacy-override-title",
            source: .codex, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/codex/legacy-override-title.jsonl",
            eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
            lightweightTitle: "Generic legacy row"
        )
        let all = [listTitleSession, overrideSession]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "ZebraLegacyZeta207",
                          filters: Filters(query: "ZebraLegacyZeta207"),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: all,
                          effectiveDisplayTitles: [SearchCoordinator.SessionKey(overrideSession): "ZebraLegacyZeta207"])
        // The override session matches only via the seeded snapshot; the legacy
        // scan must retain (not wipe or duplicate) both seeded hits.
        for _ in 0..<50 {
            let ids = Set(coordinator.results.map(\.id))
            if ids == Set([listTitleSession.id, overrideSession.id]) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(Set(coordinator.results.map(\.id)),
                       Set([listTitleSession.id, overrideSession.id]))
        XCTAssertEqual(coordinator.results.map(\.id).count,
                       Set(coordinator.results.map(\.id)).count, "seeded titles must not duplicate")
    }

    func testClaudeDisplayTitleSnapshotReturnsOverrideAndExcludesUnrelatedRows() {
        let claude = Session(
            id: "snapshot-claude",
            source: .claude, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/claude/snapshot-claude.jsonl",
            eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
            lightweightTitle: "Generic claude row"
        )
        let codex = Session(
            id: "snapshot-codex",
            source: .codex, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/codex/snapshot-codex.jsonl",
            eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
            lightweightTitle: "Generic codex row"
        )
        let blankClaude = Session(
            id: "snapshot-blank",
            source: .claude, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/claude/snapshot-blank.jsonl",
            eventCount: 0, events: [], cwd: "/tmp/repo", repoName: "repo",
            lightweightTitle: "Another claude row"
        )
        // Mirrors production: `unified.claudeDesktopTitle(for:)` returns the
        // sidecar title for the archived Claude row and nil elsewhere.
        let snapshot = UnifiedSessionsView.claudeDisplayTitleSnapshot(
            sessions: [claude, codex, blankClaude]
        ) { session in
            session.id == claude.id ? "ZebraSnapshotSidecar613" : nil
        }
        XCTAssertEqual(snapshot, [SearchCoordinator.SessionKey(claude): "ZebraSnapshotSidecar613"])
        // Whitespace-only overrides are excluded like nils.
        let blankSnapshot = UnifiedSessionsView.claudeDisplayTitleSnapshot(
            sessions: [blankClaude]
        ) { _ in "   " }
        XCTAssertTrue(blankSnapshot.isEmpty)
    }

    func testEffectiveDisplayTitleOverrideDoesNotCrossSameIDSourceBoundary() async throws {
        let sharedID = "same-id-title-boundary"
        let codex = makeProjectIdentitySession(
            id: sharedID, source: .codex, cwd: "/AS531/title/codex",
            title: "Generic Codex title"
        )
        let claude = makeProjectIdentitySession(
            id: sharedID, source: .claude, cwd: "/AS531/title/claude",
            title: "Generic Claude title"
        )
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: nil)
        coordinator.start(
            query: "ZebraSourceBoundary846",
            filters: Filters(query: "ZebraSourceBoundary846"),
            allowed: [.codex, .claude],
            enableDeepScan: false,
            all: [codex, claude],
            effectiveDisplayTitles: [
                SearchCoordinator.SessionKey(claude): "ZebraSourceBoundary846"
            ]
        )

        for _ in 0..<50 {
            if coordinator.results.map(\.source) == [.claude] { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(coordinator.results.map(\.source), [.claude],
                       "a Claude sidecar title must not leak to a Codex row with the same bare id")
    }

    // MARK: - Exact project identity (5.3.1, canary AS531-PROJECT-IDENTITY-EXACT)

    private func makeProjectIdentitySession(
        id: String,
        source: SessionSource = .codex,
        cwd: String?,
        repoName: String? = nil,
        model: String? = nil,
        title: String? = nil,
        filePath: String? = nil,
        events: [SessionEvent] = [],
        codexSurface: CodexSessionSurface? = nil,
        originator: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: source,
            startTime: nil,
            endTime: nil,
            model: model,
            filePath: filePath ?? "/tmp/AS531/\(id).jsonl",
            eventCount: events.count,
            events: events,
            cwd: cwd,
            repoName: repoName,
            lightweightTitle: title ?? id,
            codexSurface: codexSurface,
            originator: originator
        )
    }

    private func sameOriginEvent() -> SessionEvent {
        SessionEvent(
            id: "same-origin",
            timestamp: nil,
            kind: .meta,
            role: nil,
            text: nil,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: #"{"git_origin_url":"https://example.test/acme/same.git"}"#
        )
    }

    func testProjectIdentitySameBasenameDistinctRootsUnequal() throws {
        let a = makeProjectIdentitySession(id: "ident-a", cwd: "/AS531-ident/alpha/app")
        let b = makeProjectIdentitySession(id: "ident-b", cwd: "/AS531-ident/beta/app")
        XCTAssertEqual(a.rowRepoName, "app")
        XCTAssertEqual(b.rowRepoName, "app")
        let identityA = try XCTUnwrap(a.rowProjectIdentity)
        let identityB = try XCTUnwrap(b.rowProjectIdentity)
        XCTAssertEqual(identityA.canonicalRootPath, "/AS531-ident/alpha/app")
        XCTAssertEqual(identityB.canonicalRootPath, "/AS531-ident/beta/app")
        XCTAssertNotEqual(identityA, identityB, "AS531-PROJECT-IDENTITY-EXACT: distinct roots stay distinct")
    }

    func testProjectIdentityBaseCheckoutPlusRealAndEmbeddedWorktreesEqual() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AS531Identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let base = root.appendingPathComponent("app", isDirectory: true)
        try fm.createDirectory(at: base.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)

        let worktree = root.appendingPathComponent("app-wt", isDirectory: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try writeText("gitdir: \(base.appendingPathComponent(".git/worktrees/wt1").path)\n",
                      to: worktree.appendingPathComponent(".git"))

        let baseSession = makeProjectIdentitySession(id: "ident-base", cwd: base.path)
        let worktreeSession = makeProjectIdentitySession(id: "ident-wt", cwd: worktree.path)
        let embeddedSession = makeProjectIdentitySession(
            id: "ident-emb",
            cwd: base.appendingPathComponent(".worktrees/feat").path
        )
        let baseIdentity = try XCTUnwrap(baseSession.rowProjectIdentity)
        XCTAssertEqual(try XCTUnwrap(worktreeSession.rowProjectIdentity), baseIdentity,
                       "real Git worktree resolves to the base checkout")
        XCTAssertEqual(try XCTUnwrap(embeddedSession.rowProjectIdentity), baseIdentity,
                       "embedded .worktrees path resolves to the base checkout")
    }

    func testProjectIdentityStructuralSeamRequiresDisplayAgreement() throws {
        let base = makeProjectIdentitySession(id: "struct-base", cwd: "/AS531-structural/app")
        let embedded = makeProjectIdentitySession(id: "struct-emb", cwd: "/AS531-structural/app/.worktrees/feat")
        let codexEmbedded = makeProjectIdentitySession(id: "struct-codex", cwd: "/AS531-structural/app/.codex/worktrees/feat")
        let claudeEmbedded = makeProjectIdentitySession(id: "struct-claude", cwd: "/AS531-structural/app/.claude/worktrees/feat")
        let baseIdentity = try XCTUnwrap(base.rowProjectIdentity)
        XCTAssertEqual(try XCTUnwrap(embedded.rowProjectIdentity), baseIdentity)
        XCTAssertEqual(try XCTUnwrap(codexEmbedded.rowProjectIdentity), baseIdentity)
        XCTAssertEqual(try XCTUnwrap(claudeEmbedded.rowProjectIdentity), baseIdentity)

        XCTAssertEqual(Session.structuralEmbeddedBaseRoot(forStandardizedPath: "/AS531-structural/app/.codex/worktrees/feat", displayName: "app"),
                       "/AS531-structural/app")
        XCTAssertEqual(Session.structuralEmbeddedBaseRoot(forStandardizedPath: "/AS531-structural/app/.claude/worktrees/feat", displayName: "app"),
                       "/AS531-structural/app")
        XCTAssertNil(Session.structuralEmbeddedBaseRoot(forStandardizedPath: "/AS531-structural/other/.worktrees/feat", displayName: "app"),
                    "base basename must agree with the resolved display project")
        XCTAssertNil(Session.structuralEmbeddedBaseRoot(forStandardizedPath: "/AS531-structural/app/.worktrees/feat", displayName: "other"))
    }

    func testProjectIdentityIgnoresOriginForIndependentClones() throws {
        let origin = sameOriginEvent()
        let one = makeProjectIdentitySession(id: "clone-one", cwd: "/AS531-clone/one/proj", events: [origin])
        let two = makeProjectIdentitySession(id: "clone-two", cwd: "/AS531-clone/two/proj", events: [origin])
        XCTAssertEqual(one.gitRepositoryURL, two.gitRepositoryURL, "fixture must share one origin")
        XCTAssertNotNil(one.gitRepositoryURL)
        let identityOne = try XCTUnwrap(one.rowProjectIdentity)
        let identityTwo = try XCTUnwrap(two.rowProjectIdentity)
        XCTAssertNotEqual(identityOne, identityTwo, "identity must not consult origin")
    }

    func testProjectIdentityNilForVirtualAndStoredLabelOnlyRows() throws {
        let codexChats = makeProjectIdentitySession(
            id: "virtual-codex",
            cwd: "/Users/test/Documents/Codex/2026-09-01/slug",
            codexSurface: .desktop
        )
        XCTAssertEqual(codexChats.rowRepoName, "Codex Desktop Chats")
        XCTAssertNil(codexChats.rowProjectIdentity)

        let claudeChats = makeProjectIdentitySession(
            id: "virtual-claude",
            source: .claude,
            cwd: "/sessions/peaceful-awesome-bohr",
            originator: "Claude Desktop"
        )
        XCTAssertEqual(claudeChats.rowRepoName, "Claude Desktop Chats")
        XCTAssertNil(claudeChats.rowProjectIdentity)

        let storedOnly = makeProjectIdentitySession(id: "stored-only", cwd: nil, repoName: "myproj")
        XCTAssertEqual(storedOnly.rowRepoName, "myproj")
        XCTAssertNil(storedOnly.rowProjectIdentity, "stored-label-only rows are unprovable")
    }

    func testSelectedProjectIdentityExcludesSimilarAndDifferentRootApps() throws {
        let app = makeProjectIdentitySession(id: "exact-app", cwd: "/AS531-fuzzy/main/app")
        let appServer = makeProjectIdentitySession(id: "exact-app-server", cwd: "/AS531-fuzzy/main/app-server")
        let mobileApp = makeProjectIdentitySession(id: "exact-mobile-app", cwd: "/AS531-fuzzy/main/mobile-app")
        let otherRootApp = makeProjectIdentitySession(id: "exact-other-app", cwd: "/AS531-fuzzy/other/app")
        let selected = try XCTUnwrap(app.rowProjectIdentity)
        for session in [appServer, mobileApp, otherRootApp] {
            XCTAssertNotEqual(try XCTUnwrap(session.rowProjectIdentity), selected)
        }
        let filtered = FilterEngine.filterSessions(
            [app, appServer, mobileApp, otherRootApp],
            filters: Filters(selectedProjectIdentity: selected),
            allowTranscriptGeneration: false
        )
        XCTAssertEqual(filtered.map(\.id), ["exact-app"])
    }

    func testRepoOperatorRemainsFuzzySubstring() throws {
        let app = makeProjectIdentitySession(id: "fuzzy-app", cwd: "/AS531-fuzzy/main/app")
        let appServer = makeProjectIdentitySession(id: "fuzzy-app-server", cwd: "/AS531-fuzzy/main/app-server")
        let mobileApp = makeProjectIdentitySession(id: "fuzzy-mobile-app", cwd: "/AS531-fuzzy/main/mobile-app")
        let otherRootApp = makeProjectIdentitySession(id: "fuzzy-other-app", cwd: "/AS531-fuzzy/other/app")
        let filtered = FilterEngine.filterSessions(
            [app, appServer, mobileApp, otherRootApp],
            filters: Filters(query: "repo:app"),
            allowTranscriptGeneration: false
        )
        XCTAssertEqual(filtered.map(\.id), ["fuzzy-app", "fuzzy-app-server", "fuzzy-mobile-app", "fuzzy-other-app"])
    }

    func testSelectedProjectIdentityComposesWithModelAndText() throws {
        let first = makeProjectIdentitySession(id: "compose-1", cwd: "/AS531-compose/app", model: "m1", title: "Fix login bug")
        let second = makeProjectIdentitySession(id: "compose-2", cwd: "/AS531-compose/app", model: "m2", title: "Fix login bug")
        let third = makeProjectIdentitySession(id: "compose-3", cwd: "/AS531-compose/app", model: "m1", title: "Update dashboard")
        let selected = try XCTUnwrap(first.rowProjectIdentity)
        let filtered = FilterEngine.filterSessions(
            [first, second, third],
            filters: Filters(query: "login", model: "m1", selectedProjectIdentity: selected),
            allowTranscriptGeneration: false
        )
        XCTAssertEqual(filtered.map(\.id), ["compose-1"])
    }

    func testSearchCoordinatorSelectedProjectSurvivesFTSLimitOne() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let unrelated = makeProjectIdentitySession(
            id: "a-unrelated",
            cwd: "/AS531-fts/other",
            title: "a unrelated",
            filePath: "/tmp/AS531-fts/a-unrelated.jsonl"
        )
        let selected = makeProjectIdentitySession(
            id: "b-selected",
            cwd: "/AS531-fts/selected",
            title: "b selected",
            filePath: "/tmp/AS531-fts/b-selected.jsonl"
        )
        let selectedIdentity = try XCTUnwrap(selected.rowProjectIdentity)
        XCTAssertNotEqual(try XCTUnwrap(unrelated.rowProjectIdentity), selectedIdentity)

        try await db.begin()
        for session in [unrelated, selected] {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "codex")
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: "codex", path: session.filePath, mtime: 10, size: 20,
                startTS: 1, endTS: 2, model: nil, cwd: session.cwd, repo: session.rowRepoName,
                title: nil, codexInternalSessionID: nil, isHousekeeping: false,
                messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            let text = session.id == unrelated.id ? "matchterm alpha" : "matchterm beta"
            try await db.upsertSessionSearch(sessionID: session.id, source: "codex",
                                             mtime: 10, size: 20, text: text)
        }
        try await db.commit()

        let firstPage = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "matchterm*", includeSystemProbes: true,
            limit: 1
        )
        XCTAssertEqual(firstPage, [unrelated.id], "fixture must rank the unrelated hit first")

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db, ftsResultLimitForTesting: 1)
        coordinator.start(query: "matchterm",
                          filters: Filters(query: "matchterm", selectedProjectIdentity: selectedIdentity),
                          allowed: [.codex],
                          enableDeepScan: false,
                          all: [unrelated, selected])
        try await waitForSearchResults(coordinator, expectedIDs: [selected.id])
    }

    func testSearchCoordinatorExactProjectDoesNotLeakSameIDFromAnotherSource() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let sharedID = "cross-source-project-collision"
        let codex = makeProjectIdentitySession(
            id: sharedID, source: .codex, cwd: "/AS531/collision/outside",
            title: "CollisionNeedle268", filePath: "/tmp/AS531/collision/codex.jsonl"
        )
        let claude = makeProjectIdentitySession(
            id: sharedID, source: .claude, cwd: "/AS531/collision/selected",
            title: "CollisionNeedle268", filePath: "/tmp/AS531/collision/claude.jsonl"
        )
        let selectedIdentity = try XCTUnwrap(claude.rowProjectIdentity)
        XCTAssertNotEqual(try XCTUnwrap(codex.rowProjectIdentity), selectedIdentity)

        // The persistent schema currently owns this bare id on the Codex side.
        // The live selected-project candidate is Claude and must not inherit the
        // Codex row's FTS eligibility merely because the ids collide.
        try await db.begin()
        try await db.upsertFile(path: codex.filePath, mtime: 10, size: 20, source: "codex")
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: codex.id, source: "codex", path: codex.filePath,
            mtime: 10, size: 20, startTS: 1, endTS: 2, model: nil,
            cwd: codex.cwd, repo: codex.rowRepoName, title: nil,
            codexInternalSessionID: nil, isHousekeeping: false, messages: 1,
            commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
        ))
        try await db.upsertSessionSearch(sessionID: codex.id, source: "codex",
                                         mtime: 10, size: 20, text: "CollisionNeedle268")
        try await db.commit()

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db)
        coordinator.start(query: "CollisionNeedle268",
                          filters: Filters(query: "CollisionNeedle268",
                                           selectedProjectIdentity: selectedIdentity),
                          allowed: [.codex, .claude], enableDeepScan: false,
                          all: [codex, claude],
                          effectiveDisplayTitles: [
                            SearchCoordinator.SessionKey(claude): "CollisionNeedle268"
                          ])
        for _ in 0..<50 {
            if coordinator.results.map(\.source) == [.claude] { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(coordinator.results.map(\.source), [.claude],
                       "exact project filtering must retain the selected Claude row and reject the colliding Codex owner")
    }

    func testProjectIdentityRejectsRelativeCwd() throws {
        XCTAssertNil(Session.canonicalProjectRoot(forCwd: "relative/app", displayName: "app"))
        XCTAssertNil(Session.canonicalProjectRoot(forCwd: "relative/app", displayName: nil))
        let session = makeProjectIdentitySession(id: "relative-cwd", cwd: "relative/app")
        XCTAssertNil(session.rowProjectIdentity, "a relative cwd resolves process-relative and proves nothing")
    }

    func testProjectSelectionUnambiguousHasNoDiscriminator() throws {
        let target = makeProjectIdentitySession(id: "sel-clean", cwd: "/AS531-sel/alpha/app")
        let other = makeProjectIdentitySession(id: "sel-other", cwd: "/AS531-sel/beta/other")
        let selection = try XCTUnwrap(ProjectSelection.makeSelection(for: target, among: [target, other]))
        XCTAssertEqual(selection.displayName, "app")
        XCTAssertNil(selection.disambiguationPath)
        XCTAssertEqual(selection.identity, try XCTUnwrap(target.rowProjectIdentity))
    }

    func testProjectSelectionDuplicateDisplayNameGetsDiscriminator() throws {
        let first = makeProjectIdentitySession(id: "sel-dup-a", cwd: "/AS531-seldup/alpha/app")
        let second = makeProjectIdentitySession(id: "sel-dup-b", cwd: "/AS531-seldup/beta/app")
        let selectionA = try XCTUnwrap(ProjectSelection.makeSelection(for: first, among: [first, second]))
        let selectionB = try XCTUnwrap(ProjectSelection.makeSelection(for: second, among: [first, second]))
        XCTAssertEqual(selectionA.displayName, "app")
        XCTAssertEqual(selectionB.displayName, "app")
        XCTAssertEqual(selectionA.disambiguationPath, "…/alpha")
        XCTAssertEqual(selectionB.disambiguationPath, "…/beta")
        XCTAssertNotEqual(selectionA, selectionB, "independent same-basename clones stay distinct")
    }

    func testProjectSelectionSameParentBasenameWidensToAncestors() throws {
        let first = makeProjectIdentitySession(id: "sel-anc-a", cwd: "/AS531-selanc/east/shared/app")
        let second = makeProjectIdentitySession(id: "sel-anc-b", cwd: "/AS531-selanc/west/shared/app")
        let selectionA = try XCTUnwrap(ProjectSelection.makeSelection(for: first, among: [first, second]))
        let selectionB = try XCTUnwrap(ProjectSelection.makeSelection(for: second, among: [first, second]))
        XCTAssertEqual(selectionA.displayName, "app")
        XCTAssertEqual(selectionB.displayName, "app")
        XCTAssertEqual(selectionA.disambiguationPath, "…/east/shared")
        XCTAssertEqual(selectionB.disambiguationPath, "…/west/shared")
        XCTAssertNotEqual(selectionA, selectionB, "matching parent basenames must still discriminate")
    }

    func testProjectSelectionNilForUnprovableRow() throws {
        let storedOnly = makeProjectIdentitySession(id: "sel-stored", cwd: nil, repoName: "myproj")
        XCTAssertNil(ProjectSelection.makeSelection(for: storedOnly, among: [storedOnly]))
        let relative = makeProjectIdentitySession(id: "sel-relative", cwd: "relative/app")
        XCTAssertNil(ProjectSelection.makeSelection(for: relative, among: [relative]))
    }

    func testSearchCoordinatorArchivedClaudeOnlySurvivesFTSLimitOne() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let archived = makeProjectIdentitySession(
            id: "b-archived-claude",
            source: .claude,
            cwd: "/AS531-arch/a",
            title: "b archived",
            filePath: "/tmp/AS531-arch/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jsonl"
        )
        let plain = makeProjectIdentitySession(
            id: "a-plain-claude",
            source: .claude,
            cwd: "/AS531-arch/b",
            title: "a plain",
            filePath: "/tmp/AS531-arch/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jsonl"
        )
        let archivedKey = try XCTUnwrap(archived.claudeArchiveJoinKey)

        try await db.begin()
        for session in [plain, archived] {
            try await db.upsertFile(path: session.filePath, mtime: 10, size: 20, source: "claude")
            try await db.upsertSessionMeta(SessionMetaRow(
                sessionID: session.id, source: "claude", path: session.filePath, mtime: 10, size: 20,
                startTS: 1, endTS: 2, model: nil, cwd: session.cwd, repo: session.rowRepoName,
                title: nil, codexInternalSessionID: nil, isHousekeeping: false,
                messages: 1, commands: 0, parentSessionID: nil, subagentType: nil, customTitle: nil
            ))
            let text = session.id == plain.id ? "matchterm alpha" : "matchterm beta"
            try await db.upsertSessionSearch(sessionID: session.id, source: "claude",
                                             mtime: 10, size: 20, text: text)
        }
        try await db.commit()

        let firstPage = try await db.searchSessionIDsFTS(
            sources: ["claude"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "matchterm*", includeSystemProbes: true,
            limit: 1
        )
        XCTAssertEqual(firstPage, [plain.id], "fixture must rank the non-archived hit first unscoped")

        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: db, ftsResultLimitForTesting: 1)
        coordinator.start(query: "matchterm",
                          filters: Filters(query: "matchterm",
                                           archivedClaudeDesktopOnly: true,
                                           archivedClaudeSessionIDs: [archivedKey]),
                          allowed: [.claude],
                          enableDeepScan: false,
                          all: [plain, archived])
        try await waitForSearchResults(coordinator, expectedIDs: [archived.id])
    }

    // MARK: - Search dataset membership refresh (canary AS531-DATASET-MEMBERSHIP-REFRESH)

    func testSearchDatasetMembershipDistinguishesSameIDAcrossSources() {
        let codex = makeRepoSession(id: "same-id", source: .codex, repoName: "r")
        let claude = makeRepoSession(id: "same-id", source: .claude, repoName: "r")
        let membership = UnifiedSessionIndexer.searchDatasetMembership(for: [codex, claude])
        XCTAssertEqual(membership.count, 2, "AS531-DATASET-MEMBERSHIP-REFRESH: same id across sources must differ")
        XCTAssertTrue(membership.contains(UnifiedSessionIndexer.SearchDatasetMembershipKey(source: .codex, id: "same-id")))
        XCTAssertTrue(membership.contains(UnifiedSessionIndexer.SearchDatasetMembershipKey(source: .claude, id: "same-id")))
    }

    func testSearchDatasetMembershipIgnoresReorderAndMetadataChange() {
        let a = makeRepoSession(id: "a", source: .codex, repoName: "r")
        let b = makeRepoSession(id: "b", source: .claude, repoName: "r")
        let base = UnifiedSessionIndexer.searchDatasetMembership(for: [a, b])
        let reordered = UnifiedSessionIndexer.searchDatasetMembership(for: [b, a])
        XCTAssertEqual(base, reordered, "AS531-DATASET-MEMBERSHIP-REFRESH: reorder must compare equal")
        let aMetadataChanged = Session(
            id: "a", source: .codex, startTime: nil, endTime: nil, model: "other",
            filePath: "/tmp/codex/a.jsonl", eventCount: 1,
            events: [SessionEvent(id: "e", timestamp: nil, kind: .user, role: "user", text: "hello",
                                  toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil,
                                  parentID: nil, isDelta: false, rawJSON: "{}")],
            cwd: "/tmp/other", repoName: "other", lightweightTitle: "Changed Title")
        let metadataChanged = UnifiedSessionIndexer.searchDatasetMembership(for: [aMetadataChanged, b])
        XCTAssertEqual(base, metadataChanged, "AS531-DATASET-MEMBERSHIP-REFRESH: metadata/hydration change must compare equal")
        XCTAssertNil(UnifiedSessionIndexer.advancedSearchDatasetMembershipRevision(from: base, to: reordered, current: 7))
        XCTAssertNil(UnifiedSessionIndexer.advancedSearchDatasetMembershipRevision(from: base, to: metadataChanged, current: 7))
    }

    func testSearchDatasetMembershipDetectsAdditionAndRemoval() {
        let a = makeRepoSession(id: "a", source: .codex, repoName: "r")
        let b = makeRepoSession(id: "b", source: .codex, repoName: "r")
        let base = UnifiedSessionIndexer.searchDatasetMembership(for: [a])
        let added = UnifiedSessionIndexer.searchDatasetMembership(for: [a, b])
        let removed = UnifiedSessionIndexer.searchDatasetMembership(for: [])
        XCTAssertNotEqual(base, added, "AS531-DATASET-MEMBERSHIP-REFRESH: addition must differ")
        XCTAssertNotEqual(base, removed, "AS531-DATASET-MEMBERSHIP-REFRESH: removal must differ")
        XCTAssertEqual(UnifiedSessionIndexer.advancedSearchDatasetMembershipRevision(from: base, to: added, current: 7), 8)
        XCTAssertEqual(UnifiedSessionIndexer.advancedSearchDatasetMembershipRevision(from: added, to: base, current: 8), 9)
    }

    @MainActor
    func testSearchDatasetRestartCoalescerCollapsesBurstToLatestAction() async throws {
        let coalescer = SearchDatasetRestartCoalescer()
        var publications: [Int] = []
        coalescer.schedule(after: 0.02) { publications.append(1) }
        coalescer.schedule(after: 0.02) { publications.append(2) }
        coalescer.schedule(after: 0.02) { publications.append(3) }

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(publications, [3],
                       "AS531-DATASET-MEMBERSHIP-REFRESH: one provider burst must restart search once")
    }

    private func makePreserveTitleSession(id: String, titleMarker: String) -> Session {
        Session(
            id: id, source: .codex, startTime: nil, endTime: nil, model: nil,
            filePath: "/tmp/codex/\(id).jsonl", eventCount: 0, events: [],
            cwd: "/tmp/repo", repoName: "repo", lightweightTitle: titleMarker, customTitle: titleMarker)
    }

    func testSearchCoordinatorPreserveTrueReplacesAfterRefresh() async throws {
        let old = makePreserveTitleSession(id: "preserve-old", titleMarker: "PreserveOldMarker417")
        let new = makePreserveTitleSession(id: "preserve-new", titleMarker: "PreserveNewMarker418")
        let all = [old, new]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: nil)
        coordinator.start(query: "PreserveOldMarker417",
                          filters: Filters(query: "PreserveOldMarker417"),
                          allowed: [.codex], enableDeepScan: false, all: all)
        try await waitForSearchResults(coordinator, expectedIDs: [old.id])
        coordinator.start(query: "PreserveNewMarker418",
                          filters: Filters(query: "PreserveNewMarker418"),
                          allowed: [.codex], enableDeepScan: false, all: all,
                          preserveResultsUntilRefreshPublishes: true)
        // The refresh must never flash old results away: poll until the new
        // hit arrives, failing if an empty intermediate is observed. On fast
        // machines the first observation may already be the new hit.
        for _ in 0..<50 {
            let ids = coordinator.results.map(\.id)
            if ids == [new.id] { break }
            if ids.isEmpty {
                XCTFail("AS531-DATASET-MEMBERSHIP-REFRESH: preserve true flashed old results before refresh published")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await waitForSearchResults(coordinator, expectedIDs: [new.id])
        XCTAssertEqual(coordinator.results.map(\.id), [new.id],
                       "AS531-DATASET-MEMBERSHIP-REFRESH: first publication must replace, not append")
    }

    func testSearchCoordinatorPreserveTrueZeroResultClearsOldResults() async throws {
        let old = makePreserveTitleSession(id: "preserve-zero-old", titleMarker: "PreserveZeroOld519")
        let other = makePreserveTitleSession(id: "preserve-zero-other", titleMarker: "UnrelatedTitle520")
        let all = [old, other]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: nil)
        coordinator.start(query: "PreserveZeroOld519",
                          filters: Filters(query: "PreserveZeroOld519"),
                          allowed: [.codex], enableDeepScan: false, all: all)
        try await waitForSearchResults(coordinator, expectedIDs: [old.id])
        // Let the first run reach idle so the second start is not racing a
        // still-scanning predecessor; waitForSearchResults can return on the
        // seed publication while the legacy tail is still running.
        for _ in 0..<50 {
            if !coordinator.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        coordinator.start(query: "NoSuchMarkerZzz999",
                          filters: Filters(query: "NoSuchMarkerZzz999"),
                          allowed: [.codex], enableDeepScan: false, all: all,
                          preserveResultsUntilRefreshPublishes: true)
        // Wait for the durable completed state rather than requiring a sample
        // of transient `isRunning == true`: this two-row search can start and
        // finish between polling intervals. The old result prevents a false
        // positive before the refresh has published.
        for _ in 0..<100 {
            if coordinator.results.isEmpty, !coordinator.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(coordinator.results.isEmpty,
                      "AS531-DATASET-MEMBERSHIP-REFRESH: zero-result refresh must clear preserved old rows")
        XCTAssertFalse(coordinator.isRunning)
    }

    func testSearchCoordinatorDefaultPreserveFalseClearsImmediately() async throws {
        let old = makePreserveTitleSession(id: "default-old", titleMarker: "DefaultOldMarker621")
        let new = makePreserveTitleSession(id: "default-new", titleMarker: "DefaultNewMarker622")
        let all = [old, new]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: nil)
        coordinator.start(query: "DefaultOldMarker621",
                          filters: Filters(query: "DefaultOldMarker621"),
                          allowed: [.codex], enableDeepScan: false, all: all)
        try await waitForSearchResults(coordinator, expectedIDs: [old.id])
        coordinator.start(query: "DefaultNewMarker622",
                          filters: Filters(query: "DefaultNewMarker622"),
                          allowed: [.codex], enableDeepScan: false, all: all)
        // Default (preserve false) retains the existing clear semantics: the
        // ordered initialization clears before the new run publishes. Poll for
        // the cleared or replaced state; the new hit must win without the old.
        try await waitForSearchResults(coordinator, expectedIDs: [new.id])
        XCTAssertEqual(coordinator.results.map(\.id), [new.id],
                       "AS531-DATASET-MEMBERSHIP-REFRESH: default must replace via clear-then-publish")
    }

    func testSearchCoordinatorStalePreservingRunCannotPublishOverNewer() async throws {
        // Best-effort ordering check on top of the existing runID guards: no
        // deterministic pause seam exists to hold run A mid-scan, so this
        // starts a preserving run immediately superseded by a newer run and
        // asserts the newer results win and stick. The authoritative guard is
        // the existing runID equality check on every publication.
        let a = makePreserveTitleSession(id: "stale-a", titleMarker: "StaleMarkerA723")
        let b = makePreserveTitleSession(id: "stale-b", titleMarker: "StaleMarkerB724")
        let all = [a, b]
        let coordinator = SearchCoordinator(store: SearchCoordinatorTestStore(), db: nil)
        coordinator.start(query: "StaleMarkerA723",
                          filters: Filters(query: "StaleMarkerA723"),
                          allowed: [.codex], enableDeepScan: false, all: all,
                          preserveResultsUntilRefreshPublishes: true)
        coordinator.start(query: "StaleMarkerB724",
                          filters: Filters(query: "StaleMarkerB724"),
                          allowed: [.codex], enableDeepScan: false, all: all,
                          preserveResultsUntilRefreshPublishes: true)
        try await waitForSearchResults(coordinator, expectedIDs: [b.id])
        let settled = coordinator.results.map(\.id)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(coordinator.results.map(\.id), settled,
                       "AS531-DATASET-MEMBERSHIP-REFRESH: superseded run must not publish after newer results")
        XCTAssertEqual(settled, [b.id])
    }
}
