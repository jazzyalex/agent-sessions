import XCTest
import SQLite3
@testable import AgentSessions

final class CursorSessionParserTests: XCTestCase {

    // MARK: - Helpers

    private func writeTempJSONL(_ lines: [String], dirName: String = "Users-test-Repository-TestProject", sessionUUID: String = "a1b2c3d4-e5f6-7890-abcd-ef1234567890") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionUUID, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("\(sessionUUID).jsonl")
        let content = lines.joined(separator: "\n")
        try content.data(using: .utf8)?.write(to: file)
        return file
    }

    private func writeTempSubagentJSONL(_ lines: [String], parentUUID: String = "a1b2c3d4-e5f6-7890-abcd-ef1234567890", subagentUUID: String = "d88b213c-84e1-427d-bb5e-3859c1011087") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("Users-test-Repository-TestProject", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("\(subagentUUID).jsonl")
        let content = lines.joined(separator: "\n")
        try content.data(using: .utf8)?.write(to: file)
        return file
    }

    private func cleanupTemp(_ url: URL) {
        // Walk up to the cursor_test_* directory and remove it
        var dir = url.deletingLastPathComponent()
        while !dir.lastPathComponent.hasPrefix("cursor_test_") && dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private var fixtureLines: [String] {
        [
            #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nrun ls command\n</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Running the ls command."},{"type":"tool_use","name":"Shell","input":{"command":"ls -la /tmp","description":"List dir"}}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Here are the results."}]}}"#,
            #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nnow show git status\n</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"[REDACTED]"},{"type":"tool_use","name":"Shell","input":{"command":"git status"}}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"The repo is clean."}]}}"#,
        ]
    }

    // MARK: - Lightweight Preview (parseFile)

    func testParseFileExtractsCorrectEventCount() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFile(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.source, .cursor)
        XCTAssertEqual(session.eventCount, 6, "should count all user + assistant lines")
        XCTAssertTrue(session.events.isEmpty, "lightweight parse should not populate events")
    }

    func testParseFileExtractsLightweightTitle() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFile(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.lightweightTitle, "run ls command", "should strip <user_query> tags")
    }

    func testParseFileCountsToolUseAsCommands() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFile(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.lightweightCommands, 2, "should count tool_use blocks")
    }

    func testParseFileExtractsSessionIDFromDirectoryUUID() throws {
        let uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let url = try writeTempJSONL(fixtureLines, sessionUUID: uuid)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFile(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.id, uuid)
    }

    func testParseFileReturnsNilForEmptyFile() throws {
        let url = try writeTempJSONL([])
        defer { cleanupTemp(url) }

        let session = CursorSessionParser.parseFile(at: url)
        XCTAssertNil(session, "empty file should return nil")
    }

    func testParseFileRejectsNonCursorFormat() throws {
        let lines = [
            #"{"type":"system","version":"1.0"}"#,
            #"{"type":"session_start","id":"s1","title":"Not Cursor"}"#,
            #"{"type":"message","text":"hello"}"#,
        ]
        let url = try writeTempJSONL(lines)
        defer { cleanupTemp(url) }

        let session = CursorSessionParser.parseFile(at: url)
        XCTAssertNil(session, "non-Cursor format with no role fields should return nil")
    }

    // MARK: - Full Parse (parseFileFull)

    func testParseFileFullExtractsAllEventTypes() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.source, .cursor)
        XCTAssertFalse(session.events.isEmpty)

        let userEvents = session.events.filter { $0.kind == .user }
        let assistantEvents = session.events.filter { $0.kind == .assistant }
        let toolCalls = session.events.filter { $0.kind == .tool_call }

        XCTAssertEqual(userEvents.count, 2, "should have 2 user messages")
        XCTAssertGreaterThanOrEqual(assistantEvents.count, 3, "should have assistant text events")
        XCTAssertEqual(toolCalls.count, 2, "should have 2 tool_use events")
    }

    func testParseFileFullStripsUserQueryTags() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        let firstUser = session.events.first(where: { $0.kind == .user })
        XCTAssertNotNil(firstUser)
        XCTAssertFalse(firstUser?.text?.contains("<user_query>") ?? true)
        XCTAssertEqual(firstUser?.text, "run ls command")
    }

    func testParseFileFullExtractsToolNameAndInput() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        let toolCall = session.events.first(where: { $0.kind == .tool_call })
        XCTAssertEqual(toolCall?.toolName, "Shell")
        XCTAssertTrue(toolCall?.toolInput?.contains("ls -la") ?? false)
    }

    func testParseFileFullPreservesRedactedMarkers() throws {
        let url = try writeTempJSONL(fixtureLines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        let redactedEvent = session.events.first(where: { $0.text?.contains("[REDACTED]") ?? false })
        XCTAssertNotNil(redactedEvent, "should preserve [REDACTED] markers")
    }

    func testParseFileFullHandlesMalformedLines() throws {
        let lines = [
            #"{"role":"user","message":{"content":[{"type":"text","text":"hello"}]}}"#,
            "not valid json at all",
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"world"}]}}"#,
        ]
        let url = try writeTempJSONL(lines)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertEqual(session.events.filter { $0.kind == .assistant }.count, 1)
    }

    // MARK: - Subagent Detection

    func testSubagentDetectionFromPath() throws {
        let lines = [
            #"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>\ndo something\n</user_query>"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#,
        ]
        let parentUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        let subUUID = "d88b213c-84e1-427d-bb5e-3859c1011087"
        let url = try writeTempSubagentJSONL(lines, parentUUID: parentUUID, subagentUUID: subUUID)
        defer { cleanupTemp(url) }

        guard let session = CursorSessionParser.parseFile(at: url) else { return XCTFail("parse returned nil") }
        XCTAssertEqual(session.parentSessionID, parentUUID)
        XCTAssertEqual(session.subagentType, "subagent")
        XCTAssertEqual(session.id, subUUID)
    }

    // MARK: - CWD Inference

    // CWD inference decides where a `-` is a path separator by asking the
    // filesystem, so every test here injects a `FakeFileProbe`. Asserting
    // against real directories would make these tests pass or fail on the
    // layout of whichever machine runs the suite.

    func testInferCWDResolvesSimplePath() {
        let probe = FakeFileProbe(directories: ["/tmp"])
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "tmp", fileProbe: probe)
        XCTAssertEqual(cwd, "/tmp")
    }

    func testInferCWDReturnsNilForNonexistentPath() {
        let probe = FakeFileProbe(directories: [])
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "nonexistent-path-that-does-not-exist-anywhere",
                                               fileProbe: probe)
        XCTAssertNil(cwd)
    }

    func testInferCWDPreservesHyphenatedComponents() {
        // A hyphenated leaf directory must survive as one component: the walk
        // commits `/Users/alexm/Repository`, then finds no `Codex` beneath it
        // and rejoins `Codex-History`.
        let probe = FakeFileProbe(directories: [
            "/Users",
            "/Users/alexm",
            "/Users/alexm/Repository",
            "/Users/alexm/Repository/Codex-History"
        ])
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "Users-alexm-Repository-Codex-History",
                                               fileProbe: probe)
        XCTAssertEqual(cwd, "/Users/alexm/Repository/Codex-History")
    }

    func testInferCWDSplitsOnDirectoriesThatDoExist() {
        // The mirror image: with `Codex` present as a real directory, the same
        // encoded name must decode to a deeper path instead.
        let probe = FakeFileProbe(directories: [
            "/Users",
            "/Users/alexm",
            "/Users/alexm/Repository",
            "/Users/alexm/Repository/Codex",
            "/Users/alexm/Repository/Codex/History"
        ])
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "Users-alexm-Repository-Codex-History",
                                               fileProbe: probe)
        XCTAssertEqual(cwd, "/Users/alexm/Repository/Codex/History")
    }

    func testInferCWDBestEffortReturnsDecodedPathWhenFinalDirectoryMissing() {
        let probe = FakeFileProbe.withDirectoryTree(upTo: "/Users/alexm/Repository")
        let projectName = "Users-alexm-Repository-This-Path-Should-Not-Exist-For-Tests"
        let decoded = CursorSessionParser.inferCWDBestEffort(fromProjectDirName: projectName, fileProbe: probe)
        XCTAssertEqual(decoded, "/Users/alexm/Repository/This-Path-Should-Not-Exist-For-Tests")
    }
}

