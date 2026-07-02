import XCTest
@testable import AgentSessions

/// Hosts all W2 (search-ingest) tests.
final class SearchIngestTests: XCTestCase {

    private func makeMetaRow(sessionID: String, source: String, path: String, mtime: Int64) -> SessionMetaRow {
        SessionMetaRow(
            sessionID: sessionID,
            source: source,
            path: path,
            mtime: mtime,
            size: 10,
            startTS: 1,
            endTS: 2,
            model: nil,
            cwd: nil,
            repo: nil,
            title: nil,
            codexInternalSessionID: nil,
            isHousekeeping: false,
            messages: 1,
            commands: 0,
            parentSessionID: nil,
            subagentType: nil,
            customTitle: nil
        )
    }

    // MARK: - deleteSessionsForPaths

    func testDeleteSessionsForPathsAlsoRemovesSearchRows() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        try await db.begin()
        try await db.upsertFile(path: "/tmp/a.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "s1", source: "codex", path: "/tmp/a.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "s1", source: "codex", mtime: 1, size: 10, text: "needle haystack")
        try await db.upsertSessionToolIO(sessionID: "s1", source: "codex", mtime: 1, size: 10, refTS: 1, text: "tool output needle")
        try await db.commit()

        let hasDataBefore = try await db.hasSearchData(sources: ["codex"])
        XCTAssertTrue(hasDataBefore, "sanity: search rows should exist before deletion")

        _ = try await db.deleteSessionsForPaths(source: "codex", paths: ["/tmp/a.jsonl"])

        let hasData = try await db.hasSearchData(sources: ["codex"])
        XCTAssertFalse(hasData, "search rows for deleted files must be removed")
    }

    // MARK: - purgeOrphanedSessionMeta (the actual production reconciliation path)

    func testPurgeOrphanedSessionMetaAlsoRemovesSearchRows() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        try await db.begin()
        // "kept" file/session stays on disk; "orphan" session's file has been removed
        // from the files table (simulating deletion) but session_meta/search rows linger.
        try await db.upsertFile(path: "/tmp/kept.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "kept", source: "codex", path: "/tmp/kept.jsonl", mtime: 1))
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "orphan", source: "codex", path: "/tmp/orphan.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "kept", source: "codex", mtime: 1, size: 10, text: "keep me")
        try await db.upsertSessionSearch(sessionID: "orphan", source: "codex", mtime: 1, size: 10, text: "orphan needle")
        try await db.upsertSessionToolIO(sessionID: "kept", source: "codex", mtime: 1, size: 10, refTS: 1, text: "keep tool output")
        try await db.upsertSessionToolIO(sessionID: "orphan", source: "codex", mtime: 1, size: 10, refTS: 1, text: "orphan tool output")
        try await db.commit()

        try await db.begin()
        _ = try await db.purgeOrphanedSessionMeta(for: "codex")
        try await db.commit()

        let remainingSessionIDs = try await db.indexedSessionIDs(sources: ["codex"])
        XCTAssertFalse(remainingSessionIDs.contains("orphan"), "session_search row for orphaned session must be removed")
        XCTAssertTrue(remainingSessionIDs.contains("kept"), "session_search row for still-present session must be preserved")
    }
}
