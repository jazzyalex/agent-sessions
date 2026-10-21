import XCTest
import SQLite3
@testable import AgentSessions

/// OpenClaw 2026.10.5 moved transcripts from `agents/<id>/sessions/*.jsonl` into
/// `agents/<id>/agent/openclaw-agent.sqlite`. These tests run against the redacted
/// store in `Resources/Fixtures/stage0/agents/openclaw/sqlite/openclaw-agent.sql`,
/// whose schema is copied from a real 2026.10.5 database and whose tool-result row
/// is zstd-compressed the way OpenClaw writes it.
final class OpenClawSqliteStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-OpenClaw-Store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixtureDatabase() throws -> URL {
        let database = root.appendingPathComponent("agents/main/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let script = try String(
            contentsOf: FixturePaths.stage0FixtureURL("agents/openclaw/sqlite/openclaw-agent.sql"),
            encoding: .utf8)
        try execute(script, at: database)
        return database
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "OpenClawSqliteStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenClawSqliteStoreTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func session(_ rawID: String, in database: URL) throws -> Session {
        let sessions = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        return try XCTUnwrap(sessions.first { $0.id == "openclaw:main:\(rawID)" })
    }

    private func transcriptText(_ session: Session) -> String {
        session.events
            .flatMap { [$0.text, $0.toolOutput].compactMap { $0 } }
            .joined(separator: "\n")
    }

    // MARK: - Listing

    func testFixtureListsBothSessionsWithStoreMetadata() throws {
        let database = try makeFixtureDatabase()
        let sessions = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        XCTAssertEqual(Set(sessions.map(\.id)),
                       ["openclaw:main:openclaw-fixture-migrated", "openclaw:main:openclaw-fixture-native"])
        let native = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(native.model, "fixture-model")
        XCTAssertEqual(native.eventCount, 5)
        XCTAssertEqual(native.filePath, database.path)
    }

    /// Sessions imported from JSONL have no `display_name` or `model` column value,
    /// so the list must take the title, cwd and model from the transcript itself the
    /// way the JSONL preview did. Before this, they listed untitled with no project.
    func testMigratedSessionListsTranscriptTitleCwdAndModel() throws {
        let database = try makeFixtureDatabase()
        let migrated = try session("openclaw-fixture-migrated", in: database)
        XCTAssertEqual(migrated.lightweightTitle, "List the files in the fixture repo")
        XCTAssertEqual(migrated.lightweightCwd, "/tmp/repo")
        XCTAssertEqual(migrated.model, "fixture-model")
        XCTAssertEqual(migrated.eventCount, 5)
    }

    func testNativeSessionListsCwdFromTranscriptHeader() throws {
        let database = try makeFixtureDatabase()
        let native = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(native.lightweightCwd, "/tmp/repo")
        XCTAssertNotNil(native.lightweightTitle)
    }

    // MARK: - Compressed rows

    func testFullLoadDecodesCompressedToolResult() throws {
        let database = try makeFixtureDatabase()
        let listed = try session("openclaw-fixture-migrated", in: database)
        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database, sessionID: listed.id),
                                 "a zstd row must not make the whole transcript unreadable")
        let text = transcriptText(full)
        XCTAssertTrue(text.contains("fixture-file-07.txt"), "tool output from the compressed row is missing")
        XCTAssertTrue(text.contains("The fixture repo has 40 files."))
        XCTAssertEqual(full.lightweightCwd, "/tmp/repo")
        XCTAssertNotNil(full.sourceStorageRevision)
    }

    func testTelemetryReadsSessionWithCompressedRow() throws {
        let database = try makeFixtureDatabase()
        let listed = try session("openclaw-fixture-migrated", in: database)
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: listed))
        XCTAssertNil(scan.result.telemetry.usageSummary?.unavailableReason)
        XCTAssertFalse(scan.result.telemetry.usageEvents.isEmpty)
        XCTAssertNotNil(OpenClawSqliteReader.telemetryRevision(for: listed))
    }

    /// One bad compressed row: the session still opens, with a notice in place of
    /// that row and never its content; telemetry stays unavailable.
    func testCorruptCompressedRowOpensWithPlaceholderAndTelemetryFailsClosed() throws {
        let database = try makeFixtureDatabase()
        try execute("""
            UPDATE transcript_events SET event_zstd = X'28B52FFD0000DEADBEEF'
            WHERE session_id = 'openclaw-fixture-migrated' AND seq = 4;
            """, at: database)
        let listed = try session("openclaw-fixture-migrated", in: database)
        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database, sessionID: listed.id))
        let text = transcriptText(full)
        XCTAssertTrue(text.contains(OpenClawSqliteReader.undecodablePlaceholderText))
        XCTAssertFalse(text.contains("fixture-file-07.txt"))
        XCTAssertTrue(text.contains("The fixture repo has 40 files."), "rows after the bad one must still load")
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: listed))
        XCTAssertTrue(scan.result.telemetry.usageSummary?.unavailableReason?.contains("compressed") == true)
    }

    /// OpenClaw records the decoded size and rejects a frame that decodes to any
    /// other length; the app must not show such a row either.
    func testCompressedRowWithWrongRecordedSizeIsReplacedByPlaceholder() throws {
        let database = try makeFixtureDatabase()
        try execute("""
            UPDATE transcript_events SET event_utf8_bytes = event_utf8_bytes - 1
            WHERE session_id = 'openclaw-fixture-migrated' AND seq = 4;
            """, at: database)
        let listed = try session("openclaw-fixture-migrated", in: database)
        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database, sessionID: listed.id))
        XCTAssertTrue(transcriptText(full).contains(OpenClawSqliteReader.undecodablePlaceholderText))
        XCTAssertFalse(transcriptText(full).contains("fixture-file-07.txt"))
    }

    /// A text row that is not JSON, inside the 200-event preview window: the list
    /// keeps the session and its title, the full load shows a notice, telemetry
    /// fails closed.
    func testMalformedTextRowInsidePreviewWindow() throws {
        let database = try makeFixtureDatabase()
        try execute("""
            UPDATE transcript_events SET event_json = 'not json', event_utf8_bytes = 8
            WHERE session_id = 'openclaw-fixture-native' AND seq = 3;
            """, at: database)
        let listed = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(listed.lightweightTitle, "Run pwd, then say hello")
        XCTAssertEqual(listed.eventCount, 5)
        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database, sessionID: listed.id))
        XCTAssertTrue(transcriptText(full).contains(OpenClawSqliteReader.undecodablePlaceholderText))
        XCTAssertTrue(transcriptText(full).contains("Hello from /tmp/repo."))
        let scan = try XCTUnwrap(OpenClawSqliteReader.loadTelemetry(for: listed))
        XCTAssertNotNil(scan.result.telemetry.usageSummary?.unavailableReason)
    }

    // MARK: - Titles and preview cache

    /// The list and an opened session must agree, or the title flips on open.
    func testListTitleMatchesFullLoadTitle() throws {
        let database = try makeFixtureDatabase()
        for rawID in ["openclaw-fixture-migrated", "openclaw-fixture-native"] {
            let listed = try session(rawID, in: database)
            let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database, sessionID: listed.id))
            XCTAssertNotNil(listed.lightweightTitle)
            XCTAssertEqual(listed.lightweightTitle, full.lightweightTitle, rawID)
        }
    }

    /// An append changes the count and last sequence, so the cached preview is
    /// recomputed (here the first prompt was also rewritten, as a rewind would).
    func testPreviewCacheRecomputesAfterAppend() throws {
        let database = try makeFixtureDatabase()
        XCTAssertEqual(try session("openclaw-fixture-native", in: database).lightweightTitle,
                       "Run pwd, then say hello")
        try execute("""
            UPDATE transcript_events
            SET event_json = replace(event_json, 'Run pwd, then say hello', 'Rewritten first prompt'),
                event_utf8_bytes = NULL
            WHERE session_id = 'openclaw-fixture-native' AND seq = 2;
            INSERT INTO transcript_events (session_id, seq, event_json, created_at)
            VALUES ('openclaw-fixture-native', 6,
                    '{"type":"message","id":"native-user-2","message":{"role":"user","content":"Again"}}',
                    1792494406000);
            """, at: database)
        let relisted = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(relisted.lightweightTitle, "Rewritten first prompt")
        XCTAssertEqual(relisted.eventCount, 6)
    }

    /// A rewrite that keeps the event count, last sequence, byte size and
    /// transcript time (an in-place edit of the first prompt) must still
    /// invalidate the cached preview.
    func testPreviewCacheRecomputesAfterSameCountRewrite() throws {
        let database = try makeFixtureDatabase()
        let before = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(before.lightweightTitle, "Run pwd, then say hello")
        // Same length, so event_utf8_bytes and the store size stay valid.
        try execute("""
            UPDATE transcript_events
            SET event_json = replace(event_json, 'Run pwd, then say hello', 'Say pwd, then run hello')
            WHERE session_id = 'openclaw-fixture-native' AND seq = 2;
            """, at: database)
        let after = try session("openclaw-fixture-native", in: database)
        XCTAssertEqual(after.eventCount, before.eventCount)
        XCTAssertEqual(after.endTime, before.endTime)
        XCTAssertEqual(after.lightweightTitle, "Say pwd, then run hello")
    }

    private func indexedRow(like fresh: Session, path: URL, eventCount: Int? = nil) -> Session {
        var indexed = Session(id: fresh.id,
                source: .openclaw,
                startTime: fresh.startTime,
                endTime: fresh.endTime,
                model: fresh.model,
                filePath: path.path,
                fileSizeBytes: nil,
                eventCount: eventCount ?? fresh.eventCount,
                events: [],
                cwd: "/indexed",
                repoName: nil,
                lightweightTitle: "Indexed title",
                lightweightCommands: 1)
        indexed.sourcePreviewDigest = fresh.sourcePreviewDigest
        return indexed
    }

    private func copyDatabase(_ database: URL, to relativePath: String) throws -> URL {
        let copy = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: database, to: copy)
        return copy
    }

    /// After a relaunch, an indexed row from the same store whose count and end
    /// time still match supplies the preview, so the list does not reread its
    /// transcript. A row indexed from another database never does, even with
    /// the same session id, count and end time.
    func testUnchangedIndexedRowSuppliesPreview() throws {
        let database = try makeFixtureDatabase()
        let fresh = try session("openclaw-fixture-migrated", in: database)
        // New store paths, so the in-memory cache from `fresh` cannot answer.
        let copy = try copyDatabase(database, to: "agents/main/copy/openclaw-agent.sqlite")
        let reused = try XCTUnwrap(OpenClawSqliteReader.listSessions(
            databaseURL: copy, agentID: "main",
            priorSessions: [indexedRow(like: fresh, path: copy)])?.first { $0.id == fresh.id })
        XCTAssertEqual(reused.lightweightTitle, "Indexed title")
        XCTAssertEqual(reused.lightweightCwd, "/indexed")

        let foreign = try copyDatabase(database, to: "agents/main/foreign/openclaw-agent.sqlite")
        let notReused = try XCTUnwrap(OpenClawSqliteReader.listSessions(
            databaseURL: foreign, agentID: "main",
            priorSessions: [indexedRow(like: fresh, path: database)])?.first { $0.id == fresh.id })
        XCTAssertEqual(notReused.lightweightTitle, "List the files in the fixture repo",
                       "a row indexed from another database must not supply this store's preview")
        XCTAssertEqual(notReused.lightweightCwd, "/tmp/repo")

        let other = try copyDatabase(database, to: "agents/main/other/openclaw-agent.sqlite")
        let reread = try XCTUnwrap(OpenClawSqliteReader.listSessions(
            databaseURL: other, agentID: "main",
            priorSessions: [indexedRow(like: fresh, path: other, eventCount: fresh.eventCount - 1)])?
            .first { $0.id == fresh.id })
        XCTAssertEqual(reread.lightweightTitle, "List the files in the fixture repo")
    }

    /// The on-disk digest must round-trip through session_meta and hydration.
    /// Otherwise a relaunch cannot distinguish a rewritten prompt from stale
    /// indexed title/cwd when the count and timestamps remain unchanged.
    func testPreviewDigestRoundTripsCoreIndexAndHydration() async throws {
        let database = try makeFixtureDatabase()
        let original = try session("openclaw-fixture-native", in: database)
        let proof = try XCTUnwrap(original.sourcePreviewDigest)
        XCTAssertEqual(proof.count, 64)

        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        try await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: original))
        let indexedRows = try await db.fetchSessionMeta(for: "openclaw")
        XCTAssertEqual(indexedRows.first?.openClawPreviewDigest, proof)
        let hydrated = try await SessionMetaRepository(db: db).fetchSessions(for: .openclaw)
        XCTAssertEqual(hydrated.first?.sourcePreviewDigest, proof)
    }

    /// A previously indexed row is not proof after a relaunch. Same-byte-count
    /// edits must be detected even when no in-process digest cache exists for
    /// the newly copied database path.
    func testColdCacheRejectsSameLengthFirstPromptRewrite() throws {
        let original = try makeFixtureDatabase()
        let before = try session("openclaw-fixture-native", in: original)
        let copy = try copyDatabase(original, to: "agents/main/cold/openclaw-agent.sqlite")
        try execute("""
            UPDATE transcript_events
            SET event_json = replace(event_json, 'Run pwd, then say hello', 'Say pwd, then run hello')
            WHERE session_id = 'openclaw-fixture-native' AND seq = 2;
            """, at: copy)
        let actual = try XCTUnwrap(OpenClawSqliteReader.listSessions(
            databaseURL: copy, agentID: "main",
            priorSessions: [indexedRow(like: before, path: copy)])?
            .first(where: { $0.id == before.id }))
        XCTAssertEqual(actual.eventCount, before.eventCount)
        XCTAssertEqual(actual.endTime, before.endTime)
        XCTAssertEqual(actual.lightweightTitle, "Say pwd, then run hello")
        XCTAssertEqual(actual.lightweightCwd, "/tmp/repo")
        XCTAssertNotEqual(actual.sourcePreviewDigest, before.sourcePreviewDigest)
    }

    /// An atomic store replacement at the *same pathname* is not the same
    /// database, even if its session ID/count/activity time happen to match.
    func testColdCacheRejectsReplacedDatabaseAtSamePath() throws {
        let original = try makeFixtureDatabase()
        let before = try session("openclaw-fixture-native", in: original)
        let prior = indexedRow(like: before, path: original)
        let replacement = try copyDatabase(original, to: "agents/main/replacement/openclaw-agent.sqlite")
        try execute("""
            UPDATE transcript_events
            SET event_json = replace(event_json, 'Run pwd, then say hello', 'Say pwd, then run hello')
            WHERE session_id = 'openclaw-fixture-native' AND seq = 2;
            """, at: replacement)
        try FileManager.default.removeItem(at: original)
        // Do not attach an old store's WAL or shared-memory sidecar to the
        // replacement main file; either would invalidate the test's setup.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: original.path + suffix))
        }
        try FileManager.default.moveItem(at: replacement, to: original)
        // Cold cache: only the persisted digest on `prior` can authorize reuse.
        OpenClawSqliteReader.resetPreviewCachesForTesting()
        let actual = try XCTUnwrap(OpenClawSqliteReader.listSessions(
            databaseURL: original, agentID: "main", priorSessions: [prior])?
            .first(where: { $0.id == before.id }))
        XCTAssertEqual(actual.lightweightTitle, "Say pwd, then run hello")
        XCTAssertEqual(actual.eventCount, before.eventCount)
        XCTAssertNotEqual(actual.sourcePreviewDigest, before.sourcePreviewDigest)
    }

    /// Search ingest writes session_meta from the full load. That load must
    /// carry the same preview proof as the listing, or each ingest clears it.
    func testFullLoadCarriesListingPreviewProof() throws {
        let database = try makeFixtureDatabase()
        let listed = try session("openclaw-fixture-native", in: database)
        let full = try XCTUnwrap(OpenClawSqliteReader.loadFullSession(databaseURL: database,
                                                                      sessionID: listed.id))
        XCTAssertNotNil(listed.sourcePreviewDigest)
        XCTAssertEqual(full.sourcePreviewDigest, listed.sourcePreviewDigest)
    }

    /// The completed store-level fingerprint and per-session cheap signature
    /// prove an unchanged listing; no second SHA-256 window scan is needed.
    func testUnchangedStoreSkipsPreviewDigestHashing() throws {
        let database = try makeFixtureDatabase()
        let before = OpenClawSqliteReader.previewDigestReadCountForTesting(databaseURL: database)
        let first = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        let afterFirst = OpenClawSqliteReader.previewDigestReadCountForTesting(databaseURL: database)
        XCTAssertGreaterThan(afterFirst, before, "the initial pass must hash a preview window")
        let again = try XCTUnwrap(OpenClawSqliteReader.listSessions(databaseURL: database))
        XCTAssertEqual(again.count, first.count)
        XCTAssertEqual(OpenClawSqliteReader.previewDigestReadCountForTesting(databaseURL: database),
                       afterFirst, "the same unchanged store must not hash the preview rows twice")
    }

    // MARK: - JSONL and SQLite copies of one session

    private func makeSession(id: String, path: String, end: TimeInterval, deleted: Bool = false) -> Session {
        Session(id: id,
                source: .openclaw,
                startTime: Date(timeIntervalSince1970: 1_000),
                endTime: Date(timeIntervalSince1970: end),
                model: nil,
                filePath: path,
                fileSizeBytes: nil,
                eventCount: 1,
                events: [],
                cwd: nil,
                repoName: nil,
                lightweightTitle: nil,
                lightweightCommands: nil,
                deletedAt: deleted ? Date(timeIntervalSince1970: end) : nil)
    }

    func testDeletedJSONLCopyNeverBeatsTheLiveSQLiteCopy() {
        let deleted = makeSession(id: "openclaw:main:same",
                                  path: "/x/agents/main/sessions/same.jsonl.deleted.2026-10-21T00-00-00.000Z",
                                  end: 9_000, deleted: true)
        let sqlite = makeSession(id: "openclaw:main:same",
                                 path: "/x/agents/main/agent/openclaw-agent.sqlite", end: 2_000)
        XCTAssertEqual(OpenClawSessionIndexer.preferringCurrentStore([deleted, sqlite]).map(\.filePath),
                       [sqlite.filePath])
    }

    /// Only JSONL-SQLite pairs collapse; two JSONL rows are left as they were.
    func testTwoJSONLRowsWithOneIDAreNotCollapsed() {
        let first = makeSession(id: "openclaw:main:same", path: "/x/agents/main/sessions/b.jsonl", end: 2_000)
        let second = makeSession(id: "openclaw:main:same", path: "/x/agents/main/sessions/a.jsonl", end: 3_000)
        XCTAssertEqual(OpenClawSessionIndexer.preferringCurrentStore([first, second]).map(\.filePath),
                       [second.filePath, first.filePath], "both kept, in path order")
    }

    /// A configured `agentDir` can live outside `agents/<id>/` under a directory
    /// name unrelated to the agent id. OpenClaw still writes that agent's JSONL
    /// to `agents/<normalized id>/sessions/`, so the pair matches on the agent id
    /// the store was listed under, not on the database directory name.
    func testPairsWhenConfiguredAgentIDDiffersFromDirectoryName() {
        let jsonl = makeSession(id: "openclaw:configured:same",
                                path: "/x/agents/configured/sessions/same.jsonl", end: 2_000)
        let sqlite = makeSession(id: "openclaw:configured:same",
                                 path: "/elsewhere/agent/openclaw-agent.sqlite", end: 2_000)
        XCTAssertEqual(OpenClawSessionIndexer.preferringCurrentStore([jsonl, sqlite]).map(\.filePath),
                       [sqlite.filePath])
        // A JSONL directory OpenClaw would normalize to the same id still pairs.
        let upper = makeSession(id: "openclaw:Configured:same",
                                path: "/x/agents/Configured/sessions/same.jsonl", end: 2_000)
        XCTAssertEqual(OpenClawSessionIndexer.preferringCurrentStore([upper, sqlite]).map(\.filePath),
                       [sqlite.filePath])
    }

    /// Two agents can hold independent sessions with one raw id. Agent A's
    /// SQLite row and agent B's JSONL row are different sessions: keep both.
    func testCrossAgentRawIDCollisionKeepsBothRows() {
        let sqliteA = makeSession(id: "openclaw:agenta:shared-id",
                                  path: "/x/agents/agenta/agent/openclaw-agent.sqlite", end: 2_000)
        let jsonlB = makeSession(id: "openclaw:agentb:shared-id",
                                 path: "/x/agents/agentb/sessions/shared-id.jsonl", end: 3_000)
        let result = OpenClawSessionIndexer.preferringCurrentStore([sqliteA, jsonlB])
        XCTAssertEqual(Set(result.map(\.id)), ["openclaw:agenta:shared-id", "openclaw:agentb:shared-id"])
        XCTAssertEqual(result.count, 2)

        // Same agent, same raw id: the JSONL copy still collapses into SQLite.
        let jsonlA = makeSession(id: "openclaw:agenta:shared-id",
                                 path: "/x/agents/agenta/sessions/shared-id.jsonl", end: 2_000)
        let collapsed = OpenClawSessionIndexer.preferringCurrentStore([sqliteA, jsonlA, jsonlB])
        XCTAssertEqual(collapsed.map(\.filePath), [sqliteA.filePath, jsonlB.filePath])
    }

    /// End to end through the indexer: an imported session whose JSONL original is
    /// still in `sessions/` publishes one row and stores one path.
    @MainActor
    func testIndexerPublishesAndStoresOneRowForImportedSession() async throws {
        let database = try makeFixtureDatabase()
        let jsonl = root.appendingPathComponent("agents/main/sessions/openclaw-fixture-migrated.jsonl")
        try FileManager.default.createDirectory(at: jsonl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"type":"session","version":3,"id":"openclaw-fixture-migrated","timestamp":"2026-10-20T09:00:00.000Z","cwd":"/tmp/repo"}
            {"type":"message","id":"migrated-user-1","timestamp":"2026-10-20T09:00:01.000Z","message":{"role":"user","content":"List the files in the fixture repo"}}
            """.utf8).write(to: jsonl)

        let indexRoot = root.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        IndexDBTestHooks.applicationSupportDirectoryProvider = { indexRoot }
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
        }

        let indexer = OpenClawSessionIndexer(discovery: OpenClawSessionDiscovery(customRoot: root.path))
        indexer.refresh(mode: .fullReconcile)
        try await waitUntilQuiet(indexer)

        let published = indexer.allSessions.filter { $0.id == "openclaw:main:openclaw-fixture-migrated" }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first.map { URL(fileURLWithPath: $0.filePath).resolvingSymlinksInPath().path },
                       database.resolvingSymlinksInPath().path)

        let indexDB = try IndexDB()
        let storedPaths = try await indexDB.fetchSessionMetaPaths(for: SessionSource.openclaw.rawValue)
        XCTAssertFalse(storedPaths.contains { $0.hasSuffix("openclaw-fixture-migrated.jsonl") },
                       "the JSONL copy must not be stored beside the SQLite row")
        XCTAssertEqual(Set(storedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }),
                       [database.resolvingSymlinksInPath().path])
    }

    @MainActor
    private func waitUntilQuiet(_ indexer: OpenClawSessionIndexer, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var idleTicks = 0
        while idleTicks < 10 {
            guard Date() < deadline else { return XCTFail("OpenClaw indexer did not settle") }
            idleTicks = indexer.isIndexing ? 0 : idleTicks + 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testIndexerKeepsSQLiteCopyOfImportedJSONLSession() {
        let jsonl = makeSession(id: "openclaw:main:same", path: "/x/agents/main/sessions/same.jsonl", end: 2_000)
        let sqlite = makeSession(id: "openclaw:main:same",
                                 path: "/x/agents/main/agent/openclaw-agent.sqlite", end: 2_000)
        let other = makeSession(id: "openclaw:main:other", path: "/x/agents/main/sessions/other.jsonl", end: 1_500)
        let result = OpenClawSessionIndexer.preferringCurrentStore([jsonl, sqlite, other])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.id == "openclaw:main:same" }?.filePath, sqlite.filePath)
        XCTAssertNotNil(result.first { $0.id == "openclaw:main:other" })
    }

    func testIndexerKeepsJSONLCopyOnlyWhenItIsNewer() {
        let jsonl = makeSession(id: "openclaw:main:same", path: "/x/agents/main/sessions/same.jsonl", end: 3_000)
        let sqlite = makeSession(id: "openclaw:main:same",
                                 path: "/x/agents/main/agent/openclaw-agent.sqlite", end: 2_000)
        let result = OpenClawSessionIndexer.preferringCurrentStore([sqlite, jsonl])
        XCTAssertEqual(result.map(\.filePath), [jsonl.filePath])
    }

    // MARK: - Discovery

    /// OpenClaw runs an embedded Codex harness whose rollouts live under
    /// `agents/<id>/agent/codex-home/sessions/`. They are not OpenClaw transcripts.
    /// Discovery used to take `*.jsonl` from any directory named `sessions`, so a
    /// rollout directly in that directory was listed as OpenClaw.
    func testDiscoveryIgnoresEmbeddedCodexHome() throws {
        let fm = FileManager.default
        let agent = root.appendingPathComponent("agents/main", isDirectory: true)
        let live = agent.appendingPathComponent("sessions/live.jsonl")
        let rollout = agent.appendingPathComponent(
            "agent/codex-home/sessions/2026/10/20/rollout-2026-10-20T21-54-15-fixture.jsonl")
        let flatRollout = agent.appendingPathComponent("agent/codex-home/sessions/rollout-flat.jsonl")
        for url in [live, rollout, flatRollout] {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"type":"session"}"#.utf8).write(to: url)
        }

        let found = OpenClawSessionDiscovery(customRoot: root.path, includeDeleted: false).discoverSessionFiles()
        XCTAssertEqual(found.map { $0.resolvingSymlinksInPath().path },
                       [live.resolvingSymlinksInPath().path])
    }
}
