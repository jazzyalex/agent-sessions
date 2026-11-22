import XCTest
import SQLite3
import CryptoKit
@testable import AgentSessions

/// Provider conformance against checked-in synthetic fixtures and small SQLite stores.
/// These scans exercise the public search path without consulting a user's corpus.
final class SearchScannerProviderConformanceTests: XCTestCase {
    private func stage0(_ path: String, file: StaticString = #filePath) -> URL {
        FixturePaths.stage0FixtureURL(path, file: file)
    }

    private func testFixture(_ path: String, file: StaticString = #filePath) -> URL {
        FixturePaths.repoRootURL(file: file)
            .appendingPathComponent("AgentSessionsTests/Resources/Fixtures/stage0", isDirectory: true)
            .appendingPathComponent(path)
    }

    private func makeDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func session(_ source: SessionSource, id: String, path: URL) -> Session {
        Session(id: id, source: source, startTime: nil, endTime: nil, model: nil,
                filePath: path.path, fileSizeBytes: 0, eventCount: 0, events: [],
                cwd: nil, repoName: nil, lightweightTitle: nil)
    }

    @discardableResult
    private func assertSearch(_ session: Session, query: String,
                              file: StaticString = #filePath, line: UInt = #line) async throws -> SearchScanResult {
        let tokenizer = try SearchTokenizer()
        let parsed = try SearchQuery(query, tokenizer: tokenizer)
        let result = await SearchSourceScanner.scan(session: session, query: parsed)
        XCTAssertTrue(result.summary.complete,
                      "\(session.source.rawValue) scan incomplete: \(result.summary.reasons)",
                      file: file, line: line)
        guard case .yes = result.truth else {
            XCTFail("\(session.source.rawValue) did not find \(query.debugDescription): \(result.truth)",
                    file: file, line: line)
            return result
        }
        guard let snippet = result.snippet else {
            XCTFail("\(session.source.rawValue) hit has no snippet", file: file, line: line)
            return result
        }
        XCTAssertFalse(snippet.isEmpty, file: file, line: line)
        XCTAssertLessThanOrEqual(snippet.utf16.count, 512, file: file, line: line)
        return result
    }

    private func writeJSONL(_ records: [[String: Any]], to url: URL) throws {
        let data = try records.reduce(into: Data()) { result, record in
            result.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            result.append(10)
        }
        try data.write(to: url, options: .atomic)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "SearchScannerProviderFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "SearchScannerProviderFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func sql(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func testCodexPlainAndCompressedRollouts() async throws {
        let plain = session(.codex, id: "codex-plain",
                            path: stage0("agents/codex/small.jsonl"))
        try await assertSearch(plain, query: "files")

        let directory = try makeDirectory("search-codex-zstd")
        let canonical = directory.appendingPathComponent("rollout-fixture.jsonl")
        let compressed = URL(fileURLWithPath: canonical.path + ".zst")
        try FileManager.default.copyItem(at: testFixture("agents/codex/small.jsonl.zst"), to: compressed)
        try await assertSearch(session(.codex, id: "codex-compressed", path: canonical), query: "files")
    }

    func testClaudeSyntheticJSONL() async throws {
        let directory = try makeDirectory("search-claude")
        let path = directory.appendingPathComponent("session.jsonl")
        try writeJSONL([
            ["type": "user", "message": ["role": "user", "content": "claude amber" ]],
            ["type": "assistant", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Claude fixture response." ]
            ]]]
        ], to: path)
        try await assertSearch(session(.claude, id: "claude-search-fixture", path: path), query: "amber")
    }

    func testAntigravityFixture() async throws {
        try await assertSearch(session(.antigravity, id: "antigravity-stage0",
                                       path: stage0("agents/antigravity/cli_small.jsonl")), query: "a.txt")
    }

    func testCopilotFixture() async throws {
        try await assertSearch(session(.copilot, id: "copilot_stage0_small",
                                       path: stage0("agents/copilot/small.jsonl")), query: "a.txt")
    }

