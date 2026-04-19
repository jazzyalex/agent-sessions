import XCTest
import SQLite3
@testable import AgentSessions

final class SessionParserTests: XCTestCase {
    func fixtureURL(_ name: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        return bundle.url(forResource: name, withExtension: "jsonl")!
    }

    private func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    private func makeCodexHierarchySession(
        id: String,
        runtimeID: String,
        timestamp: String,
        cwd: String,
        parentSessionID: String? = nil,
        subagentType: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: .codex,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/tmp/rollout-\(timestamp)-\(runtimeID).jsonl",
            eventCount: 0,
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: id,
            codexInternalSessionIDHint: runtimeID,
            parentSessionID: parentSessionID,
            subagentType: subagentType
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

        let discovery = ClaudeSessionDiscovery(customRoot: root.path)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first.map(canonicalPath), canonicalPath(sessionURL))
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

    func testGeminiDiscoveryAcceptsNamedProjectDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Gemini-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let namedWithChats = root.appendingPathComponent("radio4j/chats", isDirectory: true)
        let namedWithoutChats = root.appendingPathComponent("radio-metadata-fr-scraper", isDirectory: true)
        let noiseDir = root.appendingPathComponent("bin/chats", isDirectory: true)
        try fm.createDirectory(at: namedWithChats, withIntermediateDirectories: true)
        try fm.createDirectory(at: namedWithoutChats, withIntermediateDirectories: true)
        try fm.createDirectory(at: noiseDir, withIntermediateDirectories: true)

        let chatsSession = namedWithChats.appendingPathComponent("session-1.json")
        let rootSession = namedWithoutChats.appendingPathComponent("session-2.json")
        let ignoredSession = noiseDir.appendingPathComponent("session-bin.json")

        try writeText("{}", to: chatsSession)
        try writeText("{}", to: rootSession)
        try writeText("{}", to: ignoredSession)

        let discovery = GeminiSessionDiscovery(customRoot: root.path)
        let found = Set(discovery.discoverSessionFiles().map(canonicalPath))

        XCTAssertTrue(found.contains(canonicalPath(chatsSession)))
        XCTAssertTrue(found.contains(canonicalPath(rootSession)))
        XCTAssertFalse(found.contains(canonicalPath(ignoredSession)))
    }

    func testOpenClawDiscoveryFindsAgentSessionFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-Discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let sessionsDir = root.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let live = sessionsDir.appendingPathComponent("live.jsonl")
        let lock = sessionsDir.appendingPathComponent("live.jsonl.lock")
        let deleted = sessionsDir.appendingPathComponent("live.jsonl.deleted.1")
        try writeText(#"{"type":"session"}"# + "\n", to: live)
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
}