// MARK: - CursorChatMetaReader Tests

final class CursorChatMetaReaderTests: XCTestCase {

    func testReadMetaFromFixtureDB() {
        let fixtureDB = FixturePaths.repoRootURL()
            .appendingPathComponent("AgentSessionsTests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("test-store.db")

        guard FileManager.default.fileExists(atPath: fixtureDB.path) else {
            XCTFail("Fixture DB not found at \(fixtureDB.path)")
            return
        }

        guard let meta = CursorChatMetaReader.sessionMeta(dbPath: fixtureDB.path) else {
            return XCTFail("sessionMeta returned nil")
        }

        XCTAssertEqual(meta.agentId, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        XCTAssertEqual(meta.name, "Test Session")
        XCTAssertEqual(meta.mode, "default")
        XCTAssertEqual(meta.lastUsedModel, "claude-4-sonnet")
        XCTAssertEqual(meta.createdAt.timeIntervalSince1970, 1775522590.321, accuracy: 0.01)
    }

    func testMD5HashMatchesKnownValue() {
        // Verified: md5("/Users/alexm/Repository/Codex-History") = "a540c72cf1054787d73d0121d2ecc391"
        let hash = CursorChatMetaReader.md5String("/Users/alexm/Repository/Codex-History")
        XCTAssertEqual(hash, "a540c72cf1054787d73d0121d2ecc391")
    }

    func testResolveWorkspacePathMatchesKnownHash() {
        let knownPaths = ["/Users/alexm/Repository/Codex-History", "/Users/alexm/Repository/Triada"]
        let resolved = CursorChatMetaReader.resolveWorkspacePath(hash: "a540c72cf1054787d73d0121d2ecc391", knownProjectDirs: knownPaths)
        XCTAssertEqual(resolved, "/Users/alexm/Repository/Codex-History")
    }

    func testResolveWorkspacePathReturnsNilForUnknownHash() {
        let resolved = CursorChatMetaReader.resolveWorkspacePath(hash: "0000000000000000000000000000000", knownProjectDirs: ["/Users/test"])
        XCTAssertNil(resolved)
    }
}

// MARK: - CursorSessionIndexer Tests

final class CursorSessionIndexerTests: XCTestCase {

    func testIsDBOnlySessionDetectsStoreDBPath() {
        let session = Session(
            id: "test-id",
            source: .cursor,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/Users/test/.cursor/chats/abc/def/store.db",
            fileSizeBytes: nil,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil
        )
        XCTAssertTrue(CursorSessionIndexer.isDBOnlySession(session))
    }

    func testIsDBOnlySessionReturnsFalseForJSONLPath() {
        let session = Session(
            id: "test-id",
            source: .cursor,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/Users/test/.cursor/projects/test/agent-transcripts/uuid/uuid.jsonl",
            fileSizeBytes: nil,
            eventCount: 5,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil
        )
        XCTAssertFalse(CursorSessionIndexer.isDBOnlySession(session))
    }

    func testIsDBOnlySessionReturnsFalseForOtherSource() {
        let session = Session(
            id: "test-id",
            source: .claude,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/some/path/store.db",
            fileSizeBytes: nil,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil
        )
        XCTAssertFalse(CursorSessionIndexer.isDBOnlySession(session))
    }

    func testACPStoreReaderParsesPersistedTurnGraphWithoutExposingOtherBlobs() throws {
        let sessionID = "8acca1dc-7b3c-4db1-a390-35773e7a1c8d"
        let root = Data(repeating: 1, count: 32)
        let turn = Data(repeating: 2, count: 32)
        let user = Data(repeating: 3, count: 32)
        let step = Data(repeating: 4, count: 32)
        let dbURL = try writeTempACPStore(sessionID: sessionID, blobs: [
            (root.hex, proto(field: 8, data: turn)),
            (turn.hex, proto(field: 1, data: proto(field: 1, data: user) + proto(field: 2, data: step))),
            (user.hex, proto(field: 1, data: Data("Please inspect this".utf8))),
            (step.hex, proto(field: 1, data: proto(field: 1, data: Data("I found the answer.".utf8)))),
            (Data(repeating: 9, count: 32).hex, Data("sensitive tool output".utf8))
        ], rootID: root.hex)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let session = try XCTUnwrap(CursorACPStoreReader.parse(at: dbURL))
        XCTAssertEqual(session.id, "cursor-acp:\(sessionID)")
        XCTAssertEqual(session.surface, .acp)
        XCTAssertEqual(session.events.map(\.text), ["Please inspect this", "I found the answer."])
        XCTAssertTrue(CursorSessionIndexer.isDBOnlySession(session))
        XCTAssertFalse(session.events.contains { $0.text?.contains("sensitive") == true })
    }

    func testACPStoreReaderRejectsUnknownSchemaVersion() throws {
        let sessionID = "8acca1dc-7b3c-4db1-a390-35773e7a1c8d"
        let root = Data(repeating: 1, count: 32)
        let dbURL = try writeTempACPStore(sessionID: sessionID,
                                           blobs: [(root.hex, Data())],
                                           rootID: root.hex,
                                           schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(CursorACPStoreReader.parse(at: dbURL))
    }

    func testACPStoreReaderRejectsIncompleteTurnGraph() throws {
        let sessionID = "8acca1dc-7b3c-4db1-a390-35773e7a1c8d"
        let root = Data(repeating: 1, count: 32)
        let missingTurn = Data(repeating: 2, count: 32)
        let dbURL = try writeTempACPStore(sessionID: sessionID,
                                           blobs: [(root.hex, proto(field: 8, data: missingTurn))],
                                           rootID: root.hex)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent().deletingLastPathComponent()) }
        XCTAssertNil(CursorACPStoreReader.parse(at: dbURL))
    }

    private func writeTempACPStore(sessionID: String, blobs: [(String, Data)], rootID: String, schemaVersion: Int = 1) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cursor_acp_test_\(UUID().uuidString)")
        let dbURL = root.appendingPathComponent("acp-sessions").appendingPathComponent(sessionID).appendingPathComponent("store.db")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);", nil, nil, nil), SQLITE_OK)
        let json = try JSONSerialization.data(withJSONObject: ["latestRootBlobId": rootID, "name": "ACP fixture", "createdAt": "2026-09-17T00:00:00Z"])
        try insert(db: db, table: "meta", id: "0", data: Data(json.hex.utf8))
        for (id, data) in blobs { try insert(db: db, table: "blobs", id: id, data: data) }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "cwd": "/tmp/acp-fixture"]).write(to: dbURL.deletingLastPathComponent().appendingPathComponent("meta.json"))
        return dbURL
    }

    private func insert(db: OpaquePointer?, table: String, id: String, data: Data) throws {
        var statement: OpaquePointer?
        let sql = table == "meta" ? "INSERT INTO meta (key, value) VALUES (?, ?)" : "INSERT INTO blobs (id, data) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "CursorACPTest", code: 1) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        let bindResult = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard bindResult == SQLITE_OK else { throw NSError(domain: "CursorACPTest", code: 3) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "CursorACPTest", code: 2) }
    }

    private func proto(field: UInt8, data: Data) -> Data {
        Data([field << 3 | 2, UInt8(data.count)]) + data
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