    func testBalancedMalformedFallbackRecordPreventsVerifiedAbsence() async throws {
        let directory = try makeDirectory("search-malformed-droid")
        let url = directory.appendingPathComponent("session.jsonl")
        var data = try Data(contentsOf: stage0("agents/droid/session_store_small.jsonl"))
        data.append(Data("\n{\"type\": }\n".utf8))
        try data.write(to: url)
        let input = session(.droid, id: "droid_s1", path: url)
        let tokenizer = try SearchTokenizer()
        let query = try SearchQuery("NOT unseenword", tokenizer: tokenizer)
        let result = await SearchSourceScanner.scan(session: input, query: query)
        XCTAssertFalse(result.summary.complete)
        XCTAssertTrue(result.summary.reasons.contains(.malformedRecord))
        XCTAssertEqual(result.truth, .unknown)
    }

    func testDroidFixture() async throws {
        try await assertSearch(session(.droid, id: "droid_s1",
                                       path: stage0("agents/droid/session_store_small.jsonl")), query: "command")
    }

    func testCursorJSONLFixture() async throws {
        try await assertSearch(session(.cursor, id: "cursor-stage0",
                                       path: stage0("agents/cursor/small.jsonl")), query: "files")
    }

    func testPiFixture() async throws {
        try await assertSearch(session(.pi, id: "019e19b4-eb48-746a-aa6b-8dfcfa37954b",
                                       path: stage0("agents/pi/small.jsonl")), query: "greeting")
    }

    func testKimiFixture() async throws {
        let directory = try makeDirectory("search-kimi")
        let sessionID = "session_1bcbe023-4f7e-4971-9dc9-43b8756045b0"
        let wire = directory.appendingPathComponent("sessions/project/\(sessionID)/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stage0("agents/kimi/assistant_tools.jsonl"), to: wire)
        try FileManager.default.copyItem(at: stage0("agents/kimi/assistant_tools.state.json"),
                                         to: wire.deletingLastPathComponent().deletingLastPathComponent()
                                            .deletingLastPathComponent().appendingPathComponent("state.json"))
        try await assertSearch(session(.kimi, id: sessionID, path: wire), query: "Kimi Code")
    }

    func testGrokFixtureAndCompanions() async throws {
        try await assertSearch(session(.grok, id: "grok-stage0",
                                       path: stage0("agents/grok/chat_history.jsonl")),
                               query: "\"hello from the grok fixture\"")
    }

    func testQwenFixture() async throws {
        try await assertSearch(session(.qwen, id: "019f0000-0000-7000-8000-000000000001",
                                       path: stage0("agents/qwen/019f0000-0000-7000-8000-000000000001.jsonl")),
                               query: "valid")
    }

    func testFxSchema4FixtureAndArtifacts() async throws {
        try await assertSearch(session(.fx, id: "schema4",
                                       path: stage0("agents/fx/schema4/events.jsonl")), query: "README")
    }

    func testClineManifestAndMessagesCompanion() async throws {
        let manifest = stage0("agents/cline/cli_tool/cline-cli-tool.json")
        try await assertSearch(session(.cline, id: "cline-cli-tool", path: manifest),
                               query: "\"fixture line one\"")
    }

    func testDeepSeekHarnessV4Fixture() async throws {
        let directory = try makeDirectory("search-dsh")
        let fixture = testFixture("agents/deepseek-harness/v4_tool_session.jsonl")
        let path = DeepSeekHarnessDiscovery.canonicalGenerationURL(
            root: directory, cwd: "/tmp/search-dsh", id: "dsh-search-fixture",
            version: 4, compression: .plain)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: path)
        try await assertSearch(session(.deepseekHarness, id: "dsh-search-fixture", path: path), query: "response")
    }

