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

    // MARK: - SearchIngestService

    private var ingestTempDir: URL!

    private func makeCodexFixture(named name: String, userText: String, assistantText: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let lines = [
            #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(userText)"}]}}"#,
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(assistantText)"}]}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileRef(for url: URL) throws -> SearchIngestService.FileRef {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = Int64((attrs[.size] as? NSNumber)?.int64Value ?? 0)
        let mtime = Int64(((attrs[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        return SearchIngestService.FileRef(path: url.path, mtime: mtime, size: size)
    }

    override func setUp() async throws {
        try await super.setUp()
        ingestTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIngestService-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ingestTempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let ingestTempDir { try? FileManager.default.removeItem(at: ingestTempDir) }
        ingestTempDir = nil
        try await super.tearDown()
    }

    func testIngestPopulatesSearchCorpusFromJSONLFixture() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let urlA = try makeCodexFixture(named: "a.jsonl", userText: "please find the zebranought token", assistantText: "sure, looking into zebranought now", in: ingestTempDir)
        let urlB = try makeCodexFixture(named: "b.jsonl", userText: "unrelated question about koalaquartz", assistantText: "answering about koalaquartz", in: ingestTempDir)

        let service = SearchIngestService(db: db)
        let progress = try await service.ingest(
            source: .codex,
            files: [try fileRef(for: urlA), try fileRef(for: urlB)],
            toolIOEnabled: false
        )

        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.processed, 2)
        XCTAssertEqual(progress.skipped, 0)

        let hasData = try await db.hasSearchData(sources: ["codex"])
        XCTAssertTrue(hasData, "ingest must populate session_search rows")

        let matches = try await db.searchSessionIDsFTS(
            sources: ["codex"],
            model: nil,
            repoSubstr: nil,
            pathSubstr: nil,
            dateFrom: nil,
            dateTo: nil,
            query: "zebranought",
            includeSystemProbes: true,
            limit: 10
        )
        XCTAssertEqual(matches.count, 1, "planted word must match exactly one session")

        let expectedID = SessionIndexer().parseFileFull(at: urlA)?.id
        XCTAssertNotNil(expectedID)
        XCTAssertEqual(matches.first, expectedID)
    }

    func testIngestSkipsAlreadyCurrentFiles() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let urlA = try makeCodexFixture(named: "a.jsonl", userText: "first pass content aardvarkiris", assistantText: "ack aardvarkiris", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        let ref = try fileRef(for: urlA)

        let first = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: false)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.processed, 1)

        let second = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: false)
        XCTAssertEqual(second.total, 1)
        XCTAssertEqual(second.skipped, 1, "unchanged file must be skipped on the second run")
        XCTAssertEqual(second.processed, 0)
    }

    func testIngestReindexesOnMtimeChange() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let urlA = try makeCodexFixture(named: "a.jsonl", userText: "original content porcupinehazel", assistantText: "ack porcupinehazel", in: ingestTempDir)
        let urlB = try makeCodexFixture(named: "b.jsonl", userText: "stable content marmotcinder", assistantText: "ack marmotcinder", in: ingestTempDir)
        let service = SearchIngestService(db: db)

        let refA1 = try fileRef(for: urlA)
        let refB = try fileRef(for: urlB)
        _ = try await service.ingest(source: .codex, files: [refA1, refB], toolIOEnabled: false)

        // Bump mtime+content on file A only.
        try (
            #"{"timestamp":"2026-01-01T00:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"updated content walrustangerine"}]}}"#
            + "\n" +
            #"{"timestamp":"2026-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ack walrustangerine"}]}}"#
            + "\n"
        ).write(to: urlA, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: urlA.path)
        let refA2 = try fileRef(for: urlA)
        XCTAssertNotEqual(refA2.mtime, refA1.mtime, "sanity: mtime must have changed")

        let second = try await service.ingest(source: .codex, files: [refA2, refB], toolIOEnabled: false)
        XCTAssertEqual(second.total, 2)
        XCTAssertEqual(second.skipped, 1, "only the unchanged file (b) should be skipped")
        XCTAssertEqual(second.processed, 1)

        let newMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "walrustangerine", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(newMatches.count, 1, "reindexed file's new content must be findable")

        let staleMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "porcupinehazel", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(staleMatches.count, 0, "stale content must no longer match after reindex")

        let stableMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "marmotcinder", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(stableMatches.count, 1, "unchanged file b must remain findable across both runs")
    }

    // MARK: - SearchIngestCoordinator (pure single-flight + coalesce state machine)

    func testCoordinatorStartsImmediatelyWhenIdle() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
    }

    func testCoordinatorCoalescesRequestWhileInFlight() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)

        // A second request while the first is still running must coalesce, not start
        // a second overlapping run.
        XCTAssertEqual(coordinator.request(source: .codex), .coalesced)
        XCTAssertTrue(coordinator.isInFlight(source: .codex))
    }

    func testCoordinatorBurstOfRequestsCoalescesToExactlyOneFollowUp() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)

        // A burst of N requests while in flight must still yield exactly one follow-up,
        // not N follow-ups.
        for _ in 0..<5 {
            XCTAssertEqual(coordinator.request(source: .codex), .coalesced)
        }

        XCTAssertTrue(coordinator.finish(source: .codex), "a coalesced request must trigger exactly one follow-up run")
        XCTAssertFalse(coordinator.isInFlight(source: .codex), "finish() reports the follow-up is owed; it does not itself re-enter in-flight state")

        // Simulate the caller starting that one follow-up run, then finishing with no
        // further requests: no second follow-up should be reported.
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
        XCTAssertFalse(coordinator.finish(source: .codex), "no further requests arrived during the follow-up run")
    }

    func testCoordinatorFinishWithoutPendingReportsNoFollowUp() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
        XCTAssertFalse(coordinator.finish(source: .codex), "no coalesced request arrived, so no follow-up is owed")
        XCTAssertFalse(coordinator.isInFlight(source: .codex))
    }

    func testCoordinatorTracksSourcesIndependently() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
        // A different source must not be affected by codex's in-flight state.
        XCTAssertEqual(coordinator.request(source: .claude), .startNow)
        XCTAssertTrue(coordinator.isInFlight(source: .codex))
        XCTAssertTrue(coordinator.isInFlight(source: .claude))
    }

    func testCoordinatorAllowsRestartAfterCleanFinish() {
        var coordinator = SearchIngestCoordinator()
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
        XCTAssertFalse(coordinator.finish(source: .codex))
        // A brand-new request after a clean finish (no coalescing) starts immediately again.
        XCTAssertEqual(coordinator.request(source: .codex), .startNow)
    }
}
