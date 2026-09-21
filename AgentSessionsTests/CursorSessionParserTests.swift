import XCTest
import CryptoKit
import SQLite3
import Darwin
import Combine
@testable import AgentSessions

final class CursorSessionParserTests: XCTestCase {

    // MARK: - Helpers

    private let acpSessionID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

    private func acpBlobID(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func proto(_ field: UInt8, _ data: Data) -> Data {
        var length = data.count
        var encodedLength: [UInt8] = []
        repeat {
            var byte = UInt8(length & 0x7f)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            encodedLength.append(byte)
        } while length > 0
        return Data([field << 3 | 2] + encodedLength) + data
    }

    private func contentID(for data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func writeTempACPStore(
        sessionID: String = "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        schemaVersion: Int = 1,
        blobs: [String: Data]? = nil,
        rootBlobID: String? = nil,
        rootAgentID: String? = nil,
        assistantText: String = "hello from assistant",
        stepMessages: [Data]? = nil,
        turnMessages: [Data]? = nil,
        enableWAL: Bool = false
    ) throws -> URL {
        let tempPath = NSTemporaryDirectory()
        let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
        let base = URL(fileURLWithPath: canonicalTempPath)
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
        let sessionDir = base
            .appendingPathComponent("acp-sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let userData = proto(1, Data("hello from user".utf8))
        let userID = contentID(for: userData)
        let assistantData = proto(1, Data(assistantText.utf8))
        let assistantID = contentID(for: assistantData)
        let steps = stepMessages ?? [proto(1, assistantID)]
        let stepIDs = steps.map(contentID(for:))
        let defaultTurnData = proto(1, proto(1, userID) + stepIDs.reduce(into: Data()) { partial, stepID in
            partial.append(proto(2, stepID))
        })
        let turns = turnMessages ?? [defaultTurnData]
        let turnIDs = turns.map(contentID(for:))
        let rootData = turnIDs.reduce(into: Data()) { partial, turnID in
            partial.append(proto(8, turnID))
        }
        let rootID = contentID(for: rootData)
        var defaultBlobs: [String: Data] = [
            rootID.hexString: rootData,
            userID.hexString: userData,
            assistantID.hexString: assistantData
        ]
        for (stepID, stepData) in zip(stepIDs, steps) {
            defaultBlobs[stepID.hexString] = stepData
        }
        for (turnID, turnData) in zip(turnIDs, turns) {
            defaultBlobs[turnID.hexString] = turnData
        }

        let storeURL = sessionDir.appendingPathComponent("store.db", isDirectory: false)
        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw NSError(domain: "CursorSessionParserTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not open fixture database"])
        }
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: storeURL.path + "-shm")
        var walSnapshot: Data?
        defer {
            sqlite3_close(db)
            if let walSnapshot {
                try? walSnapshot.write(to: walURL, options: .atomic)
                try? FileManager.default.removeItem(at: shmURL)
            }
        }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let schema = "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);"
        guard sqlite3_exec(db, schema, nil, nil, &errorMessage) == SQLITE_OK else {
            throw NSError(domain: "CursorSessionParserTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not create fixture schema"])
        }
        if enableWAL {
            guard sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, &errorMessage) == SQLITE_OK else {
                throw NSError(domain: "CursorSessionParserTests", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "could not enable WAL mode"])
            }
            guard sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0;", nil, nil, &errorMessage) == SQLITE_OK else {
                throw NSError(domain: "CursorSessionParserTests", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "could not disable WAL autocheckpoint"])
            }
        }

        let rootJSON = try JSONSerialization.data(withJSONObject: [
            "latestRootBlobId": rootBlobID ?? rootID.hexString,
            "agentId": rootAgentID ?? sessionID,
            "createdAt": 1_700_000_000,
            "name": "ACP fixture"
        ])
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func insertMeta(_ key: String, _ value: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "CursorSessionParserTests", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "CursorSessionParserTests", code: 4)
            }
        }
        func insertBlob(_ id: String, _ data: Data) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO blobs (id, data) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "CursorSessionParserTests", code: 5)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, transient)
            let result = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 2, rawBuffer.baseAddress, Int32(data.count), transient)
            }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
                throw NSError(domain: "CursorSessionParserTests", code: 6)
            }
        }

        try insertMeta("0", rootJSON.hexString)
        for (id, data) in blobs ?? defaultBlobs {
            try insertBlob(id, data)
        }

        if enableWAL {
            guard let data = try? Data(contentsOf: walURL), data.count > 32 else {
                throw NSError(domain: "CursorSessionParserTests", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "fixture did not produce a non-empty WAL"])
            }
            walSnapshot = data
        }

        let sidecar = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": schemaVersion,
            "cwd": "/tmp/acp-fixture"
        ])
        try sidecar.write(to: sessionDir.appendingPathComponent("meta.json"), options: .atomic)
        return storeURL
    }

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
        var dir = url.lastPathComponent.hasPrefix("cursor_test_")
            ? url
            : url.deletingLastPathComponent()
        while !dir.lastPathComponent.hasPrefix("cursor_test_") && dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func temporarySupportRoot(_ label: String) -> URL {
        let tempPath = NSTemporaryDirectory()
        let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
        return URL(fileURLWithPath: canonicalTempPath)
            .appendingPathComponent("cursor_test_\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func archiveRoot(for appSupport: URL) -> URL {
        appSupport
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
            .appendingPathComponent("cursor", isDirectory: true)
    }

    private func archiveStoreURL(for session: Session, appSupport: URL) -> URL {
        archiveRoot(for: appSupport)
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("store.db", isDirectory: false)
    }

    private func refreshArchiveManifest(at sessionRoot: URL) throws {
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let current = try JSONDecoder().decode(
            SessionArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let entries = try current.entries.map { entry in
            let file = dataRoot.appendingPathComponent(entry.relativePath, isDirectory: false)
            let data = try Data(contentsOf: file)
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date)
                ?? Date.distantPast
            return SessionArchiveManifest.Entry(
                relativePath: entry.relativePath,
                sizeBytes: Int64(data.count),
                mtimeSeconds: mtime.timeIntervalSince1970,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
        let manifest = SessionArchiveManifest(entries: entries)
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private func writeACPMetadata(to storeURL: URL, name: String) throws {
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/\(name)",
            "name": name
        ])
        try sidecar.write(to: storeURL.deletingLastPathComponent().appendingPathComponent("meta.json"),
                          options: .atomic)
    }

    private func writeIndexDBRow(at appSupport: URL,
                                 sessionID: String,
                                 sourcePath: String) throws {
        let directory = appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("index.db", isDirectory: false)
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            throw NSError(domain: "CursorSessionParserTests", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "could not open index fixture"])
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE session_meta (
            session_id TEXT,
            source TEXT,
            path TEXT,
            start_ts INTEGER,
            end_ts INTEGER,
            model TEXT,
            cwd TEXT,
            title TEXT,
            messages INTEGER,
            commands INTEGER,
            size INTEGER
        );
        """
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, schema, nil, nil, &errorMessage) == SQLITE_OK else {
            throw NSError(domain: "CursorSessionParserTests", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "could not create index fixture"])
        }

        let sql = """
        INSERT INTO session_meta
        (session_id, source, path, start_ts, end_ts, model, cwd, title, messages, commands, size)
        VALUES (?, ?, ?, 1700000000, 1700000001, NULL, NULL, NULL, 2, 0, 1);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorSessionParserTests", code: 22)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionID, -1, transient)
        sqlite3_bind_text(statement, 2, SessionSource.cursor.rawValue, -1, transient)
        sqlite3_bind_text(statement, 3, sourcePath, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorSessionParserTests", code: 23)
        }
    }

    private func regularFileBytes(in directory: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            out[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return out
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

    // MARK: - ACP persisted stores

    func testACPStoreReaderParsesPersistedTurnGraphAndPreservesProvenance() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }

        guard let session = CursorACPStoreReader.parse(at: url) else {
            return XCTFail("ACP store should parse")
        }
        XCTAssertEqual(session.id, "cursor-acp:\(acpSessionID)")
        XCTAssertEqual(session.surface, .acp)
        XCTAssertEqual(session.originator, "cursor-agent")
        XCTAssertEqual(session.originSource, "acp-persisted")
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant])
        XCTAssertEqual(session.events.map(\.text), ["hello from user", "hello from assistant"])

        let unit = SessionArchiveManager.archiveUnit(for: session)
        XCTAssertTrue(unit.isDirectory)
        XCTAssertEqual(unit.root.lastPathComponent, acpSessionID)
        XCTAssertEqual(unit.primaryRelativePath, "store.db")

        let refs = UnifiedSessionIndexer.searchFileRefs(for: [session])
        XCTAssertEqual(refs.map(\.path), [url.path], "parsed ACP must enter transcript search")
    }

    func testACPStoreReaderSkipsValidToolAndThinkingSteps() throws {
        let assistantData = proto(1, Data("hello from assistant".utf8))
        let assistantID = contentID(for: assistantData)
        let steps = [
            proto(1, assistantID),
            proto(2, Data("tool-call payload".utf8)),
            proto(3, Data("thinking payload".utf8)),
            proto(1, assistantID)
        ]
        let url = try writeTempACPStore(stepMessages: steps)
        defer { cleanupTemp(url) }

        let session = try XCTUnwrap(CursorACPStoreReader.parse(at: url))
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant, .assistant])
        XCTAssertEqual(session.events.map(\.text),
                       ["hello from user", "hello from assistant", "hello from assistant"])
    }

    func testACPStoreReaderSkipsValidShellTurn() throws {
        let userData = proto(1, Data("hello from user".utf8))
        let userID = contentID(for: userData)
        let assistantData = proto(1, Data("hello from assistant".utf8))
        let assistantID = contentID(for: assistantData)
        let stepData = proto(1, assistantID)
        let stepID = contentID(for: stepData)
        let agentTurn = proto(1, proto(1, userID) + proto(2, stepID))
        let shellTurn = proto(2, proto(1, Data("shell output".utf8)))
        let url = try writeTempACPStore(turnMessages: [agentTurn, shellTurn, agentTurn])
        defer { cleanupTemp(url) }

        let session = try XCTUnwrap(CursorACPStoreReader.parse(at: url))
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(session.events.map(\.text),
                       ["hello from user", "hello from assistant",
                        "hello from user", "hello from assistant"])
    }

    func testACPStoreReaderRejectsMismatchedIntrinsicIdentity() throws {
        let url = try writeTempACPStore(rootAgentID: "d88b213c-84e1-427d-bb5e-3859c1011087")
        defer { cleanupTemp(url) }

        XCTAssertNil(CursorACPStoreReader.parse(at: url),
                     "the store agentId must match its enclosing UUID directory")
    }

    func testACPParseWithAuthorityClassifiesCorruptSQLiteAsInvalid() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }
        try Data("not a SQLite database".utf8).write(to: url, options: .atomic)

        switch CursorACPStoreReader.parseWithAuthorityResult(at: url) {
        case .invalid:
            break
        case .valid, .unavailable:
            XCTFail("deterministically corrupt SQLite must remove the live projection, not preserve it as an outage")
        }
    }

    func testACPParseWithAuthorityClassifiesStructuralInvalidityAsInvalid() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }
        let metadataURL = url.deletingLastPathComponent().appendingPathComponent("meta.json")
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createSymbolicLink(at: metadataURL, withDestinationURL: url)

        switch CursorACPStoreReader.parseWithAuthorityResult(at: url) {
        case .invalid:
            break
        case .valid, .unavailable:
            XCTFail("a symlinked required sidecar is deterministic structural invalidity")
        }
    }

    func testACPStoreReaderRejectsBlobWithMismatchedContentHash() throws {
        let userData = proto(1, Data("hello from user".utf8))
        let userID = contentID(for: userData)
        let assistantData = proto(1, Data("hello from assistant".utf8))
        let assistantID = contentID(for: assistantData)
        let stepData = proto(1, assistantID)
        let stepID = contentID(for: stepData)
        let turnData = proto(1, proto(1, userID) + proto(2, stepID))
        let turnID = contentID(for: turnData)
        let rootData = proto(8, turnID)
        let rootID = contentID(for: rootData)
        let url = try writeTempACPStore(blobs: [
            rootID.hexString: rootData,
            turnID.hexString: turnData,
            userID.hexString: userData,
            stepID.hexString: stepData,
            assistantID.hexString: proto(1, Data("tampered".utf8))
        ], rootBlobID: rootID.hexString)
        defer { cleanupTemp(url) }

        XCTAssertNil(CursorACPStoreReader.parse(at: url),
                     "content-addressed blobs must be verified before decoding")
    }

    func testACPLogicalFingerprintChangesForSameSizeAtomicRewrite() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }

        let before = try XCTUnwrap(CursorACPStoreReader.logicalFileStat(at: url))
        let sidecarURL = url.deletingLastPathComponent().appendingPathComponent("meta.json")
        let replacement = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/acp-changed"
        ])
        XCTAssertEqual(replacement.count, try Data(contentsOf: sidecarURL).count)
        try replacement.write(to: sidecarURL, options: .atomic)

        let after = try XCTUnwrap(CursorACPStoreReader.logicalFileStat(at: url))
        XCTAssertEqual(before.size, after.size)
        XCTAssertNotEqual(before.fingerprint, after.fingerprint,
                          "an atomic same-size rewrite must invalidate the ACP refresh token")
    }

    func testACPParserBindsLiveSessionDirectoryBeforeCompanionReads() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(assistantText: "replacement")
        let liveRoot = liveURL.deletingLastPathComponent()
        let replacementRoot = replacementURL.deletingLastPathComponent()
        let replacementSidecar = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/replacement"
        ])
        try replacementSidecar.write(to: replacementRoot.appendingPathComponent("meta.json"), options: .atomic)
        defer {
            CursorACPStoreReader.liveParseHook = nil
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
        }

        CursorACPStoreReader.liveParseHook = {
            let displacedRoot = liveRoot.deletingLastPathComponent()
                .appendingPathComponent("displaced-session", isDirectory: true)
            try? FileManager.default.removeItem(at: displacedRoot)
            try? FileManager.default.moveItem(at: liveRoot, to: displacedRoot)
            try? FileManager.default.copyItem(at: replacementRoot, to: liveRoot)
        }

        let parsed = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        XCTAssertEqual(parsed.cwd, "/tmp/acp-fixture",
                       "sidecar reads must stay bound to the directory admitted before replacement")
        XCTAssertEqual(parsed.events.map(\.text), ["hello from user", "hello from assistant"])
    }

    func testACPParseWithAuthorityClassifiesPersistentStructuralSnapshotFailureAsInvalid() throws {
        let liveURL = try writeTempACPStore()
        let liveRoot = liveURL.deletingLastPathComponent()
        let metadataURL = liveRoot.appendingPathComponent("meta.json", isDirectory: false)
        let displacedMetadataURL = liveRoot.appendingPathComponent("meta.json.displaced", isDirectory: false)
        let previousHook = CursorACPStoreReader.liveParseHook
        var replaced = false
        defer {
            CursorACPStoreReader.liveParseHook = previousHook
            let metadataType = (try? FileManager.default.attributesOfItem(atPath: metadataURL.path)[.type]) as? FileAttributeType
            if metadataType == .typeSymbolicLink {
                try? FileManager.default.removeItem(at: metadataURL)
            }
            if FileManager.default.fileExists(atPath: displacedMetadataURL.path) {
                try? FileManager.default.moveItem(at: displacedMetadataURL, to: metadataURL)
            }
            cleanupTemp(liveURL)
        }

        CursorACPStoreReader.liveParseHook = {
            guard !replaced else { return }
            replaced = true
            try? FileManager.default.moveItem(at: metadataURL, to: displacedMetadataURL)
            try? FileManager.default.createSymbolicLink(
                at: metadataURL,
                withDestinationURL: liveRoot.appendingPathComponent("store.db", isDirectory: false)
            )
        }

        let result = CursorACPStoreReader.parseWithAuthorityResult(at: liveURL)
        XCTAssertTrue(replaced)
        guard case .invalid = result else {
            return XCTFail("a persistent structural snapshot rejection must remain invalid")
        }
    }

    func testACPParserRetriesWhenCompanionSetChangesAfterCopy() throws {
        let liveURL = try writeTempACPStore()
        let previousHook = CursorACPStoreReader.liveParsePostCopyHook
        var hookCalls = 0
        defer {
            CursorACPStoreReader.liveParsePostCopyHook = previousHook
            cleanupTemp(liveURL)
        }

        CursorACPStoreReader.liveParsePostCopyHook = {
            hookCalls += 1
            if hookCalls == 1 {
                try? self.writeACPMetadata(to: liveURL, name: "after-companion-copy")
            }
        }

        let parsed = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        XCTAssertGreaterThanOrEqual(hookCalls, 2,
                                    "a changed companion set must force a fresh snapshot attempt")
        XCTAssertEqual(parsed.cwd, "/tmp/after-companion-copy")
    }

    func testACPParserRejectsLiveCompanionABAWhenCopiedIdentityDiffers() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore()
        let liveRoot = liveURL.deletingLastPathComponent()
        let metaURL = liveRoot.appendingPathComponent("meta.json", isDirectory: false)
        let displacedMetaURL = liveRoot.appendingPathComponent("meta.aba-original", isDirectory: false)
        let replacementMetaURL = replacementURL.deletingLastPathComponent()
            .appendingPathComponent("meta.json", isDirectory: false)
        try writeACPMetadata(to: replacementURL, name: "aba-replacement")

        let previousBeforeHook = CursorACPStoreReader.liveParseBeforeMetadataCopyHook
        let previousPostHook = CursorACPStoreReader.liveParsePostCopyHook
        var didSwap = false
        var didRestore = false
        var preCopyCalls = 0
        defer {
            CursorACPStoreReader.liveParseBeforeMetadataCopyHook = previousBeforeHook
            CursorACPStoreReader.liveParsePostCopyHook = previousPostHook
            try? FileManager.default.removeItem(at: displacedMetaURL)
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
        }

        CursorACPStoreReader.liveParseBeforeMetadataCopyHook = {
            preCopyCalls += 1
            guard !didSwap else { return }
            didSwap = true
            try? FileManager.default.moveItem(at: metaURL, to: displacedMetaURL)
            try? FileManager.default.copyItem(at: replacementMetaURL, to: metaURL)
        }
        CursorACPStoreReader.liveParsePostCopyHook = {
            guard didSwap, !didRestore else { return }
            didRestore = true
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.moveItem(at: displacedMetaURL, to: metaURL)
        }

        let parsed = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        XCTAssertGreaterThanOrEqual(preCopyCalls, 2,
                                    "an ABA companion replacement must force a second snapshot attempt")
        XCTAssertEqual(parsed.cwd, "/tmp/acp-fixture",
                       "the parser must not publish bytes copied from the transient replacement")
    }

    func testACPArchiveRoundTripPreservesNamespacedIdentityAndEvents() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRoundTrip")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(live)

        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        XCTAssertTrue(CursorACPStoreReader.isACPStore(archivedURL))
        let archived = try XCTUnwrap(CursorACPStoreReader.parse(at: archivedURL))
        XCTAssertEqual(archived.id, live.id)
        XCTAssertEqual(archived.originator, "cursor-agent")
        XCTAssertEqual(archived.originSource, "acp-persisted")
        XCTAssertEqual(archived.surface, .acp)
        XCTAssertEqual(archived.events.map(\.text), live.events.map(\.text))
    }

    func testACPArchiveManifestExcludesRebuildableSQLiteSHM() throws {
        let liveURL = try writeTempACPStore()
        let liveSHM = URL(fileURLWithPath: liveURL.path + "-shm")
        try Data("rebuildable WAL index".utf8).write(to: liveSHM, options: .atomic)
        let appSupport = temporarySupportRoot("ACPArchiveSHM")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRoot = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.pinSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            SessionArchiveManifest.self,
            from: Data(contentsOf: sessionRoot.appendingPathComponent("manifest.json"))
        )
        XCTAssertFalse(manifest.entries.contains { $0.relativePath == "store.db-shm" })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessionRoot.appendingPathComponent("data/store.db-shm").path
        ))
        XCTAssertNotNil(CursorACPStoreReader.parse(at: archiveStoreURL(for: live, appSupport: appSupport)))
    }

    func testACPArchiveValidationDoesNotWriteSQLiteSHMIntoCommittedTree() throws {
        let liveURL = try writeTempACPStore(enableWAL: true)
        let walURL = URL(fileURLWithPath: liveURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: liveURL.path + "-shm")
        let walSize = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber
        XCTAssertGreaterThan(walSize?.int64Value ?? 0, 32,
                              "the fixture must contain an uncheckpointed WAL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path),
                       "the fixture must exercise SQLite's missing-SHM recovery")
        let appSupport = temporarySupportRoot("ACPArchiveWALValidation")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(live)

        let dataRoot = archiveRoot
            .appendingPathComponent(live.id, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dataRoot.path) else {
            XCTFail("archive validation failed: \(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: live.id)?.lastError ?? "no error recorded")")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(at: dataRoot,
                                                                  includingPropertiesForKeys: [],
                                                                  options: [])
            .map(\.lastPathComponent)
        XCTAssertFalse(names.contains("store.db-shm"),
                       "semantic validation must not mutate the committed archive tree")
        XCTAssertTrue(Set(names).isSubset(of: ["store.db", "meta.json", "store.db-wal"]))
        XCTAssertNotNil(CursorACPStoreReader.parse(at: archiveStoreURL(for: live, appSupport: appSupport)))
    }

    func testACPArchiveSyncPreservesCommittedFinalWhenValidationIsUnavailable() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPFinalValidationUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousValidationHook = CursorACPStoreReader.archiveValidationUnavailableHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            CursorACPStoreReader.archiveValidationUnavailableHook = previousValidationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let committedBytes = try Data(contentsOf: archivedURL)

        CursorACPStoreReader.archiveValidationUnavailableHook = { true }
        manager.syncSessionForTesting(live)

        XCTAssertEqual(try Data(contentsOf: archivedURL), committedBytes,
                       "an unavailable final validation must not allow a replacement commit")
        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertEqual(info.status, .error)
        XCTAssertTrue(info.lastError?.contains("unavailable") == true)
    }

    func testACPArchiveParseRejectsReplacementAfterAdmission() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(assistantText: "replacement")
        let appSupport = temporarySupportRoot("ACPArchiveParseSnapshot")
        let archiveRoot = archiveRoot(for: appSupport)
        let replacementSupport = temporarySupportRoot("ACPArchiveParseSnapshotReplacement")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            CursorACPStoreReader.archiveParseHook = nil
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
            cleanupTemp(appSupport)
            cleanupTemp(replacementSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let archivedSessionRoot = archivedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: replacementSupport, withIntermediateDirectories: true)
        let replacementSessionRoot = replacementSupport.appendingPathComponent(live.id, isDirectory: true)
        try FileManager.default.copyItem(at: archivedSessionRoot, to: replacementSessionRoot)
        let replacementDataRoot = replacementSessionRoot.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.removeItem(at: replacementDataRoot.appendingPathComponent("store.db"))
        try FileManager.default.copyItem(at: replacementURL, to: replacementDataRoot.appendingPathComponent("store.db"))
        let replacementSidecar = replacementURL.deletingLastPathComponent().appendingPathComponent("meta.json")
        try FileManager.default.removeItem(at: replacementDataRoot.appendingPathComponent("meta.json"))
        try FileManager.default.copyItem(at: replacementSidecar, to: replacementDataRoot.appendingPathComponent("meta.json"))
        try refreshArchiveManifest(at: replacementSessionRoot)

        CursorACPStoreReader.archiveParseHook = {
            try? FileManager.default.removeItem(at: archivedSessionRoot)
            try? FileManager.default.copyItem(at: replacementSessionRoot, to: archivedSessionRoot)
        }
        XCTAssertNil(CursorACPStoreReader.parse(at: archivedURL),
                     "archive parsing must fail when a replacement manifest and its files arrive after admission")
    }

    func testACPArchiveFallbackRestarPreservesDirectoryArchive() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveFallbackRestar")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let before = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertTrue(before.upstreamIsDirectory)

        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let fallback = Session(id: live.id,
                               source: .cursor,
                               startTime: live.startTime,
                               endTime: live.endTime,
                               model: live.model,
                               filePath: archivedURL.path,
                               fileSizeBytes: live.fileSizeBytes,
                               eventCount: live.eventCount,
                               events: [],
                               cwd: live.cwd,
                               repoName: live.repoName,
                               lightweightTitle: live.lightweightTitle,
                               customTitle: live.customTitle,
                               originator: "cursor-agent",
                               originSource: "acp-persisted",
                               surface: .acp)
        XCTAssertTrue(CursorACPStoreReader.isACPStore(archivedURL))
        XCTAssertTrue(manager.isArchivedPrimary(session: fallback))
        try FileManager.default.removeItem(at: liveURL.deletingLastPathComponent())
        XCTAssertTrue(manager.isArchivedPrimary(session: fallback),
                      "archive primary must remain recognized after deleting the live store")

        manager.pinSessionForTesting(fallback)

        let after = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertEqual(after.upstreamPath, before.upstreamPath,
                       "re-starring an archive fallback must retain the live directory source")
        XCTAssertTrue(after.upstreamIsDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedURL.deletingLastPathComponent()
            .appendingPathComponent("meta.json").path))
        XCTAssertEqual(CursorACPStoreReader.parse(at: archivedURL)?.events.map(\.text), live.events.map(\.text))
    }

    func testACPArchiveFallbackDoesNotResnapshotStaleLiveRootAfterAuthorityMoves() throws {
        let liveURL = try writeTempACPStore()
        let rootA = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootB = temporarySupportRoot("EmptyCursorRoot")
        try FileManager.default.createDirectory(at: rootB.appendingPathComponent("acp-sessions", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let appSupport = temporarySupportRoot("ArchiveFallbackAuthority")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRoot = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(rootA.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(rootB)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let archivedBefore = try Data(contentsOf: archivedURL)

        // Keep the old live root present and mutate it after authority has
        // moved. A fallback re-pin must not treat this stale path as live.
        try writeACPMetadata(to: liveURL, name: "stale-live-root")
        UserDefaults.standard.set(rootB.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let fallback = Session(id: live.id,
                               source: .cursor,
                               startTime: live.startTime,
                               endTime: live.endTime,
                               model: live.model,
                               filePath: archivedURL.path,
                               fileSizeBytes: live.fileSizeBytes,
                               eventCount: live.eventCount,
                               events: [],
                               cwd: live.cwd,
                               repoName: live.repoName,
                               lightweightTitle: live.lightweightTitle,
                               customTitle: live.customTitle,
                               originator: "cursor-agent",
                               originSource: "acp-persisted",
                               surface: .acp)

        manager.pinSessionForTesting(fallback)

        XCTAssertEqual(try Data(contentsOf: archivedURL), archivedBefore,
                       "an archive-only fallback must not resnapshot a stale live root")
        XCTAssertEqual(CursorACPStoreReader.parse(at: archivedURL)?.cwd, live.cwd)
    }

    func testACPArchiveBindsSnapshotToTheCurrentRootAuthority() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(sessionID: acpSessionID,
                                                    assistantText: "replacement")
        let rootA = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let originalSessionRoot = liveURL.deletingLastPathComponent()
        let acpRoot = originalSessionRoot.deletingLastPathComponent()
        let displacedSessionRoot = acpRoot
            .appendingPathComponent("\(acpSessionID).original", isDirectory: true)
        let replacementSessionRoot = replacementURL.deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPArchiveAuthorityABA")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRoot = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let previousPreSnapshot = SessionArchiveManagerTestHooks.preSnapshotHook
        let previousPostSnapshot = SessionArchiveManagerTestHooks.postSnapshotHook
        var replacementInstalled = false

        func restoreOriginal() {
            if FileManager.default.fileExists(atPath: originalSessionRoot.path) {
                try? FileManager.default.removeItem(at: originalSessionRoot)
            }
            if FileManager.default.fileExists(atPath: displacedSessionRoot.path) {
                try? FileManager.default.moveItem(at: displacedSessionRoot, to: originalSessionRoot)
            }
            replacementInstalled = false
        }

        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(rootA.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.preSnapshotHook = previousPreSnapshot
            SessionArchiveManagerTestHooks.postSnapshotHook = previousPostSnapshot
            restoreOriginal()
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManagerTestHooks.preSnapshotHook = {
            guard !replacementInstalled else { return }
            do {
                try FileManager.default.moveItem(at: originalSessionRoot, to: displacedSessionRoot)
                try FileManager.default.copyItem(at: replacementSessionRoot, to: originalSessionRoot)
                replacementInstalled = true
            } catch {
                restoreOriginal()
            }
        }
        SessionArchiveManagerTestHooks.postSnapshotHook = {
            if replacementInstalled {
                restoreOriginal()
            }
        }

        SessionArchiveManager.shared.pinSessionForTesting(live)

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalSessionRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: archiveStoreURL(for: live, appSupport: appSupport).path
        ), "a same-path ACP directory ABA must not be committed")
        XCTAssertNil(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: live.id),
                     "an authority ABA before first archive creation must not create stale error metadata")
    }

    func testACPArchiveCommitRollsBackIfRootChangesInRenameWindow() throws {
        let liveURL = try writeTempACPStore()
        let rootA = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootB = temporarySupportRoot("ACPCommitAuthorityChanged")
        try FileManager.default.createDirectory(at: rootB.appendingPathComponent("acp-sessions", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let appSupport = temporarySupportRoot("ACPCommitAuthorityArchive")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRoot = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let previousCommitHook = SessionArchiveManagerTestHooks.beforeCommitRenameHook
        var didChangeRoot = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(rootA.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.beforeCommitRenameHook = previousCommitHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(rootB)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let committedBytes = try Data(contentsOf: archivedURL)

        try writeACPMetadata(to: liveURL, name: "changed-before-commit")
        SessionArchiveManagerTestHooks.beforeCommitRenameHook = {
            guard !didChangeRoot else { return }
            didChangeRoot = true
            UserDefaults.standard.set(rootB.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        }
        manager.pinSessionForTesting(live)

        XCTAssertTrue(didChangeRoot)
        XCTAssertEqual(try Data(contentsOf: archivedURL), committedBytes,
                       "a root change during the rename window must restore the previous final")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedURL.path))
        XCTAssertEqual(manager.archiveInfoForTesting(source: .cursor, id: live.id)?.status, .error)
    }

    func testACPArchiveCommitRejectsMutationAfterStagedValidation() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPStagedMutation")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousHook = SessionArchiveManagerTestHooks.afterStagedValidationHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.afterStagedValidationHook = previousHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let committedBytes = try Data(contentsOf: archivedURL)

        try writeACPMetadata(to: liveURL, name: "changed-before-staging-mutation")
        var didMutate = false
        SessionArchiveManagerTestHooks.afterStagedValidationHook = { stagingSessionRoot in
            guard !didMutate else { return }
            didMutate = true
            let rogue = stagingSessionRoot
                .appendingPathComponent("data", isDirectory: true)
                .appendingPathComponent("rogue-after-validation", isDirectory: false)
            try? Data("rogue".utf8).write(to: rogue, options: .atomic)
        }

        manager.syncSessionForTesting(live)

        let diagnosticInfo = manager.archiveInfoForTesting(source: .cursor, id: live.id)
        let diagnosticStatus = diagnosticInfo?.status.rawValue ?? "nil"
        let diagnosticError = diagnosticInfo?.lastError ?? "nil"
        XCTAssertTrue(didMutate,
                      "hook was not reached: status=\(diagnosticStatus) error=\(diagnosticError)")
        XCTAssertEqual(try Data(contentsOf: archivedURL), committedBytes,
                       "a staged tree mutated after validation must not replace the committed final")
    }

    func testACPArchiveCommitRestoresKnownGoodFinalWhenValidatedFinalIsReplacedBeforeCleanup() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPCommitFinalIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-validated-final",
                                                                isDirectory: true)
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRoot = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let previousHook = SessionArchiveManagerTestHooks.beforeBackupCleanupHook
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.beforeBackupCleanupHook = previousHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let previousRoot {
                UserDefaults.standard.set(previousRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let sessionRoot = archivedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        try writeACPMetadata(to: liveURL, name: "validated-final-replaced")
        SessionArchiveManagerTestHooks.beforeBackupCleanupHook = {
            guard !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.pinSessionForTesting(live)

        XCTAssertTrue(didReplaceFinal, "cleanup identity seam was not reached")
        XCTAssertEqual(try Data(contentsOf: sessionRoot.appendingPathComponent("rogue", isDirectory: false)),
                       Data("replacement-final".utf8),
                       "a replaced final must not be deleted by rollback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedFinal.path),
                      "the validated final must remain preserved outside the replaced pathname")
        let recoveryCopies = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: [],
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".backup-\(live.id)-") }
        XCTAssertFalse(recoveryCopies.isEmpty,
                       "identity mismatch must preserve the recovery copy for later reconciliation")
    }

    func testACPArchiveCommitPreservesReplacementWhenInvalidFinalIsRolledBack() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPCommitInvalidIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-invalid-final",
                                                                isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousInstalledHook = SessionArchiveManagerTestHooks.afterReplacementInstalledHook
        let previousCleanupHook = SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook
        var didCorruptInstalledFinal = false
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.afterReplacementInstalledHook = previousInstalledHook
            SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = previousCleanupHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)

        try writeACPMetadata(to: liveURL, name: "invalid-final-rollback")
        SessionArchiveManagerTestHooks.afterReplacementInstalledHook = {
            guard !didCorruptInstalledFinal else { return }
            try? FileManager.default.removeItem(at: manifestURL)
            didCorruptInstalledFinal = true
        }
        SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = {
            guard !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-invalid-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.syncSessionForTesting(live)

        XCTAssertTrue(didCorruptInstalledFinal, "post-install validation seam was not reached")
        XCTAssertTrue(didReplaceFinal, "invalid rollback seam was not reached")
        XCTAssertEqual(
            try Data(contentsOf: sessionRoot.appendingPathComponent("rogue", isDirectory: false)),
            Data("replacement-invalid-final".utf8),
            "invalid rollback must not delete a replacement at the final pathname"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedFinal.path))
    }

    func testACPArchiveRecoveryValidatesTheBoundRootAfterPathReplacement() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPRecoveryBoundRoot")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedRoot = appSupport
            .appendingPathComponent("displaced-archive-root", isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRemoveHook = SessionArchiveManagerTestHooks.recoveryRemoveFinalHook
        var parserRoot = archiveRoot
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { parserRoot }
        defer {
            SessionArchiveManagerTestHooks.recoveryRemoveFinalHook = previousRemoveHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("manifest.json"))

        var didReplaceRoot = false
        SessionArchiveManagerTestHooks.recoveryRemoveFinalHook = {
            guard !didReplaceRoot else { return true }
            do {
                try FileManager.default.moveItem(at: archiveRoot, to: displacedRoot)
                try FileManager.default.createDirectory(at: archiveRoot,
                                                         withIntermediateDirectories: true)
                parserRoot = displacedRoot
                didReplaceRoot = true
                return true
            } catch {
                return false
            }
        }

        manager.recoverOrphanedArchivesForTesting()

        let displacedSessionRoot = displacedRoot.appendingPathComponent(live.id, isDirectory: true)
        let displacedBackupRoot = displacedRoot.appendingPathComponent(backupRoot.lastPathComponent,
                                                                        isDirectory: true)
        XCTAssertTrue(didReplaceRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedSessionRoot.path),
                      "recovery must continue operating on the originally bound archive root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: displacedBackupRoot.path),
                       "a validated recovery candidate should be consumed only after bound validation")
        XCTAssertNotNil(CursorACPStoreReader.parse(at: displacedSessionRoot
            .appendingPathComponent("data/store.db", isDirectory: false)),
                        "the restored candidate must be validated from the bound root")
    }

    func testACPArchiveRecoveryPreservesBackupsWhenValidatedFinalIsReplacedBeforeCleanup() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPRecoveryFinalIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-recovery-final",
                                                                isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousHook = SessionArchiveManagerTestHooks.beforeBackupCleanupHook
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.beforeBackupCleanupHook = previousHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupOne = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        let backupTwo = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupOne)
        try FileManager.default.copyItem(at: sessionRoot, to: backupTwo)

        SessionArchiveManagerTestHooks.beforeBackupCleanupHook = {
            guard !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(didReplaceFinal, "cleanup identity seam was not reached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupOne.path),
                      "the first recovery copy must survive final-path replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupTwo.path),
                      "the second recovery copy must survive final-path replacement")
    }

    func testACPArchiveRecoveryPreservesOtherBackupsWhenRestoredFinalIsReplacedBeforeCleanup() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPRecoveryRestoredIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-restored-final",
                                                                isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousHook = SessionArchiveManagerTestHooks.beforeBackupCleanupHook
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.beforeBackupCleanupHook = previousHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupOne = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        let backupTwo = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: backupOne)
        try FileManager.default.copyItem(at: backupOne, to: backupTwo)

        SessionArchiveManagerTestHooks.beforeBackupCleanupHook = {
            guard !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.recoverOrphanedArchivesForTesting()

        let remainingBackups = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: [],
            options: []
        ).filter { $0.lastPathComponent.hasPrefix(".backup-\(live.id)-") }
        XCTAssertTrue(didReplaceFinal, "cleanup identity seam was not reached")
        XCTAssertEqual(remainingBackups.count, 1,
                       "the untouched recovery copy must survive final-path replacement")
    }

    func testACPArchiveRecoveryPreservesReplacementWhenInvalidFinalIsRemoved() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPRecoveryInvalidIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-invalid-recovery-final",
                                                                isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousCleanupHook = SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = previousCleanupHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("manifest.json"))

        SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = {
            guard !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-invalid-recovery-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(didReplaceFinal, "invalid-final cleanup seam was not reached")
        XCTAssertEqual(
            try Data(contentsOf: sessionRoot.appendingPathComponent("rogue", isDirectory: false)),
            Data("replacement-invalid-recovery-final".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "a replaced invalid final must leave the recovery candidate intact")
    }

    func testACPArchiveRecoveryPreservesReplacementWhenInvalidRestoredFinalIsRemoved() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPRecoveryRestoredInvalidIdentity")
        let archiveRoot = archiveRoot(for: appSupport)
        let displacedFinal = appSupport.appendingPathComponent("displaced-restored-invalid-final",
                                                                isDirectory: true)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousCleanupHook = SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook
        var cleanupCallCount = 0
        var didReplaceFinal = false
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = previousCleanupHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try FileManager.default.removeItem(at: sessionRoot)
        try FileManager.default.removeItem(at: backupRoot.appendingPathComponent("manifest.json"))

        SessionArchiveManagerTestHooks.beforeInvalidArchiveCleanupHook = {
            cleanupCallCount += 1
            guard cleanupCallCount == 2, !didReplaceFinal else { return }
            do {
                try FileManager.default.moveItem(at: sessionRoot, to: displacedFinal)
                try FileManager.default.createDirectory(at: sessionRoot,
                                                         withIntermediateDirectories: true)
                try Data("replacement-restored-invalid-final".utf8).write(
                    to: sessionRoot.appendingPathComponent("rogue", isDirectory: false),
                    options: .atomic
                )
                didReplaceFinal = true
            } catch {
                didReplaceFinal = false
            }
        }

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertEqual(cleanupCallCount, 2,
                       "the race seam must run for both the missing initial final and restored invalid candidate")
        XCTAssertTrue(didReplaceFinal, "restored invalid-final cleanup seam was not reached")
        XCTAssertEqual(
            try Data(contentsOf: sessionRoot.appendingPathComponent("rogue", isDirectory: false)),
            Data("replacement-restored-invalid-final".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedFinal.path))
    }

    func testACPArchiveRecoveryRestoresBackupAfterInterruptedReplacement() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecovery")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot
            .appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: backupRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertEqual(CursorACPStoreReader.parse(at: archiveStoreURL(for: live, appSupport: appSupport))?.events.map(\.text),
                       live.events.map(\.text))
    }

    func testACPArchiveRecoverySelectsNewestValidBackupAndClearsTheSet() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoverySet")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let olderBackup = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        let newerBackup = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: olderBackup)
        try FileManager.default.copyItem(at: olderBackup, to: newerBackup)

        let newerMetaURL = newerBackup.appendingPathComponent("meta.json", isDirectory: false)
        var newerInfo = try JSONDecoder().decode(
            SessionArchiveInfo.self,
            from: Data(contentsOf: newerMetaURL)
        )
        newerInfo.title = "newer-recovery-copy"
        newerInfo.lastSyncAt = Date(timeIntervalSince1970: 2_000_000_000)
        try JSONEncoder().encode(newerInfo).write(to: newerMetaURL, options: .atomic)
        try refreshArchiveManifest(at: newerBackup)

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderBackup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newerBackup.path))
        XCTAssertEqual(manager.archiveInfoForTesting(source: .cursor, id: live.id)?.title,
                       "newer-recovery-copy")
        XCTAssertEqual(CursorACPStoreReader.parse(at: archiveStoreURL(for: live, appSupport: appSupport))?
            .events.map(\.text), live.events.map(\.text))
    }

    func testACPArchiveRecoveryPreservesBackupsWhenRestoreFails() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoveryFailure")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRecoveryRename = SessionArchiveManagerTestHooks.recoveryRenameHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.recoveryRenameHook = previousRecoveryRename
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: backupRoot)

        SessionArchiveManagerTestHooks.recoveryRenameHook = { false }
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "a failed restore must preserve the recovery copy")
    }

    func testACPArchiveRecoveryPreservesFinalAndBackupsWhenValidationUnavailable() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoveryUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousValidationHook = CursorACPStoreReader.archiveValidationUnavailableHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            CursorACPStoreReader.archiveValidationUnavailableHook = previousValidationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)

        CursorACPStoreReader.archiveValidationUnavailableHook = { true }
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path),
                      "validation outage must preserve the healthy final")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "validation outage must preserve every recovery copy")
    }

    func testACPArchiveRecoveryRollsBackSoleBackupWhenValidationFailsAfterRestore() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoveryPostRestoreUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousValidationHook = CursorACPStoreReader.archiveValidationUnavailableHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            CursorACPStoreReader.archiveValidationUnavailableHook = previousValidationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: backupRoot)

        var validationUnavailableCalls = 0
        CursorACPStoreReader.archiveValidationUnavailableHook = {
            validationUnavailableCalls += 1
            return true
        }
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertGreaterThan(validationUnavailableCalls, 0,
                             "recovery must reach post-restore validation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path),
                      "an unavailable post-restore validation must not consume the only backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "the sole recovery copy must be restored to its backup name")
    }

    func testACPArchiveRecoveryPreservesFinalAndBackupsWhenSQLiteValidationFailsAfterCopy() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoverySQLiteUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousValidationHook = CursorACPStoreReader.archiveParseOperationalFailureHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            CursorACPStoreReader.archiveParseOperationalFailureHook = previousValidationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-" + live.id + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)

        CursorACPStoreReader.archiveParseOperationalFailureHook = { true }
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path),
                      "an operational SQLite validation failure must preserve the final")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "an operational SQLite validation failure must preserve every backup")
    }

    func testACPArchiveRecoveryPreservesOtherBackupsWhenRestoreSyncFails() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRecoverySyncFailure")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousRecoverySync = SessionArchiveManagerTestHooks.recoverySyncHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.recoverySyncHook = previousRecoverySync
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let olderBackup = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        let newerBackup = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: sessionRoot, to: olderBackup)
        try FileManager.default.copyItem(at: olderBackup, to: newerBackup)

        SessionArchiveManagerTestHooks.recoverySyncHook = { false }
        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path),
                      "the restored final remains available when its durability barrier fails")
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderBackup.path)
                      || FileManager.default.fileExists(atPath: newerBackup.path),
                      "an unconsumed recovery copy must remain after sync failure")
        XCTAssertNotNil(CursorACPStoreReader.parse(at: archiveStoreURL(for: live, appSupport: appSupport)))
    }

    func testACPArchiveDeleteRemovesTransactionCopies() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveDeleteTransactions")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = archiveRoot
            .appendingPathComponent(".staging-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try FileManager.default.copyItem(at: sessionRoot, to: stagingRoot)

        manager.deleteArchiveForTesting(source: .cursor, id: live.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testACPArchiveDeletePreservesArchiveWhenTransactionEnumerationFails() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveDeleteEnumerationFailure")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousEnumerationHook = SessionArchiveManagerTestHooks.directoryEnumerationHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.directoryEnumerationHook = previousEnumerationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = archiveRoot
            .appendingPathComponent(".backup-\(live.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)

        SessionArchiveManagerTestHooks.directoryEnumerationHook = { false }
        manager.deleteArchiveForTesting(source: .cursor, id: live.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path),
                      "a failed transaction scan must not remove the final first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path),
                      "a failed transaction scan must preserve the hidden backup")
    }

    func testACPParseWithAuthorityKeepsSessionAndStatFromOneSnapshot() throws {
        let liveURL = try writeTempACPStore()
        let previousHook = CursorACPStoreReader.liveParseBeforeSemanticParseHook
        defer {
            CursorACPStoreReader.liveParseBeforeSemanticParseHook = previousHook
            cleanupTemp(liveURL)
        }

        CursorACPStoreReader.liveParseBeforeSemanticParseHook = {
            try? self.writeACPMetadata(to: liveURL, name: "new-epoch")
        }
        let parsed = try XCTUnwrap(CursorACPStoreReader.parseWithAuthority(at: liveURL))
        let currentStat = try XCTUnwrap(CursorACPStoreReader.logicalFileStat(at: liveURL))

        XCTAssertEqual(parsed.session.cwd, "/tmp/acp-fixture")
        XCTAssertNotEqual(parsed.logicalStat, currentStat,
                          "the authority token must stay bound to the parsed snapshot")
    }

    func testLegacyArchiveRecoveryRestoresHealthyBackupWhenFinalHashMismatches() throws {
        let liveURL = try writeTempJSONL(fixtureLines)
        let appSupport = temporarySupportRoot("LegacyArchiveHashRecovery")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorSessionParser.parseFile(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = appSupport
            .appendingPathComponent("AgentSessions/Archives/cursor", isDirectory: true)
            .appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = sessionRoot.deletingLastPathComponent()
            .appendingPathComponent(".backup-" + live.id + "-" + UUID().uuidString, isDirectory: true)
        let archivedFile = sessionRoot.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(liveURL.lastPathComponent, isDirectory: false)
        let original = try Data(contentsOf: archivedFile)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try Data("tampered-final".utf8).write(to: archivedFile, options: .atomic)

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertEqual(try Data(contentsOf: archivedFile), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testLegacyArchiveRecoveryRestoresHealthyBackupWhenManifestIsMissing() throws {
        let liveURL = try writeTempJSONL(fixtureLines)
        let appSupport = temporarySupportRoot("LegacyArchiveManifestRecovery")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorSessionParser.parseFile(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = appSupport
            .appendingPathComponent("AgentSessions/Archives/cursor", isDirectory: true)
            .appendingPathComponent(live.id, isDirectory: true)
        let backupRoot = sessionRoot.deletingLastPathComponent()
            .appendingPathComponent(".backup-" + live.id + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: sessionRoot, to: backupRoot)
        try FileManager.default.removeItem(at: sessionRoot.appendingPathComponent("manifest.json"))

        manager.recoverOrphanedArchivesForTesting()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.appendingPathComponent("manifest.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
    }

    func testGenericDirectoryEnumerationFailureLeavesCommittedArchiveUntouched() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_cline-enumeration-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cline-enumeration", isDirectory: true)
        let primary = root.appendingPathComponent("cline-enumeration.json", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: primary, options: .atomic)

        let appSupport = temporarySupportRoot("GenericDirectoryEnumeration")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousHook = SessionArchiveManagerTestHooks.upstreamEnumerationHook
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer {
            SessionArchiveManagerTestHooks.upstreamEnumerationHook = previousHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            cleanupTemp(primary)
            cleanupTemp(appSupport)
        }

        let session = Session(id: "cline-enumeration-test",
                              source: .cline,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: primary.path,
                              eventCount: 0,
                              events: [])
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(session)
        let sessionRoot = appSupport
            .appendingPathComponent("AgentSessions/Archives/cline", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
        let archivedFile = sessionRoot.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(primary.lastPathComponent, isDirectory: false)
        let before = try Data(contentsOf: archivedFile)

        SessionArchiveManagerTestHooks.upstreamEnumerationHook = { false }
        try Data(#"{"changed":true}"#.utf8).write(to: primary, options: .atomic)
        manager.syncSessionForTesting(session)

        XCTAssertEqual(try Data(contentsOf: archivedFile), before)
    }

    func testCursorLegacyJSONLArchiveStillUsesSingleFileUnit() throws {
        let liveURL = try writeTempJSONL(fixtureLines)
        let appSupport = temporarySupportRoot("LegacyArchive")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let session = try XCTUnwrap(CursorSessionParser.parseFile(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(session)
        let info = try XCTUnwrap(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor,
                                                                                    id: session.id))
        XCTAssertNotEqual(info.status, .error, info.lastError ?? "legacy Cursor JSONL archive failed")
        let archived = appSupport
            .appendingPathComponent("AgentSessions/Archives/cursor", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(liveURL.lastPathComponent, isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path))
    }

    func testACPArchiveRepairsMissingCompanionDuringNoopSync() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveRepair")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(live)
        let archivedSidecar = archiveStoreURL(for: live, appSupport: appSupport)
            .deletingLastPathComponent()
            .appendingPathComponent("meta.json", isDirectory: false)
        try FileManager.default.removeItem(at: archivedSidecar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedSidecar.path))

        SessionArchiveManager.shared.syncSessionForTesting(live)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedSidecar.path),
                      "a missing manifest companion must invalidate the no-op and be recopied")
    }

    func testACPBackfillFallbackPreservesProvenanceWhenSQLiteParseFails() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }
        try Data("not a SQLite database".utf8).write(to: url, options: .atomic)

        let capability = try XCTUnwrap(SessionSource.cursor.descriptor.archive)
        let fallback = try XCTUnwrap(capability.sessionForBackfill("cursor-acp:\(acpSessionID)", url))
        XCTAssertEqual(fallback.surface, .acp)
        XCTAssertEqual(fallback.originator, "cursor-agent")
        XCTAssertEqual(fallback.originSource, "acp-persisted")
    }

    func testACPBackfillURLsRetainCanonicalStoreWhenSQLiteParseFails() throws {
        let url = try writeTempACPStore()
        let cursorRoot = url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer { cleanupTemp(url) }

        try Data("not a SQLite database".utf8).write(to: url, options: .atomic)
        let suiteName = "CursorACPBackfill-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)

        let capability = try XCTUnwrap(SessionSource.cursor.descriptor.archive)
        let discovered = CursorSessionDiscovery(customRoot: cursorRoot.path).discoverACPSessionDBs()
        XCTAssertEqual(discovered?.map(\.standardizedFileURL), [url.standardizedFileURL])
        let urls = capability.backfillURLs(defaults)
        XCTAssertEqual(urls["cursor-acp:\(acpSessionID)"]?.standardizedFileURL,
                       url.standardizedFileURL,
                       "a discovered but temporarily unreadable ACP store still needs the backfill arm")
        let fallback = try XCTUnwrap(capability.sessionForBackfill("cursor-acp:\(acpSessionID)", url))
        XCTAssertEqual(fallback.surface, .acp)
        XCTAssertEqual(fallback.originSource, "acp-persisted")
    }

    func testACPBackfillIgnoresStaleIndexDBPathWhenCustomRootChanges() throws {
        let sessionUUID = UUID().uuidString.lowercased()
        let staleURL = try writeTempACPStore(sessionID: sessionUUID)
        let currentURL = try writeTempACPStore(sessionID: sessionUUID)
        let currentRoot = currentURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPStaleIndexDB")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        UserDefaults.standard.set(currentRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(staleURL)
            cleanupTemp(currentURL)
            cleanupTemp(appSupport)
        }

        let id = "cursor-acp:\(sessionUUID)"
        try writeIndexDBRow(at: appSupport, sessionID: id, sourcePath: staleURL.path)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: id, source: .cursor)

        SessionArchiveManager.shared.syncPinnedSessionsForTesting()

        let info = try XCTUnwrap(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: id))
        XCTAssertEqual(info.upstreamPath, currentURL.deletingLastPathComponent().path,
                       "a stale IndexDB ACP path must not beat the currently configured root")
        XCTAssertTrue(info.upstreamIsDirectory)
    }

    func testACPPinResolvesCurrentRootBeforeFirstArchive() throws {
        let sessionUUID = UUID().uuidString.lowercased()
        let staleURL = try writeTempACPStore(sessionID: sessionUUID)
        let currentURL = try writeTempACPStore(sessionID: sessionUUID, assistantText: "current")
        let currentRoot = currentURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPPinCurrentAuthority")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        UserDefaults.standard.set(currentRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(staleURL)
            cleanupTemp(currentURL)
            cleanupTemp(appSupport)
        }

        let stale = try XCTUnwrap(CursorACPStoreReader.parse(at: staleURL))
        let manager = SessionArchiveManager.shared
        manager.pinSessionForTesting(stale)

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: stale.id))
        XCTAssertEqual(info.upstreamPath, currentURL.deletingLastPathComponent().path,
                       "direct ACP pinning must use the current configured root, not the row's stale path")
        XCTAssertTrue(info.isCursorACPArchive)
    }

    func testACPPinRejectsLiveSessionDirectorySymlinkBeforeFirstArchive() throws {
        let liveURL = try writeTempACPStore()
        let externalURL = try writeTempACPStore(assistantText: "external")
        let liveRoot = liveURL.deletingLastPathComponent()
        let externalRoot = externalURL.deletingLastPathComponent()
        let cursorRoot = liveRoot.deletingLastPathComponent().deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPPinSymlinkAuthority")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(externalURL)
            cleanupTemp(appSupport)
        }

        let session = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        try FileManager.default.removeItem(at: liveRoot)
        try FileManager.default.createSymbolicLink(at: liveRoot, withDestinationURL: externalRoot)

        let manager = SessionArchiveManager.shared
        manager.pinSessionForTesting(session)

        XCTAssertNil(manager.archiveInfoForTesting(source: .cursor, id: session.id),
                     "direct ACP pinning must fail closed when the current session directory is a symlink")
    }

    func testACPIncompleteArchiveDoesNotBecomeFinalWhenUpstreamDisappears() throws {
        let liveURL = try writeTempACPStore()
        let walURL = URL(fileURLWithPath: liveURL.path + "-wal")
        try Data("wal companion".utf8).write(to: walURL, options: .atomic)
        let appSupport = temporarySupportRoot("ACPIncompleteArchive")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let archivedWAL = URL(fileURLWithPath: archivedURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedWAL.path))
        try FileManager.default.removeItem(at: archivedWAL)
        try FileManager.default.removeItem(at: liveURL.deletingLastPathComponent())

        manager.syncSessionForTesting(live)

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertEqual(info.status, .error)
        XCTAssertTrue(info.lastError?.contains("incomplete") == true)
        XCTAssertFalse(CursorACPStoreReader.isACPStore(archivedURL),
                       "an archive missing a manifest-recorded WAL must not be publishable")
    }

    func testACPTamperedArchiveMetadataCannotRedirectFallbackPath() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPTamperedMetadata")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let metadataURL = sessionRoot.appendingPathComponent("meta.json", isDirectory: false)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["primaryRelativePath"] = "../../outside/store.db"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)

        XCTAssertNil(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertFalse(CursorACPStoreReader.isACPStore(archiveStoreURL(for: live, appSupport: appSupport)))
    }

    func testACPArchiveRejectsManifestByteAndCompanionTampering() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPManifestTamper")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let originalStore = try Data(contentsOf: archivedURL)

        try Data("different regular bytes".utf8).write(to: archivedURL, options: .atomic)
        XCTAssertFalse(CursorACPStoreReader.isACPStore(archivedURL),
                       "archive admission must verify manifest bytes, not only file type")

        try originalStore.write(to: archivedURL, options: .atomic)
        let unexpectedWAL = URL(fileURLWithPath: archivedURL.path + "-wal")
        try Data("unmanifested companion".utf8).write(to: unexpectedWAL, options: .atomic)
        XCTAssertFalse(CursorACPStoreReader.isACPStore(archivedURL),
                       "an unmanifested SQLite companion must not be admitted")
    }

    func testACPSyncRebindsTamperedUpstreamToCurrentConfiguredRoot() throws {
        let sessionUUID = UUID().uuidString.lowercased()
        let archivedSourceURL = try writeTempACPStore(sessionID: sessionUUID)
        let tamperedSourceURL = try writeTempACPStore(sessionID: sessionUUID)
        let currentSourceURL = try writeTempACPStore(sessionID: sessionUUID)
        let currentRoot = currentSourceURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPUpstreamRebind")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(archivedSourceURL)
            cleanupTemp(tamperedSourceURL)
            cleanupTemp(currentSourceURL)
            cleanupTemp(appSupport)
        }

        let archived = try XCTUnwrap(CursorACPStoreReader.parse(at: archivedSourceURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(archived)
        let metadataURL = archiveRoot
            .appendingPathComponent(archived.id, isDirectory: true)
            .appendingPathComponent("meta.json", isDirectory: false)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["upstreamPath"] = tamperedSourceURL.deletingLastPathComponent().path
        metadata["upstreamIsDirectory"] = true
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)

        UserDefaults.standard.set(currentRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: archived.id, source: .cursor)
        manager.syncPinnedSessionsForTesting()

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: archived.id))
        XCTAssertEqual(info.upstreamPath, currentSourceURL.deletingLastPathComponent().path,
                       "periodic ACP sync must rebind to the current configured root")
    }

    func testACPIndexDBBackfillRejectsSymlinkedConfiguredRoot() throws {
        let liveURL = try writeTempACPStore()
        let realRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let symlinkParent = temporarySupportRoot("ACPSymlinkedRoot")
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: true)
        let configuredRoot = symlinkParent.appendingPathComponent("linked-cursor", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: configuredRoot, withDestinationURL: realRoot)
        let appSupport = temporarySupportRoot("ACPSymlinkedRootIndex")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        UserDefaults.standard.set(configuredRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(symlinkParent)
            cleanupTemp(appSupport)
        }

        let id = "cursor-acp:\(acpSessionID)"
        try writeIndexDBRow(at: appSupport, sessionID: id, sourcePath: liveURL.path)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: id, source: .cursor)

        SessionArchiveManager.shared.syncPinnedSessionsForTesting()

        XCTAssertNil(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: id),
                     "IndexDB must not bypass the configured-root symlink boundary")
    }

    func testACPArchiveRejectsRegularFileReplacementBetweenSnapshotAndCopy() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(sessionID: acpSessionID)
        let appSupport = temporarySupportRoot("ACPRegularFileRace")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        let backupURL = URL(fileURLWithPath: liveURL.path + ".original")
        defer {
            SessionArchiveManagerTestHooks.preCopyHook = nil
            SessionArchiveManagerTestHooks.postCopyHook = nil
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: liveURL)
                try? FileManager.default.moveItem(at: backupURL, to: liveURL)
            }
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archiveDataRoot = archiveRoot
            .appendingPathComponent(live.id, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        let dataBefore = try regularFileBytes(in: archiveDataRoot)
        try writeACPMetadata(to: liveURL, name: "regular-file-race")

        SessionArchiveManagerTestHooks.preCopyHook = {
            try? FileManager.default.moveItem(at: liveURL, to: backupURL)
            try? FileManager.default.copyItem(at: replacementURL, to: liveURL)
        }
        SessionArchiveManagerTestHooks.postCopyHook = {
            if FileManager.default.fileExists(atPath: liveURL.path) {
                try? FileManager.default.removeItem(at: liveURL)
            }
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.moveItem(at: backupURL, to: liveURL)
            }
        }

        manager.syncSessionForTesting(live)

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertEqual(info.status, .error,
                       "a regular-file replacement must fail closed instead of committing a stable-looking copy")
        XCTAssertEqual(try regularFileBytes(in: archiveDataRoot), dataBefore)
    }

    func testACPLiveSidecarSymlinkIsRejected() throws {
        let url = try writeTempACPStore()
        let sidecar = url.deletingLastPathComponent().appendingPathComponent("meta.json")
        let escaped = url.deletingLastPathComponent().appendingPathComponent("escaped-meta.json")
        try Data("{\"schemaVersion\":1,\"cwd\":\"/tmp/escaped\"}".utf8).write(to: escaped,
                                                                         options: .atomic)
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: escaped)
        defer { cleanupTemp(url) }

        XCTAssertFalse(CursorACPStoreReader.isACPStore(url))
        XCTAssertNil(CursorACPStoreReader.parse(at: url))
    }

    func testACPArchiveRechecksCompanionSetWhenWALAppearsDuringCopy() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveWALAppearance")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.postCopyHook = nil
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(live)
        try writeACPMetadata(to: liveURL, name: "wal-appeared")

        var postCopyCount = 0
        SessionArchiveManagerTestHooks.postCopyHook = {
            postCopyCount += 1
            if postCopyCount == 1 {
                try? Data("wal appeared".utf8)
                    .write(to: URL(fileURLWithPath: liveURL.path + "-wal"), options: .atomic)
            }
        }
        SessionArchiveManager.shared.syncSessionForTesting(live)

        XCTAssertEqual(postCopyCount, 2,
                       "a companion appearing after the first copy must force a retry")
        let manifestURL = archiveRoot
            .appendingPathComponent(live.id, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(SessionArchiveManifest.self,
                                                  from: Data(contentsOf: manifestURL))
        XCTAssertTrue(manifest.entries.contains { $0.relativePath == "store.db-wal" })
    }

    func testACPArchiveFailsClosedDuringContinuousSidecarChurn() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveChurn")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.postCopyHook = nil
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        SessionArchiveManager.shared.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)
        try writeACPMetadata(to: liveURL, name: "pre-churn")

        var postCopyCount = 0
        SessionArchiveManagerTestHooks.postCopyHook = {
            postCopyCount += 1
            let name = "churn-\(postCopyCount)"
            try? self.writeACPMetadata(to: liveURL, name: name)
        }
        SessionArchiveManager.shared.syncSessionForTesting(live)

        XCTAssertEqual(postCopyCount, 4)
        let info = try XCTUnwrap(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor,
                                                                                    id: live.id))
        XCTAssertEqual(info.status, .error)
        XCTAssertTrue(info.lastError?.contains("updating continuously") == true)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore)
    }

    func testACPArchivePathOutsideControlledRootIsRejected() throws {
        let liveURL = try writeTempACPStore()
        let fakeRoot = temporarySupportRoot("ArchiveOutsideRoot")
        let fakeData = fakeRoot
            .appendingPathComponent("AgentSessions/Archives/cursor", isDirectory: true)
            .appendingPathComponent("cursor-acp:\(acpSessionID)", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeData, withIntermediateDirectories: true)
        let fakeStore = fakeData.appendingPathComponent("store.db", isDirectory: false)
        try FileManager.default.copyItem(at: liveURL, to: fakeStore)
        defer {
            cleanupTemp(liveURL)
            cleanupTemp(fakeRoot)
        }

        XCTAssertFalse(CursorACPStoreReader.isACPStore(fakeStore))
    }

    func testACPArchiveSyncDoesNotWriteThroughArchivedSessionSymlink() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveSessionSymlink")
        let externalSupport = temporarySupportRoot("ArchiveSessionSymlinkExternal")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
            cleanupTemp(externalSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let externalSessionRoot = externalSupport.appendingPathComponent("moved-session", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSupport, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sessionRoot, to: externalSessionRoot)
        try FileManager.default.createSymbolicLink(at: sessionRoot, withDestinationURL: externalSessionRoot)
        let metadataURL = externalSessionRoot.appendingPathComponent("meta.json", isDirectory: false)
        let metadataBefore = try Data(contentsOf: metadataURL)

        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)
        try FileManager.default.removeItem(at: liveURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: cursorRoot.appendingPathComponent("acp-sessions", isDirectory: true),
                                                withIntermediateDirectories: true)

        manager.syncPinnedSessionsForTesting()

        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore,
                       "archive sync must not follow a substituted session directory")
        XCTAssertNil(manager.archiveInfoForTesting(source: .cursor, id: live.id),
                     "a symlinked archive session must not be trusted as archive metadata")
    }

    func testACPArchiveDeleteDoesNotFollowSessionSymlink() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ArchiveDeleteSessionSymlink")
        let externalSupport = temporarySupportRoot("ArchiveDeleteSessionSymlinkExternal")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
            cleanupTemp(externalSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let externalSessionRoot = externalSupport.appendingPathComponent("moved-session", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSupport, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sessionRoot, to: externalSessionRoot)
        try FileManager.default.createSymbolicLink(at: sessionRoot, withDestinationURL: externalSessionRoot)
        let metadataURL = externalSessionRoot.appendingPathComponent("meta.json", isDirectory: false)
        let metadataBefore = try Data(contentsOf: metadataURL)

        manager.deleteArchiveForTesting(source: .cursor, id: live.id)

        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore,
                       "archive deletion must not remove or alter a directory reached through a substituted symlink")
        var linkStat = stat()
        XCTAssertNotEqual(lstat(sessionRoot.path, &linkStat), 0,
                          "the substituted archive entry may be unlinked, but its target must remain untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalSessionRoot.path))
    }

    func testACPArchiveSyncRejectsLiveRootSymlinkSubstitution() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(sessionID: acpSessionID)
        let appSupport = temporarySupportRoot("ArchiveSymlinkReplacement")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)

        let liveRoot = liveURL.deletingLastPathComponent()
        let replacementRoot = replacementURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: liveRoot)
        try FileManager.default.createSymbolicLink(at: liveRoot, withDestinationURL: replacementRoot)

        manager.syncSessionForTesting(live)

        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore,
                       "a substituted live root must not replace the healthy archive")
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore)
        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertEqual(info.status, .error)
    }

    func testACPStoreReaderRejectsUnknownSchemaVersion() throws {
        let url = try writeTempACPStore(schemaVersion: 2)
        defer { cleanupTemp(url) }

        XCTAssertNil(CursorACPStoreReader.parse(at: url))
    }

    func testACPStoreReaderRejectsMalformedReferencedBlobInsteadOfPublishingPartialEvents() throws {
        let malformedTurn = Data([UInt8(0x08), UInt8(0x80)]) // truncated varint
        let turnID = contentID(for: malformedTurn)
        let rootData = proto(8, turnID)
        let rootID = contentID(for: rootData)
        let url = try writeTempACPStore(blobs: [
            rootID.hexString: rootData,
            turnID.hexString: malformedTurn
        ], rootBlobID: rootID.hexString)
        defer { cleanupTemp(url) }

        XCTAssertNil(CursorACPStoreReader.parse(at: url), "a malformed graph edge must fail closed")
    }

    func testACPDiscoveryTreatsEmptyRootAsAuthoritativeAndMissingRootAsIndeterminate() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("acp-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let discovery = CursorSessionDiscovery(customRoot: base.path)
        XCTAssertEqual(discovery.discoverACPSessionDBs(), [])
        try FileManager.default.removeItem(at: root)
        XCTAssertNil(discovery.discoverACPSessionDBs())
    }

    func testACPDiscoveryTreatsSymlinkedSessionsRootAsIndeterminate() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
        let external = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor_test_external_\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("acp-sessions", isDirectory: true)
        let externalRoot = external.appendingPathComponent("acp-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: externalRoot)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: external)
        }

        XCTAssertNil(CursorSessionDiscovery(customRoot: base.path).discoverACPSessionDBs(),
                     "a symlinked ACP root must not be treated as an authoritative empty directory")
    }

    func testACPDiscoverySkipsIncompleteUUIDDirectory() throws {
        let tempPath = NSTemporaryDirectory()
        let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
        let base = URL(fileURLWithPath: canonicalTempPath)
            .appendingPathComponent("cursor_test_\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("acp-sessions", isDirectory: true)
        let incomplete = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let validURL = try writeTempACPStore(sessionID: UUID().uuidString.lowercased())
        let validSession = validURL.deletingLastPathComponent()
        let validTarget = root.appendingPathComponent(validSession.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: validSession, to: validTarget)
        defer {
            cleanupTemp(validURL)
            try? FileManager.default.removeItem(at: base)
        }

        let found = CursorSessionDiscovery(customRoot: base.path).discoverACPSessionDBs()
        XCTAssertEqual(found?.map { $0.resolvingSymlinksInPath().standardizedFileURL },
                       [validTarget.appendingPathComponent("store.db")
                           .resolvingSymlinksInPath().standardizedFileURL])
    }

    func testACPDiscoveryPreservesAuthorityWhenRootChangesDuringScan() throws {
        let storeURL = try writeTempACPStore()
        let cursorRoot = storeURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let acpRoot = cursorRoot.appendingPathComponent("acp-sessions", isDirectory: true)
        let movedRoot = cursorRoot.appendingPathComponent("acp-sessions-original", isDirectory: true)
        let replacementRoot = cursorRoot.appendingPathComponent("acp-sessions-replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)

        let previousHook = CursorSessionDiscovery.boundACPRootHook
        defer {
            CursorSessionDiscovery.boundACPRootHook = previousHook
            cleanupTemp(storeURL)
        }
        CursorSessionDiscovery.boundACPRootHook = { _ in
            try? FileManager.default.moveItem(at: acpRoot, to: movedRoot)
            try? FileManager.default.createSymbolicLink(at: acpRoot, withDestinationURL: replacementRoot)
        }

        XCTAssertNil(CursorSessionDiscovery(customRoot: cursorRoot.path).discoverACPSessionDBs(),
                     "a root replacement during enumeration is indeterminate, not authoritative empty discovery")
    }

    func testACPDiscoveryRejectsAncestorSymlinkReplacementBeforePublishingPaths() throws {
        let storeURL = try writeTempACPStore()
        let cursorRoot = storeURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let displacedCursorRoot = cursorRoot.deletingLastPathComponent()
            .appendingPathComponent("cursor-ancestor-original-\(UUID().uuidString)",
                                    isDirectory: true)
        var didReplaceAncestor = false
        let previousHook = CursorSessionDiscovery.boundACPRootHook
        defer {
            CursorSessionDiscovery.boundACPRootHook = previousHook
            if didReplaceAncestor {
                try? FileManager.default.removeItem(at: cursorRoot)
                try? FileManager.default.moveItem(at: displacedCursorRoot, to: cursorRoot)
            }
            cleanupTemp(storeURL)
        }

        CursorSessionDiscovery.boundACPRootHook = { _ in
            do {
                try FileManager.default.moveItem(at: cursorRoot, to: displacedCursorRoot)
                try FileManager.default.createSymbolicLink(at: cursorRoot,
                                                            withDestinationURL: displacedCursorRoot)
                didReplaceAncestor = true
            } catch {
                didReplaceAncestor = false
            }
        }

        XCTAssertNil(
            CursorSessionDiscovery(customRoot: cursorRoot.path).discoverACPSessionDBs(),
            "an ancestor symlink replacement must not publish URLs across the substituted boundary"
        )
        XCTAssertTrue(didReplaceAncestor, "ancestor replacement seam was not reached")
    }

    func testACPDiscoveryTreatsAdmissionFailureAsIndeterminate() throws {
        let storeURL = try writeTempACPStore()
        let cursorRoot = storeURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previousHook = CursorACPStoreReader.liveStoreAdmissionUnavailableHook
        defer {
            CursorACPStoreReader.liveStoreAdmissionUnavailableHook = previousHook
            cleanupTemp(storeURL)
        }

        CursorACPStoreReader.liveStoreAdmissionUnavailableHook = { true }

        XCTAssertNil(CursorSessionDiscovery(customRoot: cursorRoot.path).discoverACPSessionDBs(),
                     "an admission I/O failure after store.db exists must preserve the prior projection")
    }

    func testACPDiscoveryAcceptsRawMacOSSystemAliases() throws {
        let tempPath = NSTemporaryDirectory()
        let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private\(tempPath)" : tempPath
        let aliases = [(canonicalTempPath, tempPath), ("/private/tmp", "/tmp")]
        var sourceURLs: [URL] = []
        var canonicalRoots: [URL] = []
        defer {
            sourceURLs.forEach(cleanupTemp)
            for root in canonicalRoots {
                let resolved = root.resolvingSymlinksInPath().standardizedFileURL
                if FileManager.default.fileExists(atPath: resolved.path) {
                    try? FileManager.default.removeItem(at: resolved)
                }
            }
        }

        for (canonicalPrefix, aliasPrefix) in aliases {
            let sessionID = UUID().uuidString.lowercased()
            let sourceURL = try writeTempACPStore(sessionID: sessionID)
            sourceURLs.append(sourceURL)
            let canonicalRoot = URL(fileURLWithPath: canonicalPrefix)
                .appendingPathComponent("cursor_alias_\(UUID().uuidString)", isDirectory: true)
            canonicalRoots.append(canonicalRoot)
            let targetSession = canonicalRoot
                .appendingPathComponent("acp-sessions", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try FileManager.default.createDirectory(at: targetSession.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL.deletingLastPathComponent(), to: targetSession)

            let rawRootPath = aliasPrefix + String(canonicalRoot.path.dropFirst(canonicalPrefix.count))
            let discovered = CursorSessionDiscovery(customRoot: rawRootPath).discoverACPSessionDBs()
            XCTAssertEqual(discovered?.map { $0.resolvingSymlinksInPath().standardizedFileURL },
                           [targetSession.appendingPathComponent("store.db")
                               .resolvingSymlinksInPath().standardizedFileURL],
                           "raw \(aliasPrefix) should normalize to its macOS canonical path")
        }
    }

    func testACPDiscoveryRejectsSymlinkedSessionDirectory() throws {
        let url = try writeTempACPStore()
        let base = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let customRoot = base.appendingPathComponent("custom-cursor", isDirectory: true)
        let acpRoot = customRoot.appendingPathComponent("acp-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: acpRoot, withIntermediateDirectories: true)
        let linkedSession = acpRoot.appendingPathComponent("11111111-1111-1111-1111-111111111111", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSession,
                                                    withDestinationURL: url.deletingLastPathComponent())
        defer { cleanupTemp(url) }

        XCTAssertEqual(CursorSessionDiscovery(customRoot: customRoot.path).discoverACPSessionDBs(), [])
    }

    func testACPSurfaceIsNotClassifiedAsLegacyDBOnly() throws {
        let url = try writeTempACPStore()
        defer { cleanupTemp(url) }

        guard let session = CursorACPStoreReader.parse(at: url) else {
            return XCTFail("ACP store should parse")
        }
        XCTAssertFalse(CursorSessionIndexer.isDBOnlySession(session))
    }

    @MainActor
    func testCursorRefreshKeepsLiveACPAuthorityOverPinnedArchiveFallback() async throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("LiveACPAuthority")
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Agents.cursorEnabled)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        UserDefaults.standard.set(true, forKey: PreferencesKey.Agents.cursorEnabled)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            if let oldOverride { UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride) }
            else { UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride) }
            if let oldEnabled { UserDefaults.standard.set(oldEnabled, forKey: PreferencesKey.Agents.cursorEnabled) }
            else { UserDefaults.standard.removeObject(forKey: PreferencesKey.Agents.cursorEnabled) }
            if let oldFavorites { UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey) }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)

        let indexer = CursorSessionIndexer()
        indexer.refresh(mode: .fullReconcile, trigger: .manual)
        let deadline = Date().addingTimeInterval(5)
        while indexer.launchPhase != .ready && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let matches = indexer.allSessions.filter { $0.id == live.id }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.filePath, live.filePath,
                       "a live ACP store must outrank the pinned archive fallback")
        XCTAssertEqual(matches.first?.surface, .acp)
    }

    @MainActor
    func testCursorRefreshPreservesACPProjectionAcrossEquivalentRootSpellings() async throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let canonicalRoot = CursorBackendDetector.cursorRoot(customRoot: cursorRoot.path).path
        let rawRoot = canonicalRoot.hasPrefix("/private/tmp/")
            ? "/tmp" + String(canonicalRoot.dropFirst("/private/tmp".count))
            : canonicalRoot
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldEnabled = UserDefaults.standard.object(forKey: PreferencesKey.Agents.cursorEnabled)
        UserDefaults.standard.set(rawRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        UserDefaults.standard.set(true, forKey: PreferencesKey.Agents.cursorEnabled)
        defer {
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldEnabled {
                UserDefaults.standard.set(oldEnabled, forKey: PreferencesKey.Agents.cursorEnabled)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Agents.cursorEnabled)
            }
            cleanupTemp(liveURL)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let indexer = CursorSessionIndexer()
        indexer.refresh(mode: .fullReconcile, trigger: .manual)
        var deadline = Date().addingTimeInterval(5)
        while indexer.launchPhase != .ready && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(indexer.allSessions.first(where: { $0.id == live.id }))

        let acpRoot = cursorRoot.appendingPathComponent("acp-sessions", isDirectory: true)
        try FileManager.default.removeItem(at: acpRoot)
        try Data("temporarily unavailable".utf8).write(to: acpRoot, options: .atomic)

        UserDefaults.standard.set(canonicalRoot, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        indexer.refresh(mode: .fullReconcile, trigger: .manual)
        deadline = Date().addingTimeInterval(5)
        while indexer.isIndexing && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertNotNil(indexer.allSessions.first(where: { $0.id == live.id }),
                        "equivalent root spellings must not clear the prior ACP projection during an unavailable refresh")
        XCTAssertEqual(CursorSessionIndexer.normalizedCursorAuthorityPath(for: rawRoot),
                       CursorSessionIndexer.normalizedCursorAuthorityPath(for: canonicalRoot))
    }

    func testACPPinnedSyncMarksAuthoritativeCurrentRootAbsenceWithoutUsingStalePath() throws {
        let liveURL = try writeTempACPStore()
        let replacementURL = try writeTempACPStore(sessionID: acpSessionID)
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPCurrentRootAbsence")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let dataBefore = try regularFileBytes(in: dataRoot)

        let metadataURL = sessionRoot.appendingPathComponent("meta.json", isDirectory: false)
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["upstreamPath"] = replacementURL.deletingLastPathComponent().path
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)

        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)
        try FileManager.default.removeItem(at: liveURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: cursorRoot.appendingPathComponent("acp-sessions", isDirectory: true),
                                                withIntermediateDirectories: true)

        manager.syncPinnedSessionsForTesting()

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertTrue(info.upstreamMissing)
        XCTAssertEqual(info.status, .final)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore,
                       "authoritative absence must not resnapshot from stale archive metadata")
    }

    func testACPPinnedSyncDoesNotRecreateArchiveDeletedBeforeMutationLock() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPArchiveDeletedBeforeLock")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousLockHook = SessionArchiveManagerTestHooks.beforeArchiveMutationLockHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.beforeArchiveMutationLockHook = previousLockHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionRoot.path))

        try FileManager.default.removeItem(at: liveURL.deletingLastPathComponent())
        try FileManager.default.createDirectory(
            at: cursorRoot.appendingPathComponent("acp-sessions", isDirectory: true),
            withIntermediateDirectories: true
        )

        var didReplaceArchive = false
        SessionArchiveManagerTestHooks.beforeArchiveMutationLockHook = {
            guard !didReplaceArchive else { return }
            didReplaceArchive = true
            try? FileManager.default.removeItem(at: sessionRoot)
            SessionArchiveManagerTestHooks.beforeArchiveMutationLockHook = nil
        }

        manager.syncPinnedSessionsForTesting()

        XCTAssertTrue(didReplaceArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path),
                       "a stale absence observation must not recreate a deleted archive")
        XCTAssertNil(manager.archiveInfoForTesting(source: .cursor, id: live.id))
    }

    func testACPPinnedSyncPreservesArchiveWhenCurrentStoreCannotParse() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPParseUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride { UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride) }
            else { UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride) }
            if let oldFavorites { UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey) }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)

        try Data("not a SQLite database".utf8).write(to: liveURL, options: .atomic)
        manager.syncPinnedSessionsForTesting()

        let info = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertFalse(info.upstreamMissing,
                       "an existing but unreadable store is unavailable, not authoritative absence")
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore,
                       "an unreadable live store must not replace a healthy archive")
    }

    func testACPPinnedSyncPreservesArchiveWhenAuthorityRecheckIsUnavailable() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPAuthorityRecheckUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousAdmissionHook = CursorACPStoreReader.liveStoreAdmissionUnavailableHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            CursorACPStoreReader.liveStoreAdmissionUnavailableHook = previousAdmissionHook
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)
        let before = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))

        var admissionCalls = 0
        CursorACPStoreReader.liveStoreAdmissionUnavailableHook = {
            admissionCalls += 1
            return admissionCalls >= 6
        }
        manager.syncPinnedSessionsForTesting()

        let after = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))
        XCTAssertGreaterThanOrEqual(admissionCalls, 6,
                                    "sync must re-resolve the live ACP authority before checking existence")
        XCTAssertEqual(after, before,
                       "an unavailable authority recheck must preserve archive metadata and state")
    }

    func testACPPinnedSyncPreservesArchiveWhenAuthorityBecomesUnavailableBeforeCommit() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let unavailableRoot = temporarySupportRoot("ACPAuthorityBeforeCommitUnavailableRoot")
        let appSupport = temporarySupportRoot("ACPAuthorityBeforeCommitUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousPreSnapshotHook = SessionArchiveManagerTestHooks.preSnapshotHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.preSnapshotHook = previousPreSnapshotHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(unavailableRoot)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)
        let infoBefore = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))

        try writeACPMetadata(to: liveURL, name: "authority-outage-before-commit")
        var authorityUnavailable = false
        SessionArchiveManagerTestHooks.preSnapshotHook = {
            authorityUnavailable = true
            UserDefaults.standard.set(unavailableRoot.path,
                                      forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        }

        manager.pinSessionForTesting(live)

        XCTAssertTrue(authorityUnavailable)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore)
        XCTAssertEqual(manager.archiveInfoForTesting(source: .cursor, id: live.id), infoBefore,
                       "a late authority outage must restore the original metadata")
    }

    func testACPPinnedSyncPreservesArchiveWhenAuthorityBecomesUnavailableDuringCommit() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let unavailableRoot = temporarySupportRoot("ACPAuthorityDuringCommitUnavailableRoot")
        let appSupport = temporarySupportRoot("ACPAuthorityDuringCommitUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousCommitHook = SessionArchiveManagerTestHooks.beforeCommitRenameHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.beforeCommitRenameHook = previousCommitHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(unavailableRoot)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let manifestURL = sessionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        let dataRoot = sessionRoot.appendingPathComponent("data", isDirectory: true)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let dataBefore = try regularFileBytes(in: dataRoot)
        let infoBefore = try XCTUnwrap(manager.archiveInfoForTesting(source: .cursor, id: live.id))

        try writeACPMetadata(to: liveURL, name: "authority-outage-during-commit")
        var authorityUnavailable = false
        SessionArchiveManagerTestHooks.beforeCommitRenameHook = {
            authorityUnavailable = true
            UserDefaults.standard.set(unavailableRoot.path,
                                      forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        }

        manager.pinSessionForTesting(live)

        XCTAssertTrue(authorityUnavailable)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try regularFileBytes(in: dataRoot), dataBefore)
        XCTAssertEqual(manager.archiveInfoForTesting(source: .cursor, id: live.id), infoBefore,
                       "a post-install authority outage must restore the original metadata")
    }

    func testACPPinDoesNotPersistPlaceholderBeforeUnavailableAuthoritySync() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSupport = temporarySupportRoot("ACPPinPlaceholderAuthorityUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousAdmissionHook = CursorACPStoreReader.liveStoreAdmissionUnavailableHook
        let previousSemanticHook = CursorACPStoreReader.liveParseBeforeSemanticParseHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            CursorACPStoreReader.liveStoreAdmissionUnavailableHook = previousAdmissionHook
            CursorACPStoreReader.liveParseBeforeSemanticParseHook = previousSemanticHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        var authorityUnavailable = false
        CursorACPStoreReader.liveStoreAdmissionUnavailableHook = { authorityUnavailable }
        CursorACPStoreReader.liveParseBeforeSemanticParseHook = {
            authorityUnavailable = true
        }

        SessionArchiveManager.shared.pinSessionForTesting(live)

        XCTAssertTrue(authorityUnavailable)
        XCTAssertNil(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: live.id),
                     "an unavailable first sync must not leave a disk placeholder")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: archiveRoot.appendingPathComponent(live.id, isDirectory: true).path
        ))
    }

    func testACPPinDoesNotLeaveCanonicalStagingMetadataAfterLateFirstSyncFailure() throws {
        let liveURL = try writeTempACPStore()
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let unavailableRoot = temporarySupportRoot("ACPLateFirstSyncUnavailableRoot")
        let appSupport = temporarySupportRoot("ACPLateFirstSyncUnavailable")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let previousValidationHook = SessionArchiveManagerTestHooks.afterStagedValidationHook
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.afterStagedValidationHook = previousValidationHook
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(unavailableRoot)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        var didReachPostValidation = false
        SessionArchiveManagerTestHooks.afterStagedValidationHook = { _ in
            guard !didReachPostValidation else { return }
            didReachPostValidation = true
            UserDefaults.standard.set(unavailableRoot.path,
                                      forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        }

        SessionArchiveManager.shared.pinSessionForTesting(live)

        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        XCTAssertTrue(didReachPostValidation)
        XCTAssertNil(SessionArchiveManager.shared.archiveInfoForTesting(source: .cursor, id: live.id),
                     "a failed first sync must not leave canonical .staging metadata")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionRoot.path))
    }

    func testACPArchiveMetadataCannotDowngradeNamespacedIdentity() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPMetadataDowngrade")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let sessionRoot = archiveRoot.appendingPathComponent(live.id, isDirectory: true)
        let metadataURL = sessionRoot.appendingPathComponent("meta.json", isDirectory: false)
        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let dataBefore = try regularFileBytes(in: sessionRoot.appendingPathComponent("data", isDirectory: true))
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["surface"] = NSNull()
        metadata["upstreamIsDirectory"] = false
        metadata["upstreamPath"] = "/tmp/attacker-controlled-store"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL, options: .atomic)

        XCTAssertNil(manager.archiveInfoForTesting(source: .cursor, id: live.id),
                     "downgraded ACP metadata must not validate as a generic Cursor archive")
        XCTAssertFalse(CursorACPStoreReader.isACPStore(archivedURL))
        XCTAssertEqual(try regularFileBytes(in: sessionRoot.appendingPathComponent("data", isDirectory: true)), dataBefore)
    }

    func testFocusedReloadHydratesArchiveOnlyACPProjection() throws {
        let liveURL = try writeTempACPStore()
        let appSupport = temporarySupportRoot("ACPArchiveOnlyReload")
        let archiveRoot = archiveRoot(for: appSupport)
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        let archivedURL = archiveRoot
            .appendingPathComponent(live.id, isDirectory: true)
            .appendingPathComponent("data/store.db", isDirectory: false)
        let fallback = Session(id: live.id,
                               source: .cursor,
                               startTime: live.startTime,
                               endTime: live.endTime,
                               model: live.model,
                               filePath: archivedURL.path,
                               fileSizeBytes: live.fileSizeBytes,
                               eventCount: live.eventCount,
                               events: [],
                               cwd: live.cwd,
                               repoName: live.repoName,
                               lightweightTitle: live.lightweightTitle,
                               lightweightCommands: live.lightweightCommands,
                               originator: "cursor-agent",
                               originSource: "acp-persisted",
                               surface: .acp)

        let indexer = CursorSessionIndexer()
        indexer.installSessionsForReloadTesting([fallback])
        let hydrated = expectation(description: "archive-only ACP hydration")
        var cancellable: AnyCancellable?
        cancellable = indexer.$allSessions.sink { sessions in
            if sessions.first?.events.isEmpty == false {
                hydrated.fulfill()
            }
        }
        indexer.reloadSession(id: live.id, reason: .selection)
        wait(for: [hydrated], timeout: 3)
        cancellable?.cancel()

        XCTAssertFalse(indexer.allSessions.first?.events.isEmpty ?? true,
                       "focused reload must parse a complete archive-only ACP fallback")
    }

    func testFocusedReloadDiscardsACPResultAfterConfiguredRootChanges() throws {
        let liveURL = try writeTempACPStore(assistantText: "old-root")
        let replacementURL = try writeTempACPStore(
            sessionID: acpSessionID,
            assistantText: "new-root"
        )
        let liveRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let replacementRoot = replacementURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let previousHook = CursorACPStoreReader.liveParseBeforeSemanticParseHook
        defer {
            CursorACPStoreReader.liveParseBeforeSemanticParseHook = previousHook
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            cleanupTemp(liveURL)
            cleanupTemp(replacementURL)
        }

        UserDefaults.standard.set(replacementRoot.path,
                                  forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let replacement = try XCTUnwrap(CursorACPStoreReader.parse(at: replacementURL))
        UserDefaults.standard.set(liveRoot.path,
                                  forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))

        let existing = Session(id: live.id,
                               source: .cursor,
                               startTime: replacement.startTime,
                               endTime: replacement.endTime,
                               model: replacement.model,
                               filePath: live.filePath,
                               fileSizeBytes: replacement.fileSizeBytes,
                               eventCount: replacement.eventCount,
                               events: replacement.events,
                               cwd: replacement.cwd,
                               repoName: replacement.repoName,
                               lightweightTitle: replacement.lightweightTitle,
                               lightweightCommands: replacement.lightweightCommands,
                               originator: replacement.originator,
                               originSource: replacement.originSource,
                               surface: .acp)
        let indexer = CursorSessionIndexer()
        indexer.installSessionsForReloadTesting([existing])

        let rootTransition = expectation(description: "configured ACP root changes during reload")
        var didSwitch = false
        CursorACPStoreReader.liveParseBeforeSemanticParseHook = {
            guard !didSwitch else { return }
            didSwitch = true
            UserDefaults.standard.set(replacementRoot.path,
                                      forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            rootTransition.fulfill()
        }

        indexer.reloadSession(id: live.id, force: true, reason: .manualRefresh)
        wait(for: [rootTransition], timeout: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(indexer.allSessions.first?.events.map(\.text),
                       replacement.events.map(\.text),
                       "a focused reload from the superseded root must not publish its old snapshot")
    }

    func testFocusedReloadFallsBackToPinnedArchiveWhenLiveACPIsInvalid() throws {
        let liveURL = try writeTempACPStore(assistantText: "live-invalid")
        let appSupport = temporarySupportRoot("ACPInvalidLiveReloadFallback")
        let archiveRoot = archiveRoot(for: appSupport)
        let cursorRoot = liveURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previousSupport = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        let previousArchiveRoot = CursorACPStoreReader.archiveRootProvider
        let oldOverride = UserDefaults.standard.object(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        let oldFavorites = UserDefaults.standard.object(forKey: StarredSessionsStore.defaultsKey)
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { appSupport }
        CursorACPStoreReader.archiveRootProvider = { archiveRoot }
        UserDefaults.standard.set(cursorRoot.path,
                                  forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
        defer {
            SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = previousSupport
            CursorACPStoreReader.archiveRootProvider = previousArchiveRoot
            if let oldOverride {
                UserDefaults.standard.set(oldOverride, forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferencesKey.Paths.cursorSessionsRootOverride)
            }
            if let oldFavorites {
                UserDefaults.standard.set(oldFavorites, forKey: StarredSessionsStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StarredSessionsStore.defaultsKey)
            }
            cleanupTemp(liveURL)
            cleanupTemp(appSupport)
        }

        let live = try XCTUnwrap(CursorACPStoreReader.parse(at: liveURL))
        let manager = SessionArchiveManager.shared
        manager.syncSessionForTesting(live)
        var favorites = StarredSessionsStore()
        favorites.setStarred(true, id: live.id, source: .cursor)

        let archivedURL = archiveStoreURL(for: live, appSupport: appSupport)
        let metadataURL = liveURL.deletingLastPathComponent()
            .appendingPathComponent("meta.json", isDirectory: false)
        try FileManager.default.removeItem(at: metadataURL)

        let placeholder = Session(id: live.id,
                                  source: .cursor,
                                  startTime: live.startTime,
                                  endTime: live.endTime,
                                  model: live.model,
                                  filePath: liveURL.path,
                                  fileSizeBytes: live.fileSizeBytes,
                                  eventCount: live.eventCount,
                                  events: [],
                                  cwd: live.cwd,
                                  repoName: live.repoName,
                                  lightweightTitle: live.lightweightTitle,
                                  lightweightCommands: live.lightweightCommands,
                                  originator: "cursor-agent",
                                  originSource: "acp-persisted",
                                  surface: .acp)
        let indexer = CursorSessionIndexer()
        indexer.installSessionsForReloadTesting([placeholder])

        let hydrated = expectation(description: "invalid live ACP reload uses pinned archive")
        var cancellable: AnyCancellable?
        cancellable = indexer.$allSessions.sink { sessions in
            if let session = sessions.first,
               session.filePath == archivedURL.path,
               !session.events.isEmpty {
                hydrated.fulfill()
            }
        }

        indexer.reloadSession(id: live.id, force: true, reason: .manualRefresh)
        wait(for: [hydrated], timeout: 3)
        cancellable?.cancel()

        XCTAssertEqual(indexer.allSessions.first?.filePath, archivedURL.path)
        XCTAssertEqual(indexer.allSessions.first?.events.map(\.text), live.events.map(\.text))
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

    func testIsDBOnlySessionReturnsFalseForACPProvenance() {
        let session = Session(
            id: "cursor-acp:test-id",
            source: .cursor,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: "/Users/test/.cursor/acp-sessions/test-id/store.db",
            fileSizeBytes: nil,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            surface: .acp
        )
        XCTAssertFalse(CursorSessionIndexer.isDBOnlySession(session),
                       "ACP store rows are searchable persisted transcripts, not legacy metadata-only rows")
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