    func testOpenCodeV1Database() async throws {
        let directory = try makeDirectory("search-opencode-v1")
        let path = directory.appendingPathComponent("opencode.db")
        let id = "ses_search_v1"
        try execute("""
            CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('\(id)', 1000);
            INSERT INTO message VALUES ('msg_v1', '\(id)', 1000, 1000, '{"role":"user","time":{"created":1000}}');
            INSERT INTO part VALUES ('part_v1', 'msg_v1', '\(id)', 1000, 1000, '{"type":"text","text":"opencode v1 quartz"}');
            """, at: path)
        try await assertSearch(session(.opencode, id: id, path: path), query: "quartz")
    }

    func testOpenCodeV2Database() async throws {
        let directory = try makeDirectory("search-opencode-v2")
        let path = directory.appendingPathComponent("opencode.db")
        let id = "ses_search_v2"
        try execute("""
            CREATE TABLE session_v2 (id TEXT PRIMARY KEY, time_updated INTEGER);
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER,
                time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session_v2 VALUES ('\(id)', 2000);
            INSERT INTO session_message VALUES ('msg_v2', '\(id)', 'user', 0, 2000, 2000,
                '{"time":{"created":2000},"text":"opencode v2 quartz","files":[],"agents":[]}');
            """, at: path)
        try await assertSearch(session(.opencode, id: id, path: path), query: "quartz")
    }

    func testOpenCodeMigrationSkipsCurrentSessionInSameDatabase() async throws {
        let directory = try makeDirectory("search-opencode-mixed-formats")
        let path = directory.appendingPathComponent("opencode.db")
        try execute("""
            CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_current', 1000), ('ses_pending', 1000);
            """, at: path)
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let refs = ["ses_current", "ses_pending"].map {
            SearchIngestService.FileRef(path: path.path, mtime: 1, size: 10, sessionID: $0,
                                        contentRevision: .init(updatedMillis: 1000, extent: 0))
        }
        let identitySnapshot = SearchIngestService.IdentitySnapshot(
            storagePaths: [path.path], sessionIDs: ["ses_current", "ses_pending"])
        let service = SearchIngestService(db: db)
        let first = try await service.ingest(source: .opencode, files: refs, toolIOEnabled: false,
                                             identitySnapshot: identitySnapshot, yieldNanoseconds: 0)
        XCTAssertEqual(first.processed, 2)

        try await db.upsertSessionSearch(sessionID: "ses_pending", source: "opencode",
                                         mtime: 1000, size: 0, text: "old format",
                                         formatVersion: FeatureFlags.sessionSearchFormatVersion - 1)
        let second = try await service.ingest(source: .opencode, files: refs, toolIOEnabled: false,
                                              identitySnapshot: identitySnapshot, yieldNanoseconds: 0)
        XCTAssertEqual(second.processed, 1)
        XCTAssertEqual(second.skipped, 1)
        let states = try await db.sessionSearchIdentityStatesByID(for: "opencode")
        XCTAssertEqual(Set(states.keys), identitySnapshot.sessionIDs)
    }

