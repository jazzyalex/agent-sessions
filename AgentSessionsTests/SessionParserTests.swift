import XCTest
import SQLite3
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
            total_tokens INTEGER,
            cost REAL,
            title TEXT
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

        let modelConfig = #"{"cwd":"/tmp/hermes-repo"}"#
        let toolCalls = #"[{"id":"call_hermes_1","type":"function","function":{"name":"shell","arguments":"{\"cmd\":\"pwd\"}"}}]"#
        try exec("""
        INSERT INTO sessions (id, source, user_id, model, model_config, system_prompt, parent_session_id, started_at, ended_at, end_reason, message_count, tool_call_count, input_tokens, output_tokens, total_tokens, cost, title)
        VALUES ('hermes_sqlite_demo', 'cli', 'user_1', 'qwen3.5-9b', \(sqlString(modelConfig)), 'system', NULL, 1780000000.0, 1780000004.0, 'complete', 3, 1, 10, 20, 30, 0.01, 'Hermes SQLite demo');
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (1, 'hermes_sqlite_demo', 'user', 'Hello from Hermes SQLite', NULL, NULL, NULL, 1780000000.1, 4, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (2, 'hermes_sqlite_demo', 'assistant', 'Running pwd.', NULL, \(sqlString(toolCalls)), NULL, 1780000001.0, 8, NULL, 'brief reasoning', NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (3, 'hermes_sqlite_demo', 'tool', '/tmp/hermes-repo', 'call_hermes_1', NULL, 'shell', 1780000002.0, 3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_calls, tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_content, reasoning_details, codex_reasoning_items, codex_message_items, platform_message_id, observed)
        VALUES (4, 'hermes_sqlite_demo', 'session_meta', NULL, NULL, NULL, NULL, 1780000003.0, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1);
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
                          includeCodex: true,
                          includeClaude: false,
                          includeAntigravity: false,
                          includeOpenCode: false,
                          includeHermes: false,
                          includeCopilot: false,
                          includeDroid: false,
                          includeOpenClaw: false,
                          includeCursor: false,
                          includePi: false,
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
                          includeCodex: true,
                          includeClaude: false,
                          includeAntigravity: false,
                          includeOpenCode: false,
                          includeHermes: false,
                          includeCopilot: false,
                          includeDroid: false,
                          includeOpenClaw: false,
                          includeCursor: false,
                          includePi: false,
                          enableDeepScan: false,
                          all: [root, sideChat])

        try await waitForSearchResults(coordinator, expectedIDs: ["side-chat"])
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(store.parseFullCallCount, 0)
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
        let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Origin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

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
        XCTAssertEqual(full.eventCount, 4)
        XCTAssertEqual(full.customTitle, "Hermes SQLite demo")
        XCTAssertTrue(full.events.contains { $0.kind == .user && ($0.text ?? "").contains("Hello from Hermes SQLite") })
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("Running pwd.") })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "shell" && $0.messageID == "call_hermes_1" })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result && $0.toolName == "shell" && ($0.toolOutput ?? "").contains("/tmp/hermes-repo") })
        XCTAssertTrue(full.events.contains { $0.kind == .meta && ($0.text ?? "").contains("brief reasoning") })
        let sessionMeta = try XCTUnwrap(full.events.first { $0.kind == .meta && $0.role == "session_meta" })
        XCTAssertNil(sessionMeta.text)
        XCTAssertFalse(sessionMeta.rawJSON.isEmpty)
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
}
