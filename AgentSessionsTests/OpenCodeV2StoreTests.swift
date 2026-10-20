import XCTest
import SQLite3
@testable import AgentSessions

/// OpenCode 2.0 writes sessions to `session_v2` + `session_message` and keeps
/// the v1 `session`/`message`/`part` tables in the same opencode.db. Row shapes
/// here mirror a real OpenCode 2.1.1 database (anomalyco/opencode
/// packages/schema/src/session-message.ts).
final class OpenCodeV2StoreTests: XCTestCase {
    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-OpenCodeV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = directory.appendingPathComponent("opencode.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Discovery

    func testListMergesV2AndUncopiedV1SessionsWithV2Winning() throws {
        try createV1Tables()
        try createV2Tables()
        try insertMigratedSession()
        try insertV1OnlySession()
        try insertNativeV2Session()

        XCTAssertTrue(OpenCodeBackendDetector.isSQLiteAvailable(customRoot: dbURL.path))
        let sessions = try XCTUnwrap(OpenCodeSqliteReader.listSessionsIfReadable(customRoot: dbURL.path))

        XCTAssertEqual(sessions.map(\.id), ["ses_native", "ses_migrated", "ses_v1_only"],
                       "one row per session, newest first")
        let migrated = try XCTUnwrap(sessions.first { $0.id == "ses_migrated" })
        XCTAssertEqual(migrated.customTitle, "Migrated title",
                       "the v2 copy is the row OpenCode 2.0 keeps updating")
        XCTAssertEqual(migrated.model, "v2-model")

        let native = try XCTUnwrap(sessions.first { $0.id == "ses_native" })
        XCTAssertEqual(native.cwd, "/tmp/v2repo")
        XCTAssertEqual(native.model, "deepseek-v4.1-flash-free")
        XCTAssertEqual(native.eventCount, 4, "user, two assistant steps, and shell; system and idle are not messages")
        XCTAssertEqual(native.customTitle, "Native v2 session")

        let v1Only = try XCTUnwrap(sessions.first { $0.id == "ses_v1_only" })
        XCTAssertEqual(v1Only.customTitle, "Not yet copied")
        XCTAssertEqual(v1Only.eventCount, 1)
    }

    func testDatabaseWithOnlyV2TablesIsReadable() throws {
        try createV2Tables()
        try insertNativeV2Session()

        XCTAssertTrue(OpenCodeBackendDetector.isSQLiteAvailable(customRoot: dbURL.path))
        let sessions = try XCTUnwrap(OpenCodeSqliteReader.listSessionsIfReadable(customRoot: dbURL.path))
        XCTAssertEqual(sessions.map(\.id), ["ses_native"])
        XCTAssertNotNil(OpenCodeSqliteReader.sessionUpdatedAt(customRoot: dbURL.path, sessionID: "ses_native"))
    }

    func testGeneratedDefaultTitleFallsBackToFirstUserText() throws {
        try createV2Tables()
        try insertNativeV2Session(title: "New session - 2026-10-20T19:14:36.000Z")

        let session = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertNil(session.customTitle)
        XCTAssertEqual(session.title, "so no more Big Pickle in opencode?")
    }

    // MARK: - Transcript

    func testFullSessionBuildsTranscriptFromSessionMessageRows() throws {
        try createV2Tables()
        try insertNativeV2Session()

        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_native"))
        let visible = full.events.filter { $0.kind != .meta }

        XCTAssertEqual(visible.first?.kind, .user)
        XCTAssertEqual(visible.first?.text, "so no more Big Pickle in opencode?")
        XCTAssertTrue(visible.contains { $0.kind == .assistant && $0.text == "Big Pickle is still listed." })

        let call = try XCTUnwrap(visible.first { $0.kind == .tool_call && $0.toolName == "execute" })
        XCTAssertTrue((call.toolInput ?? "").contains("tools.opencode.models"))
        let result = try XCTUnwrap(visible.first { $0.kind == .tool_result && $0.parentID == call.id })
        XCTAssertEqual(result.toolOutput, "{\"providers\":[]}")

        let failed = try XCTUnwrap(visible.first { $0.kind == .error && $0.toolName == "read" })
        XCTAssertEqual(failed.text, "File not found: /tmp/missing.swift")

        let shell = try XCTUnwrap(visible.first { $0.kind == .tool_call && $0.toolName == "shell" })
        XCTAssertTrue((shell.toolInput ?? "").contains("git status"))
        let shellResult = try XCTUnwrap(visible.first { $0.kind == .tool_result && $0.parentID == shell.id })
        // 2.x stores shell output as a page object; the transcript shows its text.
        XCTAssertEqual(shellResult.toolOutput, "nothing to commit, working tree clean\nExit Code: 0")
        XCTAssertFalse((shellResult.toolOutput ?? "").contains("cursor"))

        XCTAssertFalse(visible.contains { ($0.text ?? "").contains("The available tools have changed") },
                       "system rows are model-facing context, not conversation")
        XCTAssertTrue(full.events.contains { $0.kind == .meta && $0.text == "[OpenCode part: system]" })
        XCTAssertTrue(full.events.contains { $0.kind == .meta && $0.text == "[OpenCode part: idle]" })
        XCTAssertFalse(visible.contains { ($0.text ?? "").isEmpty && $0.kind == .assistant },
                       "no blank assistant rows")
        XCTAssertEqual(full.model, "deepseek-v4.1-flash-free")
        XCTAssertEqual(full.lightweightCommands, 3)
    }

    func testMigratedSessionLoadsFromV2CopyNotV1Rows() throws {
        try createV1Tables()
        try createV2Tables()
        try insertMigratedSession()

        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_migrated"))
        XCTAssertTrue(full.events.contains { $0.kind == .user && $0.text == "continued in 2.0" })
        XCTAssertFalse(full.events.contains { $0.text == "old v1 text" })
    }

    // MARK: - Telemetry

    func testAssistantRowTokensBecomeStepFinishUsage() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))

        let value = await engine.telemetry(for: selected("ses_native"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(Set(telemetry.usageEvents.map(\.usageFamily)), ["opencode.step-finish.tokens"])
        // (100 + 10 cache read + 5 + 2) + (50 + 0 + 3 + 1)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 171)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 7,
                       "OpenCode output excludes reasoning; normalize it into common output")
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 10)
        XCTAssertEqual(telemetry.usageEvents.first?.model, "deepseek-v4.1-flash-free")
        XCTAssertEqual(telemetry.currentConfiguration?.model, "deepseek-v4.1-flash-free")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
    }

    func testRevisionChangesWhenASessionMessageRowChanges() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let session = selected("ses_native")

        let beforeValue = await engine.telemetry(for: session)
        XCTAssertEqual(try XCTUnwrap(beforeValue).usageSummary?.topLineTokens, 171)

        try exec("""
        UPDATE session_message
        SET data = replace(data, '"input":50,', '"input":60,')
        WHERE id = 'msg_native_a2';
        """)

        let afterValue = await engine.telemetry(for: session)
        XCTAssertEqual(try XCTUnwrap(afterValue).usageSummary?.topLineTokens, 181)
        XCTAssertEqual(engine.parseCount, 2, "a changed session_message row must invalidate the cache")
    }

    func testUntouchedMigratedSessionKeepsReadingV1Rows() throws {
        // OpenCode's v1→v2 copy can drop assistant steps. When the copy is not
        // newer than the v1 row, the complete v1 rows stay authoritative.
        try createV1Tables()
        try createV2Tables()
        try exec("""
        INSERT INTO session VALUES ('ses_copy', 'proj', NULL, 'c', '/tmp/repo', 'Original', '1.19.3',
            1000, 3000, NULL, NULL);
        INSERT INTO message VALUES ('msg_u', 'ses_copy', 1000, 1000, '{"role":"user","time":{"created":1000}}');
        INSERT INTO part VALUES ('prt_u', 'msg_u', 'ses_copy', 1000, 1000, '{"type":"text","text":"question"}');
        INSERT INTO message VALUES ('msg_a', 'ses_copy', 2000, 2000, '{"role":"assistant","time":{"created":2000}}');
        INSERT INTO part VALUES ('prt_a', 'msg_a', 'ses_copy', 2000, 2000, '{"type":"text","text":"v1 answer"}');
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated)
        VALUES ('ses_copy', 'proj', 'c', '/tmp/repo', 'Original', '1.19.3', 1000, 3000);
        INSERT INTO session_message VALUES ('msg_u', 'ses_copy', 'user', 0, 1000, 1000,
            '{"time":{"created":1000},"text":"question"}');
        """)

        let listed = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        XCTAssertEqual(listed.eventCount, 2, "the v1 row with both messages is listed")
        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_copy"))
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && $0.text == "v1 answer" })
    }

    // MARK: - Review follow-ups

    func testSessionArchivedOnlyInV2IsHiddenEvenWithoutATimestampChange() throws {
        try createV1Tables()
        try createV2Tables()
        try insertSameAgeCopy(id: "ses_arch_v2", v1Archived: nil, v2Archived: 4000)
        try insertSameAgeCopy(id: "ses_arch_v2_newer", v1Archived: nil, v2Archived: 4000, v2Updated: 3500)

        let ids = try XCTUnwrap(OpenCodeSqliteReader.listSessionsIfReadable(customRoot: dbURL.path)).map(\.id)
        XCTAssertFalse(ids.contains("ses_arch_v2"), "archiving in OpenCode 2.x must hide the stale v1 copy")
        XCTAssertFalse(ids.contains("ses_arch_v2_newer"))
        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_arch_v2"))
        XCTAssertTrue(full.events.contains { $0.text == "v2 copy" }, "list and load pick the same store")
    }

    func testSessionArchivedOnlyInV1StaysHiddenAndLoadsFromV1() throws {
        try createV1Tables()
        try createV2Tables()
        try insertSameAgeCopy(id: "ses_arch_v1", v1Archived: 4000, v2Archived: nil)

        let ids = try XCTUnwrap(OpenCodeSqliteReader.listSessionsIfReadable(customRoot: dbURL.path)).map(\.id)
        XCTAssertFalse(ids.contains("ses_arch_v1"), "the unarchived v2 copy must not resurface it")
        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_arch_v1"))
        XCTAssertTrue(full.events.contains { $0.text == "v1 copy" })
    }

    func testUnreadableV1StoreFailsTheListInsteadOfHidingV1Sessions() throws {
        // A v1 `session` table the list query cannot read (here: no title or
        // directory column) must not look like an empty v1 store.
        try exec("""
        CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER NOT NULL, time_archived INTEGER);
        INSERT INTO session VALUES ('ses_hidden_v1', 1000, NULL);
        """)
        try createV2Tables()
        try insertNativeV2Session()

        XCTAssertNil(OpenCodeSqliteReader.listSessionsIfReadable(customRoot: dbURL.path))
    }

    func testAssistantStepWithoutTokensMakesUsageUnavailable() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        try exec("""
        INSERT INTO session_message VALUES ('msg_no_tokens', 'ses_native', 'assistant', 10, 9070, 9070,
            '{"time":{"created":9070},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"x"}]}');
        """)

        let telemetry = try await telemetry(for: "ses_native")
        XCTAssertNotNil(telemetry.usageSummary?.unavailableReason,
                        "a step without usage evidence must not leave the other steps' sum looking complete")
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 0)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testAssistantStepWithMalformedTokensMakesUsageUnavailable() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        try exec("""
        INSERT INTO session_message VALUES ('msg_bad_tokens', 'ses_native', 'assistant', 10, 9070, 9070,
            '{"time":{"created":9070},"agent":"build","model":{"id":"m","providerID":"p"},"content":[],"tokens":{"input":"12","output":1}}');
        """)

        let telemetry = try await telemetry(for: "ses_native")
        XCTAssertNotNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertTrue(telemetry.usageEvents.isEmpty)
    }

    func testCompactionUsageCountsAndCompactionWithoutUsageDoesNot() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        try exec("""
        INSERT INTO session_message VALUES ('msg_compact_used', 'ses_native', 'compaction', 10, 9070, 9070,
            '{"time":{"created":9070},"status":"completed","reason":"auto","summary":"s","recent":"r","model":{"id":"deepseek-v4.1-flash-free","providerID":"opencode"},"tokens":{"input":20,"output":4,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO session_message VALUES ('msg_compact_free', 'ses_native', 'compaction', 11, 9080, 9080,
            '{"time":{"created":9080},"status":"completed","reason":"manual","summary":"s","recent":"r"}');
        """)

        let telemetry = try await telemetry(for: "ses_native")
        XCTAssertNil(telemetry.usageSummary?.unavailableReason)
        XCTAssertEqual(telemetry.usageEvents.count, 3)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 171 + 24)
    }

    func testFileOnlyAndMixedUserTurnsAreVisible() throws {
        try createV2Tables()
        try insertNativeV2Session()
        try exec("""
        INSERT INTO session_message VALUES ('msg_file_only', 'ses_native', 'user', 10, 9070, 9070,
            '{"time":{"created":9070},"text":"","files":[{"mime":"image/png","name":"/Users/me/Shot 1.png","data":"iVBORw0KGgo="}],"agents":[]}');
        INSERT INTO session_message VALUES ('msg_mixed', 'ses_native', 'user', 11, 9080, 9080,
            '{"time":{"created":9080},"text":"match this layout","files":[{"mime":"application/pdf","name":"spec.pdf","data":"JVBERi0="}],"agents":[]}');
        """)

        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_native"))
        let users = full.events.filter { $0.kind == .user }
        XCTAssertTrue(users.contains { $0.text == "[Attached: Shot 1.png]" })
        XCTAssertTrue(users.contains { $0.text == "match this layout\n\n[Attached: spec.pdf]" })
        XCTAssertFalse(users.contains { ($0.text ?? "").isEmpty }, "no empty user turns")
        XCTAssertTrue(full.events.contains { $0.kind == .meta && $0.text == "[OpenCode part: file]" },
                      "the attachment payload stays available as metadata")
    }

    func testAssistantContentKeepsItsOrderWithinOneStep() throws {
        try createV2Tables()
        try insertNativeV2Session()
        try exec("""
        INSERT INTO session_message VALUES ('msg_ordered', 'ses_native', 'assistant', 10, 9070, 9070,
            '{"time":{"created":9070},"agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"first I look"},{"type":"tool","id":"call_ls","name":"shell","state":{"status":"completed","input":{"command":"ls"},"content":[{"type":"text","text":"a.txt"}]},"time":{"created":9071,"completed":9072}},{"type":"text","text":"then I answer"}],"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """)

        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_native"))
        let step = full.events.filter { $0.messageID == "msg_ordered" || $0.messageID == "call_ls" }
            .filter { $0.kind != .meta }
        XCTAssertEqual(step.map(\.kind), [.assistant, .tool_call, .tool_result, .assistant])
        XCTAssertEqual(step.first?.text, "first I look")
        XCTAssertEqual(step.last?.text, "then I answer")
    }

    func testCancelledV2LoadReturnsNilInsteadOfAPartialTranscript() async throws {
        try createV2Tables()
        try insertNativeV2Session()
        let path = dbURL.path

        let task = Task.detached { () -> Session? in
            // The sleep throws once the task is cancelled; the load then runs
            // with Task.isCancelled already true.
            try? await Task.sleep(nanoseconds: 200_000_000)
            return OpenCodeSqliteReader.loadFullSession(customRoot: path, sessionID: "ses_native")
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNotNil(OpenCodeSqliteReader.loadFullSession(customRoot: path, sessionID: "ses_native"),
                        "the same load succeeds when not cancelled")
    }

    func testCancellationMidScanReturnsNilAndStopsReading() async throws {
        try createV2Tables()
        try insertNativeV2Session() // six session_message rows
        let path = dbURL.path

        let outcome = await Task.detached { () -> (session: Session?, rowsRead: Int) in
            var rowsRead = 0
            let session = OpenCodeSqliteReader.loadFullSession(customRoot: path, sessionID: "ses_native") { count in
                rowsRead = count
                // Cancel the running load after its second row.
                if count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return (session, rowsRead)
        }.value

        XCTAssertNil(outcome.session, "rows already collected must not escape as a full transcript")
        XCTAssertEqual(outcome.rowsRead, 2, "the scan stops at the next row after cancellation")
    }

    func testCancelledLoadOfEmptyV2SessionReturnsNil() async throws {
        try createV2Tables()
        try exec("""
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated)
        VALUES ('ses_empty', 'proj', 'e', '/tmp/repo', 'Empty', '2.1.1', 1000, 1000);
        """)
        let path = dbURL.path

        let task = Task.detached { () -> Session? in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return OpenCodeSqliteReader.loadFullSession(customRoot: path, sessionID: "ses_empty")
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result, "a cancelled load reports cancellation even when there are no rows to read")
        XCTAssertNotNil(OpenCodeSqliteReader.loadFullSession(customRoot: path, sessionID: "ses_empty"))
    }

    func testGeneratedTitleFallsBackToAttachmentNamesForFileOnlyFirstPrompt() throws {
        try createV2Tables()
        try exec("""
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated)
        VALUES ('ses_file_title', 'proj', 'f', '/tmp/repo', 'New session - 2026-10-20T19:14:36.000Z', '2.1.1', 1000, 2000);
        INSERT INTO session_message VALUES ('msg_ft_u', 'ses_file_title', 'user', 0, 1000, 1000,
            '{"time":{"created":1000},"text":"","files":[{"mime":"image/png","name":"/Users/me/Shot 1.png","data":"iVBORw0KGgo="}],"agents":[]}');
        """)

        let listed = try XCTUnwrap(OpenCodeSqliteReader.listSessions(customRoot: dbURL.path).first)
        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_file_title"))
        XCTAssertTrue(listed.title.contains("Shot 1.png"), "got \(listed.title)")
        XCTAssertEqual(listed.title, full.title, "list and transcript agree on the fallback title")
    }

    func testV1UserMessageWithObjectDiffsKeepsItsPrompt() throws {
        // OpenCode stores summary.diffs as {file, patch} objects. Decoding them
        // as strings used to drop the whole user message.
        try createV1Tables()
        try exec("""
        INSERT INTO session VALUES ('ses_diffs', 'proj', NULL, 'd', '/tmp/repo', 'Diffs', '1.19.3', 1000, 2000, NULL, NULL);
        INSERT INTO message VALUES ('msg_d', 'ses_diffs', 1000, 1000,
            '{"role":"user","time":{"created":1000},"summary":{"diffs":[{"file":"a.swift","patch":"@@"}]}}');
        INSERT INTO part VALUES ('prt_d', 'msg_d', 'ses_diffs', 1000, 1000, '{"type":"text","text":"implement the fix"}');
        """)

        let full = try XCTUnwrap(OpenCodeSqliteReader.loadFullSession(customRoot: dbURL.path, sessionID: "ses_diffs"))
        XCTAssertTrue(full.events.contains { $0.kind == .user && $0.text == "implement the fix" })
    }

    func testAdapterTurnsCompactionUsageIntoStepFinish() {
        let adapted = OpenCodeV2MessageAdapter.adapt(
            rowID: "msg_compact",
            type: "compaction",
            timeCreatedMillis: 1_000,
            data: ["status": "completed", "reason": "auto", "summary": "s", "recent": "r",
                   "model": ["id": "m", "providerID": "p"],
                   "tokens": ["input": 1, "output": 2, "reasoning": 0, "cache": ["read": 0, "write": 0]]])
        let stepFinish = adapted.parts.first { ($0.dict["type"] as? String) == "step-finish" }
        XCTAssertEqual(stepFinish?.dict["modelID"] as? String, "m")
        XCTAssertNotNil(stepFinish?.dict["tokens"])
    }

    func testAdapterKeepsUnknownRowTypesAsMeta() {
        let adapted = OpenCodeV2MessageAdapter.adapt(
            rowID: "msg_future",
            type: "future-kind",
            timeCreatedMillis: 1_000,
            data: ["time": ["created": 1_000], "payload": "x"])
        XCTAssertEqual(adapted.message["role"] as? String, "system")
        XCTAssertEqual(adapted.parts.count, 1)
        XCTAssertEqual(adapted.parts.first?.dict["type"] as? String, "future-kind")
    }

    // MARK: - Fixture

    private func telemetry(for id: String) async throws -> SessionTelemetry {
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(for: selected(id))
        return try XCTUnwrap(value)
    }

    /// A migrated session present in both stores with the same time_updated
    /// (3000) unless `v2Updated` says otherwise.
    private func insertSameAgeCopy(id: String, v1Archived: Int?, v2Archived: Int?, v2Updated: Int = 3000) throws {
        let v1Archive = v1Archived.map(String.init) ?? "NULL"
        let v2Archive = v2Archived.map(String.init) ?? "NULL"
        try exec("""
        INSERT INTO session VALUES (\(sql(id)), 'proj', NULL, 's', '/tmp/repo', 'Copy', '1.19.3', 1000, 3000, \(v1Archive), NULL);
        INSERT INTO message VALUES (\(sql(id + "_m")), \(sql(id)), 1000, 1000, '{"role":"user","time":{"created":1000}}');
        INSERT INTO part VALUES (\(sql(id + "_p")), \(sql(id + "_m")), \(sql(id)), 1000, 1000, '{"type":"text","text":"v1 copy"}');
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated, time_archived)
        VALUES (\(sql(id)), 'proj', 's', '/tmp/repo', 'Copy', '1.19.3', 1000, \(v2Updated), \(v2Archive));
        INSERT INTO session_message VALUES (\(sql(id + "_m")), \(sql(id)), 'user', 0, 1000, 1000,
            '{"time":{"created":1000},"text":"v2 copy"}');
        """)
    }

    private func selected(_ id: String) -> Session {
        Session(id: id, source: .opencode, startTime: nil, endTime: nil, model: nil,
                filePath: dbURL.path, eventCount: 0, events: [])
    }

    private func createV1Tables() throws {
        try exec("""
        CREATE TABLE session (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, parent_id TEXT, slug TEXT NOT NULL,
            directory TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER, model TEXT
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        """)
    }

    private func createV2Tables() throws {
        try exec("""
        CREATE TABLE session_v2 (
            id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, parent_id TEXT,
            fork_session_id TEXT, fork_boundary TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL,
            path TEXT, title TEXT, version TEXT NOT NULL, agent TEXT, model TEXT,
            cost REAL DEFAULT 0 NOT NULL, tokens_input INTEGER DEFAULT 0 NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
            time_archived INTEGER, time_suspended INTEGER
        );
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
        """)
    }

    /// A v1 session that OpenCode 2.0 copied into session_v2 and then continued.
    private func insertMigratedSession() throws {
        try exec("""
        INSERT INTO session VALUES ('ses_migrated', 'proj', NULL, 'm', '/tmp/repo', 'Old v1 title', '1.19.3',
            1000, 2000, NULL, '{"id":"v1-model","providerID":"opencode"}');
        INSERT INTO message VALUES ('msg_old', 'ses_migrated', 1000, 1000, '{"role":"user","time":{"created":1000}}');
        INSERT INTO part VALUES ('prt_old', 'msg_old', 'ses_migrated', 1000, 1000, '{"type":"text","text":"old v1 text"}');
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, model, time_created, time_updated)
        VALUES ('ses_migrated', 'proj', 'm', '/tmp/repo', 'Migrated title', '1.19.3',
            '{"id":"v2-model","providerID":"opencode"}', 1000, 5000);
        INSERT INTO session_message VALUES ('msg_mig_u', 'ses_migrated', 'user', 0, 4000, 4000,
            '{"time":{"created":4000},"text":"continued in 2.0","files":[],"agents":[]}');
        """)
    }

    /// A v1 session the background copy has not reached yet.
    private func insertV1OnlySession() throws {
        try exec("""
        INSERT INTO session VALUES ('ses_v1_only', 'proj', NULL, 'o', '/tmp/repo', 'Not yet copied', '1.19.3',
            500, 1500, NULL, NULL);
        INSERT INTO message VALUES ('msg_v1_only', 'ses_v1_only', 500, 500, '{"role":"user","time":{"created":500}}');
        INSERT INTO part VALUES ('prt_v1_only', 'msg_v1_only', 'ses_v1_only', 500, 500, '{"type":"text","text":"v1 only"}');
        """)
    }

    private func insertNativeV2Session(title: String = "Native v2 session") throws {
        let model = #"{"id":"deepseek-v4.1-flash-free","providerID":"opencode","variant":"default"}"#
        try exec("""
        INSERT INTO session_v2 (id, project_id, slug, directory, title, version, model, time_created, time_updated)
        VALUES ('ses_native', 'proj', 'n', '/tmp/v2repo', \(sql(title)), '2.1.1', \(sql(model)), 9000, 9900);
        """)
        let rows: [(String, String, Int, Int, String)] = [
            ("msg_native_sys", "system", 0, 9000,
             #"{"time":{"created":9000},"text":"The available tools have changed.","description":"tools changed"}"#),
            ("msg_native_u", "user", 1, 9001,
             #"{"time":{"created":9001},"text":"so no more Big Pickle in opencode?","files":[],"agents":[]}"#),
            ("msg_native_a1", "assistant", 2, 9002,
             #"{"time":{"created":9002,"streamed":9010,"completed":9020},"agent":"build","model":\#(model),"content":[{"type":"reasoning","text":"Check the catalog."},{"type":"tool","id":"call_exec","name":"execute","executed":false,"state":{"status":"completed","input":{"code":"return await tools.opencode.models({ query: \"pickle\" })"},"content":[{"type":"text","text":"{\"providers\":[]}"}]},"time":{"created":9003,"completed":9004}},{"type":"tool","id":"call_read","name":"read","state":{"status":"error","input":{"path":"/tmp/missing.swift"},"error":{"type":"tool.execution","message":"File not found: /tmp/missing.swift"}},"time":{"created":9005,"completed":9006}}],"finish":"tool-calls","cost":0,"tokens":{"input":100,"output":5,"reasoning":2,"cache":{"read":10,"write":0}}}"#),
            ("msg_native_a2", "assistant", 3, 9030,
             #"{"time":{"created":9030,"completed":9040},"agent":"build","model":\#(model),"content":[{"type":"text","text":"Big Pickle is still listed."}],"finish":"stop","cost":0,"tokens":{"input":50,"output":3,"reasoning":1,"cache":{"read":0,"write":0}}}"#),
            ("msg_native_sh", "shell", 4, 9050,
             #"{"time":{"created":9050,"completed":9051},"shellID":"sh_1","command":"git status","status":"exited","exit":0,"output":{"output":"nothing to commit, working tree clean","cursor":37,"size":37,"truncated":false}}"#),
            ("msg_native_idle", "idle", 5, 9060,
             #"{"time":{"created":9060},"outcome":"succeeded"}"#),
        ]
        for (id, type, seq, created, data) in rows {
            try exec("""
            INSERT INTO session_message VALUES (\(sql(id)), 'ses_native', \(sql(type)), \(seq), \(created), \(created), \(sql(data)));
            """)
        }
    }

    private func sql(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func exec(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "OpenCodeV2Fixture", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, statement, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenCodeV2Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
