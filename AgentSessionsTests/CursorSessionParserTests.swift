import XCTest
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

    func testInferCWDResolvesSimplePath() {
        // /Users and /tmp always exist on macOS
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "tmp")
        XCTAssertEqual(cwd, "/tmp")
    }

    func testInferCWDReturnsNilForNonexistentPath() {
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "nonexistent-path-that-does-not-exist-anywhere")
        XCTAssertNil(cwd)
    }

    func testInferCWDPreservesHyphenatedComponents() {
        // We can't guarantee a specific hyphenated directory exists on the test machine,
        // but we can verify the algorithm doesn't split /tmp into /t/m/p
        let cwd = CursorSessionParser.inferCWD(fromProjectDirName: "tmp")
        // If /tmp exists (it always does on macOS), the result should be exactly "/tmp"
        // not "/t/m/p" or similar
        if let cwd = cwd {
            XCTAssertEqual(cwd, "/tmp")
        }
    }

    func testInferCWDBestEffortReturnsDecodedPathWhenFinalDirectoryMissing() {
        let projectName = "Users-alexm-Repository-This-Path-Should-Not-Exist-For-Tests"
        let decoded = CursorSessionParser.inferCWDBestEffort(fromProjectDirName: projectName)
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
}