    func testHermesStateDatabase() async throws {
        let directory = try makeDirectory("search-hermes")
        let path = directory.appendingPathComponent("state.db")
        let id = "hermes_search_fixture"
        try execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY);
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT,
                tool_calls TEXT, tool_name TEXT, timestamp REAL, finish_reason TEXT, reasoning TEXT,
                reasoning_content TEXT, codex_reasoning_items TEXT);
            INSERT INTO sessions VALUES ('\(id)');
            INSERT INTO messages (id, session_id, role, content, timestamp)
                VALUES (1, '\(id)', 'user', 'hermes quartz', 1780000000.0);
            """, at: path)
        try await assertSearch(session(.hermes, id: id, path: path), query: "quartz")
    }

    func testHermesBalancedInvalidToolCallsPreventVerifiedAbsence() async throws {
        let directory = try makeDirectory("search-hermes-malformed-tools")
        let path = directory.appendingPathComponent("state.db")
        let id = "hermes_malformed_tools_fixture"
        try execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY);
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, tool_call_id TEXT,
                tool_calls TEXT, tool_name TEXT, timestamp REAL, finish_reason TEXT, reasoning TEXT,
                reasoning_content TEXT, codex_reasoning_items TEXT);
            INSERT INTO sessions VALUES ('\(id)');
            INSERT INTO messages (id, session_id, role, content, tool_calls, timestamp)
                VALUES (1, '\(id)', 'assistant', 'hermes response', '[{"id":"call-1",}]', 1780000000.0);
            """, at: path)

        let tokenizer = try SearchTokenizer()
        let query = try SearchQuery("NOT absenthermesword", tokenizer: tokenizer)
        let result = await SearchSourceScanner.scan(session: session(.hermes, id: id, path: path), query: query)

        XCTAssertFalse(result.summary.complete)
        XCTAssertTrue(result.summary.reasons.contains(.malformedRecord))
        XCTAssertEqual(result.truth, .unknown)
    }

    func testDevinSessionDatabase() async throws {
        let directory = try makeDirectory("search-devin")
        let path = directory.appendingPathComponent("sessions.db")
        let id = "devin_search_fixture"
        let message = #"{"message_id":"m1","role":"user","content":"devin quartz","metadata":{"is_user_input":true}}"#
        try execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, main_chain_id INTEGER);
            CREATE TABLE message_nodes (session_id TEXT, node_id INTEGER, parent_node_id INTEGER,
                chat_message TEXT, created_at INTEGER);
            INSERT INTO sessions VALUES ('\(id)', 1);
            INSERT INTO message_nodes VALUES ('\(id)', 1, NULL, \(sql(message)), 1780000000);
            """, at: path)
        try await assertSearch(session(.devin, id: id, path: path), query: "quartz")
    }

    func testOpenClawCurrentSQLiteFixture() async throws {
        let directory = try makeDirectory("search-openclaw")
        let path = directory.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let schema = try String(contentsOf: stage0("agents/openclaw/sqlite/openclaw-agent.sql"), encoding: .utf8)
        try execute(schema, at: path)
        let listed = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: path))
        let selected = try XCTUnwrap(listed.first { $0.id == "openclaw:main:openclaw-fixture-migrated" })
        try await assertSearch(selected, query: "\"fixture-file-07.txt\"")
    }

    func testCursorACPStoreAndJSONL() async throws {
        try await assertSearch(session(.cursor, id: "cursor-jsonl",
                                       path: stage0("agents/cursor/small.jsonl")), query: "files")
        let acp = try makeCursorACPStore(assistantText: "cursor ACP quartz")
        try await assertSearch(acp, query: "quartz")
    }

    func testCursorACPOmittedShellAndToolStepMakeNegativeUnknown() async throws {
        for shape in [CursorACPShape.shellTurn, .toolStep] {
            let acp = try makeCursorACPStore(assistantText: "cursor visible text", shape: shape)
            let tokenizer = try SearchTokenizer()
            let query = try SearchQuery("NOT absentcursorword", tokenizer: tokenizer)
            let result = await SearchSourceScanner.scan(session: acp, query: query)

            XCTAssertFalse(result.summary.complete)
            XCTAssertTrue(result.summary.reasons.contains(.omittedRecord))
            XCTAssertEqual(result.truth, .unknown)
        }
    }

    func testCursorACPRepeatedTurnAndStepReferencesRespectExpansionBudget() async throws {
        let acp = try makeCursorACPStore(assistantText: "cursor visible text",
                                        repeatedTurns: 12_000,
                                        repeatedSteps: 2)
        let tokenizer = try SearchTokenizer()
        let query = try SearchQuery("NOT absentcursorword", tokenizer: tokenizer)
        let result = await SearchSourceScanner.scan(session: acp, query: query)

        XCTAssertFalse(result.summary.complete)
        XCTAssertTrue(result.summary.reasons.contains(.resourceLimit))
        XCTAssertEqual(result.truth, .unknown)
    }

    private enum CursorACPShape {
        case assistant
        case shellTurn
        case toolStep
    }

    private func makeCursorACPStore(assistantText: String,
                                    shape: CursorACPShape = .assistant,
                                    repeatedTurns: Int = 1,
                                    repeatedSteps: Int = 1) throws -> Session {
        let temp = NSTemporaryDirectory()
        let canonicalTemp = temp.hasPrefix("/var/") ? "/private\(temp)" : temp
        let root = URL(fileURLWithPath: canonicalTemp, isDirectory: true)
            .appendingPathComponent("search-cursor-acp-\(UUID().uuidString)", isDirectory: true)
        let id = UUID().uuidString.lowercased()
        let sessionDirectory = root.appendingPathComponent("acp-sessions/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storeURL = sessionDirectory.appendingPathComponent("store.db")
        let user = proto(1, Data("cursor ACP user".utf8))
        let assistant = proto(1, Data(assistantText.utf8))
        let userID = contentID(user)
        let assistantID = contentID(assistant)
        let step: Data
        switch shape {
        case .assistant, .shellTurn:
            step = proto(1, assistantID)
        case .toolStep:
            step = proto(2, Data("write_file".utf8))
        }
        let stepID = contentID(step)
        let turn: Data
        if case .shellTurn = shape {
            turn = proto(2, proto(1, Data("shell command".utf8)))
        } else {
            var agentTurn = proto(1, userID)
            for _ in 0..<max(1, repeatedSteps) { agentTurn.append(proto(2, stepID)) }
            turn = proto(1, agentTurn)
        }
        let turnID = contentID(turn)
        var rootData = Data()
        for _ in 0..<max(1, repeatedTurns) { rootData.append(proto(8, turnID)) }
        let rootID = contentID(rootData)
        let rootJSON = try JSONSerialization.data(withJSONObject: [
            "latestRootBlobId": hex(rootID),
            "agentId": id,
            "createdAt": 1_700_000_000,
            "name": "Search ACP fixture"
        ], options: [.sortedKeys])
        let rootHex = rootJSON.map { String(format: "%02x", $0) }.joined()
        let metadata = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "agentId": id])
        try metadata.write(to: sessionDirectory.appendingPathComponent("meta.json"), options: .atomic)

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "SearchCursorACPFixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let schema = "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);"
        guard sqlite3_exec(db, schema, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "SearchCursorACPFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var metaStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES ('0', ?)", -1, &metaStatement, nil) == SQLITE_OK,
              let metaStatement else { throw NSError(domain: "SearchCursorACPFixture", code: 3) }
        defer { sqlite3_finalize(metaStatement) }
        sqlite3_bind_text(metaStatement, 1, rootHex, -1, transient)
        guard sqlite3_step(metaStatement) == SQLITE_DONE else { throw NSError(domain: "SearchCursorACPFixture", code: 4) }

        let blobs: [(String, Data)] = [
            (hex(rootID), rootData), (hex(turnID), turn), (hex(stepID), step),
            (hex(userID), user), (hex(assistantID), assistant)
        ]
        for (blobID, data) in blobs {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO blobs (id, data) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw NSError(domain: "SearchCursorACPFixture", code: 5) }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, blobID, -1, transient)
            let bindResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), transient)
            }
            guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "SearchCursorACPFixture", code: 6)
            }
        }
        return session(.cursor, id: "cursor-acp:\(id)", path: storeURL)
    }

    private func proto(_ field: UInt8, _ data: Data) -> Data {
        var length = data.count
        var encoded: [UInt8] = []
        repeat {
            var byte = UInt8(length & 0x7f)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            encoded.append(byte)
        } while length > 0
        return Data([field << 3 | 2] + encoded) + data
    }

    private func contentID(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
