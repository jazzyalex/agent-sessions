import XCTest
@testable import AgentSessions

#if DEBUG
/// Locks the contract of the corpus-preserving reindex primitive that schema
/// migrations must use instead of wiping the world.
///
/// The failure this guards against: a reindex marker that adds `DELETE FROM
/// session_search` / `session_tool_io` to force a `session_meta` re-derive. That
/// empties the FTS corpus on the first launch after an upgrade, so search returns
/// nothing for the full (minutes-long) reparse. `IndexDB.reindexSessionMeta` is the
/// sanctioned alternative: it re-derives `session_meta` only and leaves the corpus
/// intact. If a future change makes it (or a migration built on it) touch the corpus,
/// these tests fail.
final class MigrationCorpusPreservationTests: XCTestCase {

    private func seedSession(_ db: IndexDB,
                             source: String,
                             id: String,
                             metaMtime: Int64 = 100,
                             searchMtime: Int64 = 100) async throws {
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: id, source: source, path: "/tmp/\(id).jsonl",
            mtime: metaMtime, size: 200, startTS: 100, endTS: 200,
            model: nil, cwd: nil, repo: nil, title: "t",
            codexInternalSessionID: nil, isHousekeeping: false,
            messages: 3, commands: 1,
            parentSessionID: nil, subagentType: nil, customTitle: nil))
        try await db.upsertSessionSearch(sessionID: id, source: source,
            mtime: searchMtime, size: 200, text: "hello \(source) searchable")
        try await db.upsertSessionToolIO(sessionID: id, source: source,
            mtime: 100, size: 200, refTS: 200, text: "tool io \(source)")
    }

    func testReindexSessionMetaPreservesSearchCorpusAndScopesBySource() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        try await seedSession(db, source: "codex", id: "codex-1")
        try await seedSession(db, source: "claude", id: "claude-1")

        // Re-derive only codex meta (the pattern a source-scoped migration would use).
        try await db.reindexSessionMeta(sources: ["codex"])

        // codex meta cleared (forces the core indexer to re-parse + repopulate);
        // claude meta untouched.
        let codexMeta = try await db.rowCountForTesting(table: "session_meta", source: "codex")
        let claudeMeta = try await db.rowCountForTesting(table: "session_meta", source: "claude")
        XCTAssertEqual(codexMeta, 0, "reindexSessionMeta should clear scoped session_meta")
        XCTAssertEqual(claudeMeta, 1, "reindexSessionMeta must not touch other sources' meta")

        // FTS corpus fully preserved for BOTH sources — search never goes empty.
        for source in ["codex", "claude"] {
            let search = try await db.rowCountForTesting(table: "session_search", source: source)
            let toolIO = try await db.rowCountForTesting(table: "session_tool_io", source: source)
            XCTAssertEqual(search, 1, "session_search[\(source)] must survive a meta re-derive")
            XCTAssertEqual(toolIO, 1, "session_tool_io[\(source)] must survive a meta re-derive")
        }
    }

    func testReindexSessionMetaAllSourcesStillPreservesCorpus() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        try await seedSession(db, source: "codex", id: "codex-1")
        try await seedSession(db, source: "claude", id: "claude-1")

        // nil == every source.
        try await db.reindexSessionMeta()

        let metaCount = try await db.rowCountForTesting(table: "session_meta")
        let searchCount = try await db.rowCountForTesting(table: "session_search")
        let toolIOCount = try await db.rowCountForTesting(table: "session_tool_io")
        XCTAssertEqual(metaCount, 0, "reindexSessionMeta() should clear all session_meta")
        // The corpus is what's expensive to rebuild and must be preserved wholesale.
        XCTAssertEqual(searchCount, 2, "session_search must survive a full meta re-derive")
        XCTAssertEqual(toolIOCount, 2, "session_tool_io must survive a full meta re-derive")
    }

    /// The tests above lock the `reindexSessionMeta` primitive itself, but not any
    /// particular marker's use of it — `makeTestIndexDB()` always bootstraps a fresh,
    /// empty database, so every `bootstrap` marker (including
    /// `codex_guardian_subagent_reindex_v1`) runs as a no-op there and the effect of
    /// re-running `bootstrap` against a POPULATED corpus is never exercised. That gap
    /// would let someone "fix" the marker by copy-pasting the neighboring
    /// `DELETE FROM session_search WHERE source='codex'` shape — the exact mistake the
    /// guardrail comment above the markers in `DB.swift` warns against, and which 4 of
    /// the 5 existing markers already exhibit — without any test noticing.
    ///
    /// This test drives `bootstrap` itself (via two real `IndexDB()` opens against the
    /// same on-disk file) against a populated corpus, simulating an app relaunch after
    /// an upgrade where this marker has not yet run.
    func testBootstrapCodexGuardianReindexMarkerPreservesCorpusOnPopulatedDatabase() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        defer { IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider }

        // First open: a fresh database. `bootstrap` runs every marker — including
        // codex_guardian_subagent_reindex_v1 — as a no-op against empty tables and
        // records them all as applied in schema_migrations.
        IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
        var db: IndexDB? = try IndexDB()
        IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

        // Seed a populated corpus for BOTH sources, simulating an already-indexed
        // install — the marker must only ever touch codex.
        try await seedSession(db!, source: "codex", id: "codex-1")
        try await seedSession(db!, source: "claude", id: "claude-1")

        // Simulate an upgrade where this marker has never run on this install: clear
        // only its own schema_migrations row. The four legacy (grandfathered,
        // destructive) markers stay recorded as applied from the fresh-db bootstrap
        // above, so their "wipe everything" bodies stay skipped and can't clobber the
        // seed data — isolating the assertion to the marker under test.
        try await db!.exec("DELETE FROM schema_migrations WHERE key = 'codex_guardian_subagent_reindex_v1';")
        db = nil // close this connection before reopening the same on-disk file

        // Re-open the SAME on-disk database — this re-runs `bootstrap` against
        // populated tables, exactly like an app relaunch after upgrade.
        IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
        let reopened = try IndexDB()
        IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

        let codexMeta = try await reopened.rowCountForTesting(table: "session_meta", source: "codex")
        let claudeMeta = try await reopened.rowCountForTesting(table: "session_meta", source: "claude")
        XCTAssertEqual(codexMeta, 0, "bootstrap's codex_guardian_subagent_reindex_v1 marker should clear codex session_meta")
        XCTAssertEqual(claudeMeta, 1, "the marker must not touch claude session_meta")

        // Load-bearing: the FTS corpus must be preserved across the bootstrap run for
        // BOTH sources. This is the assertion that fails if the marker is ever "fixed"
        // into the destructive `DELETE FROM session_search WHERE source='codex'` shape.
        for source in ["codex", "claude"] {
            let search = try await reopened.rowCountForTesting(table: "session_search", source: source)
            let toolIO = try await reopened.rowCountForTesting(table: "session_tool_io", source: source)
            XCTAssertEqual(search, 1, "session_search[\(source)] must survive bootstrap's codex guardian reindex marker")
            XCTAssertEqual(toolIO, 1, "session_tool_io[\(source)] must survive bootstrap's codex guardian reindex marker")
        }
    }

    /// Locks the in-place mtime migration: millisecond-scale session_meta rows are
    /// converted for every source, seconds-scale rows and row counts stay unchanged,
    /// and session_search retains the millisecond identity revision used by ingest.
    func testBootstrapSessionMetaMtimeMigrationNormalizesAllSourcesInPlace() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        defer { IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider }

        IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
        var db: IndexDB? = try IndexDB()
        IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

        let millis: Int64 = 1_776_370_012_000
        let seconds: Int64 = 1_776_370_012
        try await seedSession(db!, source: "opencode", id: "opencode-ms",
                              metaMtime: millis, searchMtime: millis)
        try await seedSession(db!, source: "hermes", id: "hermes-ms",
                              metaMtime: millis, searchMtime: millis)
        try await seedSession(db!, source: "opencode", id: "opencode-seconds",
                              metaMtime: seconds, searchMtime: seconds)
        try await seedSession(db!, source: "claude", id: "claude-seconds",
                              metaMtime: seconds, searchMtime: seconds)
        try await db!.begin()
        for source in ["opencode", "hermes", "claude"] {
            _ = try await db!.populateSessionDaysFromMeta(for: source)
        }
        try await db!.commit()

        // Simulate the upgrade where this marker has never run.
        try await db!.exec("DELETE FROM schema_migrations WHERE key = 'session_meta_mtime_seconds_v1';")
        db = nil

        IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
        let reopened = try IndexDB()
        IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

        let metaCount = try await reopened.rowCountForTesting(table: "session_meta")
        let searchCount = try await reopened.rowCountForTesting(table: "session_search")
        let toolIOCount = try await reopened.rowCountForTesting(table: "session_tool_io")
        let dayCount = try await reopened.rowCountForTesting(table: "session_days")
        XCTAssertEqual(metaCount, 4)
        XCTAssertEqual(searchCount, 4)
        XCTAssertEqual(toolIOCount, 4)
        XCTAssertEqual(dayCount, 4)

        let opencodeMeta = Dictionary(uniqueKeysWithValues:
            try await reopened.fetchSessionMeta(for: "opencode").map { ($0.sessionID, $0.mtime) })
        let hermesMeta = Dictionary(uniqueKeysWithValues:
            try await reopened.fetchSessionMeta(for: "hermes").map { ($0.sessionID, $0.mtime) })
        let claudeMeta = Dictionary(uniqueKeysWithValues:
            try await reopened.fetchSessionMeta(for: "claude").map { ($0.sessionID, $0.mtime) })
        XCTAssertEqual(opencodeMeta["opencode-ms"], seconds)
        XCTAssertEqual(hermesMeta["hermes-ms"], seconds)
        XCTAssertEqual(opencodeMeta["opencode-seconds"], seconds)
        XCTAssertEqual(claudeMeta["claude-seconds"], seconds)

        let opencodeSearch = try await reopened.sessionSearchIdentityStatesByID(for: "opencode")
        let hermesSearch = try await reopened.sessionSearchIdentityStatesByID(for: "hermes")
        XCTAssertEqual(opencodeSearch["opencode-ms"]?.revision.updatedMillis, millis,
                       "session_search must retain the millisecond identity revision")
        XCTAssertEqual(hermesSearch["hermes-ms"]?.revision.updatedMillis, millis,
                       "the migration must not normalize identity revisions")

        let opencodeDayUpdates = try await reopened.findSessionsNeedingDayUpdate(source: "opencode")
        let hermesDayUpdates = try await reopened.findSessionsNeedingDayUpdate(source: "hermes")
        let claudeDayUpdates = try await reopened.findSessionsNeedingDayUpdate(source: "claude")
        XCTAssertEqual(opencodeDayUpdates, ["opencode-ms"])
        XCTAssertEqual(hermesDayUpdates, ["hermes-ms"])
        XCTAssertTrue(claudeDayUpdates.isEmpty)
    }

    // MARK: - claude_request_log_reindex_v2 (repairs v1)

    private static let requestLogLine = #"{"type":"api-request-blob","sessionId":"s","hash":"b1","message":{"role":"user","content":[{"type":"text","text":"copy"}]}}"#
    private static let plainLine = #"{"type":"user","sessionId":"s","message":{"role":"user","content":"hello"},"uuid":"u1","timestamp":"2026-10-21T00:00:00.000Z"}"#

    private func seedPath(_ db: IndexDB, source: String, id: String, path: String) async throws {
        try await db.upsertFile(path: path, mtime: 100, size: 200, source: source)
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: id, source: source, path: path,
            mtime: 100, size: 200, startTS: 100, endTS: 200,
            model: nil, cwd: nil, repo: nil, title: "t",
            codexInternalSessionID: nil, isHousekeeping: false,
            messages: 3, commands: 1,
            parentSessionID: nil, subagentType: nil, customTitle: nil))
        try await db.upsertSessionSearch(sessionID: id, source: source,
            mtime: 100, size: 200, text: "hello \(id)")
        try await db.upsertSessionToolIO(sessionID: id, source: source,
            mtime: 100, size: 200, refTS: 200, text: "tool io \(id)")
    }

    private func rowCounts(_ db: IndexDB, source: String) async throws -> [Int] {
        var out: [Int] = []
        for table in ["files", "session_meta", "session_search", "session_tool_io"] {
            out.append(try await db.rowCountForTesting(table: table, source: source))
        }
        return out
    }

    /// Only Claude paths whose file holds a request-log record lose their rows (all four
    /// tables) and their Image Browser index; unaffected, missing, too-old and
    /// non-Claude paths keep theirs. A temp database and temp files only.
    func testClaudeRequestLogReindexDropsOnlyAffectedClaudePaths() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogReindex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let affected = dir.appendingPathComponent("affected.jsonl")
        let clean = dir.appendingPathComponent("clean.jsonl")
        let old = dir.appendingPathComponent("old.jsonl")
        let missing = dir.appendingPathComponent("missing.jsonl")
        let codex = dir.appendingPathComponent("codex.jsonl")
        try (Self.plainLine + "\n" + Self.requestLogLine + "\n").write(to: affected, atomically: true, encoding: .utf8)
        try (Self.plainLine + "\n").write(to: clean, atomically: true, encoding: .utf8)
        try (Self.plainLine + "\n" + Self.requestLogLine + "\n").write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_788_220_800)], // 2026-09-01
                             ofItemAtPath: old.path)
        try (Self.requestLogLine + "\n").write(to: codex, atomically: true, encoding: .utf8)

        try await seedPath(db, source: "claude", id: "affected", path: affected.path)
        try await seedPath(db, source: "claude", id: "clean", path: clean.path)
        try await seedPath(db, source: "claude", id: "old", path: old.path)
        try await seedPath(db, source: "claude", id: "missing", path: missing.path)
        try await seedPath(db, source: "codex", id: "codex", path: codex.path)

        let cacheRoot = dir.appendingPathComponent("ImageCache", isDirectory: true)
        let cache = ImageBrowserIndexCache(cacheRootOverride: cacheRoot)
        func session(_ url: URL) -> Session {
            Session(id: url.lastPathComponent, source: .claude, startTime: nil, endTime: nil,
                    model: nil, filePath: url.path, eventCount: 0, events: [])
        }
        _ = await cache.getOrBuildIndex(for: session(affected), maxMatches: 10)
        _ = await cache.getOrBuildIndex(for: session(clean), maxMatches: 10)
        let affectedIndexBefore = await cache.loadIndexIfValid(for: session(affected))
        XCTAssertNotNil(affectedIndexBefore, "guard: the affected file must have a cached image index")

        let reindexed = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: cache)

        XCTAssertEqual(reindexed, [affected.path])
        let affectedPath = affected.path
        let claudePathsLeft = try await db.recordedPaths(source: "claude")
        XCTAssertFalse(claudePathsLeft.contains(affectedPath))
        XCTAssertEqual(Set(claudePathsLeft), Set([clean.path, old.path, missing.path]))
        let claudeCounts = try await rowCounts(db, source: "claude")
        XCTAssertEqual(claudeCounts, [3, 3, 3, 3], "only the affected path's four rows go")
        let codexCounts = try await rowCounts(db, source: "codex")
        XCTAssertEqual(codexCounts, [1, 1, 1, 1], "other sources are never touched")

        let affectedIndexAfter = await cache.loadIndexIfValid(for: session(affected))
        let cleanIndexAfter = await cache.loadIndexIfValid(for: session(clean))
        XCTAssertNil(affectedIndexAfter, "the affected file's image index must be removed")
        XCTAssertNotNil(cleanIndexAfter, "other image indexes stay")
        let applied = try await db.isMigrationApplied(ClaudeRequestLogReindexMigration.migrationKey)
        XCTAssertTrue(applied)
    }

    /// The marker makes it one-time: the second call neither scans nor deletes.
    func testClaudeRequestLogReindexRunsOnlyOnce() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        try await seedPath(db, source: "claude", id: "a", path: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")

        var scans = 0
        let first = try await ClaudeRequestLogReindexMigration.runIfNeeded(
            db: db, imageIndexCache: nil, scanFile: { _ in scans += 1; return .affected })
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(scans, 1)

        try await seedPath(db, source: "claude", id: "b", path: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        let second = try await ClaudeRequestLogReindexMigration.runIfNeeded(
            db: db, imageIndexCache: nil, scanFile: { _ in scans += 1; return .affected })
        XCTAssertEqual(second, [])
        XCTAssertEqual(scans, 1, "a recorded marker must skip the scan")
        let claudeMeta = try await db.rowCountForTesting(table: "session_meta", source: "claude")
        XCTAssertEqual(claudeMeta, 1, "rows written after the migration stay")
    }

    /// The scan uses the parser's rule (`ClaudeSessionParser.isRequestLogRecord`): a
    /// top-level `type` that starts with `api-request`, any case, any JSON spacing or
    /// key order. Text that only mentions the type inside another record does not count.
    func testClaudeRequestLogScanMatchesParserRule() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogRule-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let cases: [(name: String, line: String, expected: ClaudeRequestLogReindexMigration.Scan)] = [
            ("whitespace", #"{"type": "api-request-blob", "sessionId": "s", "message": {"role": "user", "content": "copy"}}"#, .affected),
            ("uppercase", #"{"type":"API-REQUEST-SHAPE","sessionId":"s","system":"prompt"}"#, .affected),
            ("mixed-case-key-order", #"{"sessionId":"s","type" : "Api-Request","params":{}}"#, .affected),
            ("mention-only", #"{"type":"user","sessionId":"s","message":{"role":"user","content":"why does \"type\": \"API-Request-blob\" show up?"}}"#, .unaffected),
        ]
        for c in cases {
            let url = dir.appendingPathComponent("\(c.name).jsonl")
            try (Self.plainLine + "\n" + c.line + "\n" + Self.plainLine + "\n").write(to: url, atomically: true, encoding: .utf8)
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.line.utf8)) as? [String: Any])
            XCTAssertEqual(ClaudeSessionParser.isRequestLogRecord(obj), c.expected == .affected,
                           "guard: \(c.name) must match what the parser skips")
            XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: url.path), c.expected, c.name)
        }
    }

    /// A Claude file that exists but cannot be read keeps the marker unwritten. The
    /// readable affected file is reindexed at once; the next run rescans only the file
    /// that failed, reindexes it, and then writes the marker.
    func testClaudeRequestLogReindexRetriesUnreadableFiles() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogRetry-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let unreadable = dir.appendingPathComponent("unreadable.jsonl")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
            try? fm.removeItem(at: dir)
        }

        let readable = dir.appendingPathComponent("readable.jsonl")
        let missing = dir.appendingPathComponent("missing.jsonl")
        try (Self.requestLogLine + "\n").write(to: readable, atomically: true, encoding: .utf8)
        try (Self.requestLogLine + "\n").write(to: unreadable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        try await seedPath(db, source: "claude", id: "readable", path: readable.path)
        try await seedPath(db, source: "claude", id: "unreadable", path: unreadable.path)
        try await seedPath(db, source: "claude", id: "missing", path: missing.path)

        let first = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: nil)
        XCTAssertEqual(first, [readable.path])
        let appliedAfterFirst = try await db.isMigrationApplied(ClaudeRequestLogReindexMigration.migrationKey)
        XCTAssertFalse(appliedAfterFirst, "an unreadable candidate must leave the marker unwritten")
        let pathsAfterFirst = try await db.recordedPaths(source: "claude")
        XCTAssertEqual(Set(pathsAfterFirst), Set([unreadable.path, missing.path]))

        // Ingest rebuilds the readable file's rows with the fixed parser.
        try await seedPath(db, source: "claude", id: "readable", path: readable.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)

        let second = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: nil)
        XCTAssertEqual(second, [unreadable.path], "the retry reindexes the file that failed, and only that file")
        let appliedAfterSecond = try await db.isMigrationApplied(ClaudeRequestLogReindexMigration.migrationKey)
        XCTAssertTrue(appliedAfterSecond)
        let pathsAfterSecond = try await db.recordedPaths(source: "claude")
        XCTAssertEqual(Set(pathsAfterSecond), Set([readable.path, missing.path]),
                       "the rebuilt rows of the already-reindexed file stay")
    }

    /// A failed Image Browser index removal stays pending after the marker commits, and
    /// a later run removes it and clears the entry.
    func testClaudeRequestLogReindexRetriesFailedImageIndexRemoval() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogImage-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = dir.appendingPathComponent("ImageCache", isDirectory: true)
        let indexDir = cacheRoot.appendingPathComponent("Index", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexDir.path)
            try? fm.removeItem(at: dir)
        }

        let affected = dir.appendingPathComponent("affected.jsonl")
        try (Self.plainLine + "\n" + Self.requestLogLine + "\n").write(to: affected, atomically: true, encoding: .utf8)
        try await seedPath(db, source: "claude", id: "affected", path: affected.path)
        let cache = ImageBrowserIndexCache(cacheRootOverride: cacheRoot)
        let session = Session(id: "affected", source: .claude, startTime: nil, endTime: nil,
                              model: nil, filePath: affected.path, eventCount: 0, events: [])
        _ = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        let before = await cache.loadIndexIfValid(for: session)
        XCTAssertNotNil(before, "guard: the affected file must have a cached image index")

        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: indexDir.path)
        let first = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: cache)
        XCTAssertEqual(first, [affected.path])
        let stillCached = await cache.loadIndexIfValid(for: session)
        XCTAssertNotNil(stillCached, "guard: the removal must really have failed")
        let pendingAfterFailure = try await db.pendingImageCacheInvalidations()
        XCTAssertEqual(pendingAfterFailure, [affected.path], "a failed removal stays pending")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: indexDir.path)
        let second = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: cache)
        XCTAssertEqual(second, [], "the marker is written; no rescan")
        let afterRetry = await cache.loadIndexIfValid(for: session)
        XCTAssertNil(afterRetry, "the pending removal is retried after the marker")
        let pendingAfterRetry = try await db.pendingImageCacheInvalidations()
        XCTAssertEqual(pendingAfterRetry, [])
    }

    /// Crash after the commit: the marker and the pending entries are in the database
    /// but no index was removed. The next run removes the index (a missing index counts
    /// as removed) and clears every entry.
    func testClaudeRequestLogReindexFinishesImageInvalidationAfterCrash() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogCrash-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let affected = dir.appendingPathComponent("affected.jsonl")
        let noIndex = dir.appendingPathComponent("no-index.jsonl")
        try (Self.plainLine + "\n" + Self.requestLogLine + "\n").write(to: affected, atomically: true, encoding: .utf8)
        try (Self.requestLogLine + "\n").write(to: noIndex, atomically: true, encoding: .utf8)
        try await seedPath(db, source: "claude", id: "affected", path: affected.path)
        try await seedPath(db, source: "claude", id: "no-index", path: noIndex.path)
        let cache = ImageBrowserIndexCache(cacheRootOverride: dir.appendingPathComponent("ImageCache", isDirectory: true))
        let session = Session(id: "affected", source: .claude, startTime: nil, endTime: nil,
                              model: nil, filePath: affected.path, eventCount: 0, events: [])
        _ = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        let before = await cache.loadIndexIfValid(for: session)
        XCTAssertNotNil(before, "guard: the affected file must have a cached image index")

        // The transaction commits, then the process dies before touching the cache.
        try await db.applyPathScopedReindex(source: "claude", paths: [affected.path, noIndex.path],
                                            migrationKey: ClaudeRequestLogReindexMigration.migrationKey)
        let pendingAfterCrash = try await db.pendingImageCacheInvalidations()
        XCTAssertEqual(Set(pendingAfterCrash), Set([affected.path, noIndex.path]),
                       "the pending removals commit with the deletes")

        let rerun = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: cache)
        XCTAssertEqual(rerun, [])
        let after = await cache.loadIndexIfValid(for: session)
        XCTAssertNil(after, "the stale index must be removed even though the marker was already written")
        let pendingAfterRerun = try await db.pendingImageCacheInvalidations()
        XCTAssertEqual(pendingAfterRerun, [])
    }

    func testClaudeRequestLogV1MarkerDoesNotBlockV2Repair() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        try await db.applyPathScopedReindex(source: "claude", paths: [],
                                            migrationKey: "claude_request_log_reindex_v1")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeRequestLogV2-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try (Self.requestLogLine + "\n").write(to: file, atomically: true, encoding: .utf8)
        try await seedPath(db, source: "claude", id: "v1-survivor", path: file.path)

        let repaired = try await ClaudeRequestLogReindexMigration.runIfNeeded(db: db, imageIndexCache: nil)
        XCTAssertEqual(repaired, [file.path])
        let v2Applied = try await db.isMigrationApplied(ClaudeRequestLogReindexMigration.migrationKey)
        let remaining = try await db.rowCountForTesting(table: "session_meta", source: "claude")
        XCTAssertTrue(v2Applied)
        XCTAssertEqual(remaining, 0)
    }

    func testClaudeRequestLogEarlyMatchDoesNotMaskLateReadFailure() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeRequestLogLateRead-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try (Self.requestLogLine + "\n" + String(repeating: "x", count: 1 << 20) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        var calls = 0
        let result = ClaudeRequestLogReindexMigration.scanFile(atPath: file.path) { handle, count in
            calls += 1
            // Three reads complete the cheap candidate pass (including EOF).
            // Fail the second read of the JSONL validation pass, after a
            // valid top-level request-log record has already been decoded.
            if calls == 5 { throw NSError(domain: "injected-late-read", code: 1) }
            return try handle.read(upToCount: min(count, 1 << 20)) ?? Data()
        }
        XCTAssertEqual(result, .unreadable)
        XCTAssertGreaterThan(calls, 4)
    }

    /// The streaming check finds a marker split across its 1 MiB read boundary, treats
    /// missing and pre-cutoff files as unaffected and reports unreadable files.
    func testClaudeRequestLogFileCheck() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ClaudeRequestLogCheck-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("unreadable.jsonl").path)
            try? fm.removeItem(at: dir)
        }

        let split = dir.appendingPathComponent("split.jsonl")
        // A valid JSONL object crosses the one-MiB chunk boundary.
        let prefix = #"{"content":""# + String(repeating: "x", count: (1 << 20) - 20)
        let line = prefix + "\"" + #","type":"api-request-blob"}"#
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        try (line + "\n").write(to: split, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: split.path), .affected)

        let malformed = dir.appendingPathComponent("malformed.jsonl")
        try (#""type":"api-request-blob"}"# + "\n").write(to: malformed, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: malformed.path), .unaffected)

        let nested = dir.appendingPathComponent("nested.jsonl")
        try (#"{"type":"user","payload":{"type":"api-request-blob"}}"# + "\n")
            .write(to: nested, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: nested.path), .unaffected)

        let plain = dir.appendingPathComponent("plain.jsonl")
        try (Self.plainLine + "\n").write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: plain.path), .unaffected)

        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: dir.appendingPathComponent("missing.jsonl").path), .unaffected)

        let old = dir.appendingPathComponent("old.jsonl")
        try (Self.requestLogLine + "\n").write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_788_220_800)], // 2026-09-01
                             ofItemAtPath: old.path)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: old.path), .unaffected)

        let unreadable = dir.appendingPathComponent("unreadable.jsonl")
        try (Self.requestLogLine + "\n").write(to: unreadable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        XCTAssertEqual(ClaudeRequestLogReindexMigration.scanFile(atPath: unreadable.path), .unreadable)
    }
}
#endif
