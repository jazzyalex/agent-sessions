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

    private func seedSession(_ db: IndexDB, source: String, id: String) async throws {
        try await db.upsertSessionMeta(SessionMetaRow(
            sessionID: id, source: source, path: "/tmp/\(id).jsonl",
            mtime: 100, size: 200, startTS: 100, endTS: 200,
            model: nil, cwd: nil, repo: nil, title: "t",
            codexInternalSessionID: nil, isHousekeeping: false,
            messages: 3, commands: 1,
            parentSessionID: nil, subagentType: nil, customTitle: nil))
        try await db.upsertSessionSearch(sessionID: id, source: source,
            mtime: 100, size: 200, text: "hello \(source) searchable")
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
}
#endif
