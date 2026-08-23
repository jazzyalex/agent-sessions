import XCTest
import SQLite3
@testable import AgentSessions

/// Builds a miniature `sessions.db` matching the schema verified by
/// `scripts/devin_sessions_schema_probe.py` against 253 real sessions at CLI
/// 3000.3.27, then exercises the forest walk.
///
/// The fixture is constructed rather than copied because the real store is a
/// single 5.4 GB database containing every session on the machine; there is no
/// way to excerpt one session from it without rebuilding the schema anyway.
final class DevinSqliteReaderTests: XCTestCase {
    private var dbPath: String = ""

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("sessions.db").path
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try buildFixture()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Session `bald-ketch` is a five-node main chain with a two-node abandoned
    /// branch hanging off node 2 — the shape the real store is full of.
    ///
    ///     1 system → 2 user → 3 assistant(+tool_call) → 4 tool → 5 assistant
    ///                   └── 6 assistant (abandoned) → 7 tool (abandoned)
    private func buildFixture() throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
              hidden INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE message_nodes (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL,
              created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            """)

        try exec(db, """
            INSERT INTO sessions VALUES
              ('bald-ketch', '/tmp/as-agent-lab/devin/project', 'Windsurf', 'swe-1-7', 'bypass',
               1786004275, 1786004400, 'Fix the broken checks', 5, 0),
              ('hidden-otter', '/tmp/as-agent-lab/devin/other', 'Windsurf', 'glm-5-2', 'bypass',
               1786004000, 1786004100, 'Retired session', 1, 1);
            """)

        func node(_ id: Int, _ parent: String, _ json: String, _ time: Int) -> String {
            let escaped = json.replacingOccurrences(of: "'", with: "''")
            return "('bald-ketch', \(id), \(parent), '\(escaped)', \(time), NULL)"
        }

        let rows = [
            node(1, "NULL", #"{"message_id":"m1","role":"system","content":"You are Devin.","metadata":{}}"#, 1786004275),
            node(2, "1", #"{"message_id":"m2","role":"user","content":"Fix the broken checks.","metadata":{"is_user_input":true}}"#, 1786004280),
            node(3, "2", #"{"message_id":"m3","role":"assistant","content":"Reading the file.","thinking":{"signature":"sig","thinking":"I should read it first."},"tool_calls":[{"id":"call_1","index":0,"kind":"function","name":"read_file","arguments":{"path":"hello.py"}}],"metadata":{"num_tokens":42}}"#, 1786004290),
            node(4, "3", #"{"message_id":"m4","role":"tool","content":"print(\"hello\")","tool_call_id":"call_1","metadata":{}}"#, 1786004300),
            node(5, "4", #"{"message_id":"m5","role":"assistant","content":"It prints hello.","thinking":null,"tool_calls":[],"metadata":{}}"#, 1786004400),
            // abandoned branch off node 2
            node(6, "2", #"{"message_id":"m6","role":"assistant","content":"ABANDONED BRANCH","tool_calls":[],"metadata":{}}"#, 1786004285),
            node(7, "6", #"{"message_id":"m7","role":"tool","content":"ABANDONED RESULT","tool_call_id":"call_x","metadata":{}}"#, 1786004286),
            "('hidden-otter', 1, NULL, '{\"message_id\":\"h1\",\"role\":\"user\",\"content\":\"hi\",\"metadata\":{}}', 1786004000, NULL)",
        ]
        try exec(db, "INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at, metadata) VALUES "
                 + rows.joined(separator: ",") + ";")
    }

    // MARK: - List

    func testListSkipsHiddenSessions() {
        let sessions = DevinSqliteReader.listSessions(databasePath: dbPath)
        XCTAssertEqual(sessions.map(\.id), ["bald-ketch"])
    }

    func testListReadsIdentityFromSessionsTable() throws {
        let session = try XCTUnwrap(DevinSqliteReader.listSessions(databasePath: dbPath).first)
        XCTAssertEqual(session.source, .devin)
        XCTAssertEqual(session.model, "swe-1-7")
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-lab/devin/project")
        XCTAssertEqual(session.lightweightRepoName, "project")
        XCTAssertEqual(session.lightweightTitle, "Fix the broken checks")
        XCTAssertEqual(session.reasoningEffort, "bypass")
        // Devin stores epoch seconds, not milliseconds.
        XCTAssertEqual(session.startTime?.timeIntervalSince1970, 1786004275)
        XCTAssertEqual(session.endTime?.timeIntervalSince1970, 1786004400)
        // All sessions share the one database path.
        XCTAssertEqual(session.filePath, dbPath)
    }

    /// The list count must be the main chain, not `COUNT(*)`: the fixture has
    /// seven nodes but only five on the chain, and in the real store the gap is
    /// roughly eightfold.
    func testListCountsMainChainNotEveryNode() throws {
        let session = try XCTUnwrap(DevinSqliteReader.listSessions(databasePath: dbPath).first)
        XCTAssertEqual(session.eventCount, 5)
    }

    /// The load-bearing invariant: a session visible in the list must not vanish
    /// when it is opened. The list estimate is compared against the same filter
    /// input the full parse produces, so an estimate above the real non-meta
    /// count would hide the row mid-view.
    func testListEstimateNeverExceedsLoadedNonMetaCount() throws {
        let listed = try XCTUnwrap(DevinSqliteReader.listSessions(databasePath: dbPath).first)
        let loaded = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "bald-ketch"))
        let loadedNonMeta = loaded.events.filter { $0.kind != .meta }.count
        XCTAssertLessThanOrEqual(listed.eventCount, loadedNonMeta,
                                 "estimate \(listed.eventCount) > loaded \(loadedNonMeta): the row disappears on open")
        XCTAssertEqual(listed.eventCount, loadedNonMeta, "fixture should be exact, not merely bounded")
    }

    /// A chain of nothing but nodes that render as `.meta` must estimate zero.
    /// A plain node count would say three, so the row would show in the list and
    /// then vanish the moment it was opened.
    func testMetaOnlyChainEstimatesZeroNotNodeCount() throws {
        let path = try makeAuxiliaryDatabase(sessionID: "meta-only", mainChainID: 3, rows: """
              ('meta-only', 1, NULL, '{"role":"system","content":"You are Devin."}', 1),
              ('meta-only', 2, 1, '{"role":"assistant","content":"","tool_calls":[]}', 2),
              ('meta-only', 3, 2, '{"role":"toolbox","content":"unknown role"}', 3)
            """)
        let listed = try XCTUnwrap(DevinSqliteReader.listSessions(databasePath: path).first)
        let loaded = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: path, sessionID: "meta-only"))

        XCTAssertEqual(listed.eventCount, 0)
        XCTAssertEqual(loaded.events.filter { $0.kind != .meta }.count, 0)
        XCTAssertEqual(loaded.events.count, 3, "the nodes still render, they are just all meta")
    }

    /// `lightweightCommands` drives the has-commands filter for unopened
    /// sessions. While it was nil every unopened Devin session was treated as
    /// command-free and hidden by that filter.
    func testListReportsToolCallCountForUnopenedSessions() throws {
        let session = try XCTUnwrap(DevinSqliteReader.listSessions(databasePath: dbPath).first)
        XCTAssertEqual(session.lightweightCommands, 1)
        XCTAssertTrue(session.events.isEmpty, "still the lightweight pass")
        XCTAssertTrue(UnifiedSessionIndexer.passesHasCommandsFilter(session))
    }

    /// SQLite raises "malformed JSON" as a runtime error, not a NULL — so the
    /// JSON accounting in the counts query can fail the step on a single bad row.
    /// Unguarded, that trips the terminal-status check and reports the whole
    /// database as unreadable, which for an identity-backed source is the
    /// difference between "one broken turn" and "this agent has no sessions".
    func testMalformedChatMessageDoesNotMakeTheDatabaseUnreadable() throws {
        let path = try makeAuxiliaryDatabase(sessionID: "bad-json", mainChainID: 3, rows: """
              ('bad-json', 1, NULL, '{"role":"user","content":"real question"}', 1),
              ('bad-json', 2, 1, '{not json at all', 2),
              ('bad-json', 3, 2, '{"role":"assistant","content":"real answer"}', 3)
            """)

        let listed = try XCTUnwrap(DevinSqliteReader.listSessionsIfReadable(databasePath: path),
                                   "one malformed row must not retire the whole store")
        XCTAssertEqual(listed.count, 1)
        // user + assistant = 2; the malformed node renders as meta and counts 0.
        XCTAssertEqual(listed[0].eventCount, 2)

        let loaded = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: path, sessionID: "bad-json"))
        XCTAssertEqual(loaded.events.filter { $0.kind != .meta }.count, 2)
        XCTAssertLessThanOrEqual(listed[0].eventCount, loaded.events.filter { $0.kind != .meta }.count)
    }

    /// `main_chain_id` is nullable. Read as an int it becomes 0, which anchors
    /// the CTE at a node that cannot exist, so the session used to load as an
    /// empty transcript that looked like a parse failure.
    func testNullMainChainIDLoadsAnEmptySessionNotAFailure() throws {
        let path = try makeAuxiliaryDatabase(sessionID: "no-chain", mainChainID: nil, rows: """
              ('no-chain', 1, NULL, '{"role":"user","content":"orphaned"}', 1)
            """)
        let loaded = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: path, sessionID: "no-chain"),
                                   "a session with no live chain is empty, not unreadable")
        XCTAssertEqual(loaded.events.count, 0)
        XCTAssertEqual(loaded.eventCount, 0)
        XCTAssertEqual(loaded.lightweightTitle, "No chain")
    }

    /// Builds a second single-session database so a test can pick its own chain
    /// shape without disturbing the shared fixture.
    private func makeAuxiliaryDatabase(sessionID: String, mainChainID: Int?, rows: String) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-aux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sessions.db").path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 4) }
        defer { sqlite3_close(db) }
        try exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
              hidden INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE message_nodes (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL,
              created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            """)
        try exec(db, """
            INSERT INTO sessions VALUES
              ('\(sessionID)', '/tmp/x', 'Windsurf', 'swe-1-7', 'bypass', 1, 2,
               '\(mainChainID == nil ? "No chain" : "Chained")',
               \(mainChainID.map(String.init) ?? "NULL"), 0);
            """)
        try exec(db, "INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at) VALUES \(rows);")
        return path
    }

    // MARK: - Full session

    func testFullSessionRendersOnlyTheMainChain() throws {
        let session = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "bald-ketch"))
        let bodies = session.events.compactMap { $0.text ?? $0.toolOutput }
        XCTAssertFalse(bodies.contains { $0.contains("ABANDONED") },
                       "abandoned branch nodes must not be rendered")
    }

    func testFullSessionIsOrderedRootToTip() throws {
        let session = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "bald-ketch"))
        let kinds = session.events.map(\.kind)
        XCTAssertEqual(kinds.first, .meta)      // system
        XCTAssertEqual(session.events.first?.role, "system")
        let userIndex = try XCTUnwrap(kinds.firstIndex(of: .user))
        let resultIndex = try XCTUnwrap(kinds.firstIndex(of: .tool_result))
        XCTAssertLessThan(userIndex, resultIndex)
        let times = session.events.compactMap { $0.timestamp?.timeIntervalSince1970 }
        XCTAssertEqual(times, times.sorted(), "events must run oldest to newest")
    }

    /// One assistant node yields a thinking block, the reply, and each tool call.
    func testAssistantNodeExpandsIntoThinkingReplyAndCalls() throws {
        let session = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "bald-ketch"))

        let thinking = session.events.filter { $0.role == "thinking" }
        XCTAssertEqual(thinking.count, 1)
        XCTAssertEqual(thinking.first?.text, "[thinking] I should read it first.")

        let calls = session.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.toolName, "read_file")
        // `arguments` is a JSON object on the wire, serialised with sorted keys.
        XCTAssertEqual(calls.first?.toolInput, #"{"path":"hello.py"}"#)
        XCTAssertEqual(calls.first?.messageID, "call_1")
    }

    func testToolResultKeysBackToItsCall() throws {
        let session = try XCTUnwrap(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "bald-ketch"))
        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.messageID, "call_1")
        XCTAssertEqual(result.toolOutput, "print(\"hello\")")
    }

    func testUnknownSessionReturnsNil() {
        XCTAssertNil(DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: "no-such-session"))
    }

    func testMissingDatabaseYieldsEmptyList() {
        XCTAssertTrue(DevinSqliteReader.listSessions(databasePath: "/tmp/definitely-not-here.db").isEmpty)
    }

    // MARK: - The nil-versus-empty contract

    /// `nil` and `[]` are different answers and search ingest treats them
    /// differently: only a clean read may retire identities. Every other test
    /// here goes through `listSessions`, which collapses the two, so these are
    /// the only ones pinning the distinction.
    func testUnreadableDatabaseIsNilNotEmpty() {
        XCTAssertNil(DevinSqliteReader.listSessionsIfReadable(databasePath: "/tmp/definitely-not-here.db"))
    }

    func testReadableButEmptyDatabaseIsEmptyNotNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sessions.db").path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 2) }
        try exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
              hidden INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE message_nodes (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL,
              created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            """)
        sqlite3_close(db)

        let result = DevinSqliteReader.listSessionsIfReadable(databasePath: path)
        XCTAssertNotNil(result, "an empty store read cleanly is [] — nil would mean the read failed")
        XCTAssertEqual(result?.count, 0)
    }

    /// The scan skips a row with no usable id. It must also advance the cursor
    /// while doing so — a `continue` that leaves `sqlite3_step` un-advanced
    /// re-reads the same row forever. This test hangs rather than fails if that
    /// regresses.
    func testRowWithEmptyIDIsSkippedWithoutStalling() throws {
        try exec(openFixtureDB(), "INSERT INTO sessions VALUES ('', '/tmp/x', 'Windsurf', 'm', 'bypass', 1, 2, 'No id', NULL, 0);")

        let sessions = try XCTUnwrap(DevinSqliteReader.listSessionsIfReadable(databasePath: dbPath))
        XCTAssertEqual(sessions.map(\.id), ["bald-ketch"], "the id-less row is skipped, the real one still returned")
    }

    /// Reopens the fixture built in `setUpWithError` for a test that needs an
    /// extra row. Caller owns nothing; the file is removed by the teardown block.
    private func openFixtureDB() throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 3) }
        addTeardownBlock { sqlite3_close(db) }
        return db
    }

    // MARK: - Cycle safety

    /// `message_nodes` is a forest and nothing in the schema forbids a cycle, so
    /// both recursive CTEs carry a depth bound. Without it these calls spin
    /// `sqlite3_step` forever — this test hangs rather than fails if the bound
    /// is ever removed, which is why it runs against a deliberately cyclic store.
    func testCyclicParentChainTerminates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sessions.db").path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 2) }
        try exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
              hidden INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE message_nodes (
              row_id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
              node_id INTEGER NOT NULL, parent_node_id INTEGER, chat_message TEXT NOT NULL,
              created_at INTEGER NOT NULL, metadata TEXT, UNIQUE(session_id, node_id));
            INSERT INTO sessions VALUES
              ('loop-session', '/tmp/x', 'Windsurf', 'swe-1-7', 'bypass', 1, 2, 'Looping', 2, 0);
            """)
        // 1 <-> 2: walking parents from the tip never reaches a root.
        try exec(db, """
            INSERT INTO message_nodes (session_id, node_id, parent_node_id, chat_message, created_at) VALUES
              ('loop-session', 1, 2, '{"role":"user","content":"a"}', 1),
              ('loop-session', 2, 1, '{"role":"assistant","content":"b"}', 2);
            """)
        sqlite3_close(db)

        // Both entry points walk the chain; neither may hang.
        let listed = DevinSqliteReader.listSessionsIfReadable(databasePath: path)
        XCTAssertEqual(listed?.count, 1)

        let full = DevinSqliteReader.loadFullSession(databasePath: path, sessionID: "loop-session")
        XCTAssertNotNil(full)
    }
}
