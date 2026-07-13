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
}
#endif
