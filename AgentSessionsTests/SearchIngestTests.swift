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

    private func makeCodexFixture(named name: String, userText: String, assistantText: String, in dir: URL, isoTimestamp: String = "2026-01-01T00:00:00.000Z") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let lines = [
            #"{"timestamp":"\#(isoTimestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(userText)"}]}}"#,
            #"{"timestamp":"\#(isoTimestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(assistantText)"}]}}"#
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
        // quietSeconds: 0 — this test is exercising mtime/size change detection
        // (indexedByPath vs. the caller's freshly-stat'd FileRef), independent of the
        // quiet-period gate added for actively-appending files. See
        // testIngestSkipsHotFileWithinQuietPeriod/testIngestReindexesQuietFileAfterQuietPeriodElapses
        // for gate-specific coverage.
        _ = try await service.ingest(source: .codex, files: [refA1, refB], toolIOEnabled: false, quietSeconds: 0)

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

        let second = try await service.ingest(source: .codex, files: [refA2, refB], toolIOEnabled: false, quietSeconds: 0)
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

    // MARK: - SearchIngestService: quiet-period gate

    func testIngestSkipsHotFileWithinQuietPeriod() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let url = try makeCodexFixture(named: "hot.jsonl", userText: "first pass content lemursaffron", assistantText: "ack lemursaffron", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        // Back-date the initial mtime by an hour so the follow-up "now" mtime (below)
        // is guaranteed to differ, independent of how fast this test executes.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: url.path)
        let firstRef = try fileRef(for: url)

        // Establish an existing row so the second call is a re-ingest, not first-time.
        let first = try await service.ingest(source: .codex, files: [firstRef], toolIOEnabled: false, quietSeconds: 3600)
        XCTAssertEqual(first.processed, 1)

        // Mutate the file and bump mtime to "now" so it looks actively-changing.
        try "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"updated hot content ibexsulphur\"}]}}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let hotRef = try fileRef(for: url)
        XCTAssertNotEqual(hotRef.mtime, firstRef.mtime, "sanity: mtime must have changed")

        // Re-run with a long quiet period: the hot (recently-modified) file must be
        // skipped, and its stale (pre-mutation) search row must be retained rather
        // than rewritten with the new (as-yet-unstable) content.
        let second = try await service.ingest(source: .codex, files: [hotRef], toolIOEnabled: false, quietSeconds: 3600)
        XCTAssertEqual(second.skipped, 1, "hot file within the quiet period must be skipped")
        XCTAssertEqual(second.processed, 0)

        let staleStillThere = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "lemursaffron", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(staleStillThere.count, 1, "stale row must be retained (not blown away) while the file is hot")
    }

    func testIngestReindexesQuietFileAfterQuietPeriodElapses() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let url = try makeCodexFixture(named: "quiet.jsonl", userText: "first pass content tapirumber", assistantText: "ack tapirumber", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        let firstRef = try fileRef(for: url)

        let first = try await service.ingest(source: .codex, files: [firstRef], toolIOEnabled: false, quietSeconds: 3600)
        XCTAssertEqual(first.processed, 1)

        // Mutate the file, but set its mtime 2 hours in the past — simulating a session
        // that has gone quiet well beyond the quiet window.
        try "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"settled content quokkabramble\"}]}}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: url.path)
        let quietRef = try fileRef(for: url)
        XCTAssertNotEqual(quietRef.mtime, firstRef.mtime, "sanity: mtime must have changed")

        let second = try await service.ingest(source: .codex, files: [quietRef], toolIOEnabled: false, quietSeconds: 3600)
        XCTAssertEqual(second.processed, 1, "file quiet well beyond the window must be re-ingested")
        XCTAssertEqual(second.skipped, 0)

        let newContentMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "quokkabramble", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(newContentMatches.count, 1, "new content must be findable after the quiet file is re-ingested")
    }

    func testIngestNeverIngestedHotFileIsIngestedImmediately() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        // Fresh file, mtime "now" (hot), and — critically — no prior row in the DB at
        // all (simulating a fresh backfill). Even with a long quiet window, this must
        // be ingested immediately: the exemption exists so first-time indexing is
        // never delayed by the quiet gate.
        let url = try makeCodexFixture(named: "fresh.jsonl", userText: "brand new content ocelotginger", assistantText: "ack ocelotginger", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        let ref = try fileRef(for: url)

        let progress = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: false, quietSeconds: 3600)
        XCTAssertEqual(progress.processed, 1, "never-ingested file must be ingested regardless of quietness")
        XCTAssertEqual(progress.skipped, 0)

        let matches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "ocelotginger", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(matches.count, 1, "fresh hot file's content must be immediately findable")
    }

    // MARK: - SearchIngestService: size-aware re-ingest cooldown

    func testReingestCooldownTiers() {
        // Small tier: strictly under 2MB gets no additional cooldown (quiet gate alone).
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 0), 0)
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 1_999_999), 0)

        // Medium tier: [2MB, 20MB) -> 15 minutes.
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 2_000_000), 15 * 60)
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 19_999_999), 15 * 60)

        // Large tier: >= 20MB -> 45 minutes.
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 20_000_000), 45 * 60)
        XCTAssertEqual(SearchIngestService.reingestCooldown(forFileSize: 500_000_000), 45 * 60)
    }

    func testReingestCooldownSkipsSecondReingestWithinOverrideWindow() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let url = try makeCodexFixture(named: "cooldown.jsonl", userText: "first pass content nightjarumber", assistantText: "ack nightjarumber", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        let firstRef = try fileRef(for: url)

        // Call 1: first-time ingest (no existing row) — always proceeds, unaffected by
        // the cooldown gate (which only applies to RE-ingest). This also writes the
        // persisted `session_search.updated_at` timestamp that now backs the cooldown.
        let first = try await service.ingest(source: .codex, files: [firstRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 3600)
        XCTAssertEqual(first.processed, 1)

        // Mutate the file and push mtime 2 hours into the past so it clears the quiet
        // gate (quietSeconds: 0 disables that gate entirely).
        try "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"updated content jackalvermillion\"}]}}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: url.path)
        let secondRef = try fileRef(for: url)
        XCTAssertNotEqual(secondRef.mtime, firstRef.mtime, "sanity: mtime must have changed")

        // Call 2: the first RE-ingest attempt for this path. Under the persisted
        // (DB-backed) cooldown, `session_search.updated_at` from call 1 is only
        // moments old, so this is blocked immediately — unlike the old in-memory
        // mechanism, there is no "first re-ingest this process run is free" grace
        // period, because the cooldown's clock started at the first successful
        // ingest, not at process/actor start.
        let second = try await service.ingest(source: .codex, files: [secondRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 3600)
        XCTAssertEqual(second.skipped, 1, "re-ingest within the cooldown window (measured from the first ingest's persisted timestamp) must be skipped")
        XCTAssertEqual(second.processed, 0)

        let staleStillThere = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "nightjarumber", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(staleStillThere.count, 1, "content from the first ingest must be retained while cooldown blocks the re-ingest")
    }

    func testReingestCooldownOverrideZeroAllowsImmediateReingest() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let url = try makeCodexFixture(named: "cooldown-zero.jsonl", userText: "first pass content ptarmigancobalt", assistantText: "ack ptarmigancobalt", in: ingestTempDir)
        let service = SearchIngestService(db: db)
        let firstRef = try fileRef(for: url)

        let first = try await service.ingest(source: .codex, files: [firstRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 0)
        XCTAssertEqual(first.processed, 1)

        try "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"updated content flamingoazure\"}]}}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: url.path)
        let secondRef = try fileRef(for: url)
        XCTAssertNotEqual(secondRef.mtime, firstRef.mtime, "sanity: mtime must have changed")

        let second = try await service.ingest(source: .codex, files: [secondRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 0)
        XCTAssertEqual(second.processed, 1, "a zero-length cooldown override must not block re-ingest")
        XCTAssertEqual(second.skipped, 0)

        let newContentMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "flamingoazure", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(newContentMatches.count, 1, "new content must be findable after cooldown-override-0 re-ingest")
    }

    /// Pins the actual bug this cooldown mechanism was rewritten to fix: the old
    /// `lastReingestAt` map lived in the `SearchIngestService` actor's own memory, so it
    /// was wiped every time a fresh service instance was constructed — exactly what
    /// happens on every app relaunch. This test proves the cooldown now survives that:
    /// it is re-derived from `session_search.updated_at` (read fresh via
    /// `sessionSearchUpdatedAt` at the top of every `ingest` call), not carried in
    /// process/actor state.
    func testReingestCooldownPersistsAcrossServiceInstances() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let url = try makeCodexFixture(named: "cooldown-persist.jsonl", userText: "first pass content wombatsienna", assistantText: "ack wombatsienna", in: ingestTempDir)

        // Instance 1 performs the first-time ingest, writing `session_search.updated_at`.
        let serviceOne = SearchIngestService(db: db)
        let firstRef = try fileRef(for: url)
        let first = try await serviceOne.ingest(source: .codex, files: [firstRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 3600)
        XCTAssertEqual(first.processed, 1)

        // Mutate the file and push mtime 2 hours into the past so it clears the quiet
        // gate entirely (quietSeconds: 0) and looks like a settled, changed file.
        try "{\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"updated content coyotebergamot\"}]}}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: url.path)
        let secondRef = try fileRef(for: url)
        XCTAssertNotEqual(secondRef.mtime, firstRef.mtime, "sanity: mtime must have changed")

        // Brand-new SearchIngestService actor, same underlying DB — simulates the
        // service being torn down and reconstructed across an app relaunch. It has no
        // in-memory state whatsoever; the cooldown must be honored purely from the
        // DB-persisted `updated_at` written by instance 1.
        let serviceTwo = SearchIngestService(db: db)
        let blocked = try await serviceTwo.ingest(source: .codex, files: [secondRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 3600)
        XCTAssertEqual(blocked.skipped, 1, "a fresh service instance must still honor the cooldown recorded by a prior instance")
        XCTAssertEqual(blocked.processed, 0)

        let staleStillThere = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "wombatsienna", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(staleStillThere.count, 1, "content from instance 1's ingest must be retained while the cross-instance cooldown blocks the re-ingest")

        // A third, also-fresh instance with cooldown override 0 must re-ingest
        // immediately: proves the block above is cooldown-driven, not a stuck gate.
        let serviceThree = SearchIngestService(db: db)
        let allowed = try await serviceThree.ingest(source: .codex, files: [secondRef], toolIOEnabled: false, quietSeconds: 0, reingestCooldownOverride: 0)
        XCTAssertEqual(allowed.processed, 1, "cooldown override 0 on yet another fresh instance must allow immediate re-ingest")
        XCTAssertEqual(allowed.skipped, 0)

        let newContentMatches = try await db.searchSessionIDsFTS(
            sources: ["codex"], model: nil, repoSubstr: nil, pathSubstr: nil,
            dateFrom: nil, dateTo: nil, query: "coyotebergamot", includeSystemProbes: true, limit: 10
        )
        XCTAssertEqual(newContentMatches.count, 1, "new content must be findable once the override-0 instance re-ingests")
    }

    // MARK: - SearchIngestService: tool-IO retention prune

    func testIngestPrunesOldToolIORowsBeyondBytesCap() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let now = Int64(Date().timeIntervalSince1970)
        let oldTS = now - Int64(FeatureFlags.toolIOIndexRecentDays + 5) * 24 * 60 * 60
        let recentTS = now

        // Seed two old tool-IO rows and one recent row directly (bypassing the
        // ingest loop's own recency gate, which only writes tool-IO for sessions
        // whose refTS is within the recent window). This isolates the prune step
        // under test from the ingest recency gate.
        try await db.begin()
        try await db.upsertFile(path: "/tmp/old1.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "old1", source: "codex", path: "/tmp/old1.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "old1", source: "codex", mtime: 1, size: 10, text: "old one")
        try await db.upsertSessionToolIO(sessionID: "old1", source: "codex", mtime: 1, size: 10, refTS: oldTS, text: String(repeating: "x", count: 5_000))

        try await db.upsertFile(path: "/tmp/old2.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "old2", source: "codex", path: "/tmp/old2.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "old2", source: "codex", mtime: 1, size: 10, text: "old two")
        try await db.upsertSessionToolIO(sessionID: "old2", source: "codex", mtime: 1, size: 10, refTS: oldTS, text: String(repeating: "y", count: 5_000))

        try await db.upsertFile(path: "/tmp/recent.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "recent", source: "codex", path: "/tmp/recent.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "recent", source: "codex", mtime: 1, size: 10, text: "recent one")
        try await db.upsertSessionToolIO(sessionID: "recent", source: "codex", mtime: 1, size: 10, refTS: recentTS, text: String(repeating: "z", count: 5_000))
        try await db.commit()

        let idsBefore = try await db.toolIOSessionIDs(sources: ["codex"])
        XCTAssertEqual(Set(idsBefore), ["old1", "old2", "recent"], "sanity: all three seeded rows present before prune")

        // A single empty-files ingest run with toolIOEnabled + a tiny cap should
        // trigger the retention prune as its post-loop step, evicting old rows
        // (oldest ref_ts first) until under cap, while leaving the recent row alone.
        let service = SearchIngestService(db: db)
        _ = try await service.ingest(
            source: .codex,
            files: [],
            toolIOEnabled: true,
            toolIOOldBytesCap: 1
        )

        let idsAfter = try await db.toolIOSessionIDs(sources: ["codex"])
        XCTAssertFalse(idsAfter.contains("old1"), "old row must be pruned once old-bytes exceed the cap")
        XCTAssertFalse(idsAfter.contains("old2"), "old row must be pruned once old-bytes exceed the cap")
        XCTAssertTrue(idsAfter.contains("recent"), "recent row must survive the prune regardless of cap")
    }

    func testIngestSkipsPruneWhenToolIODisabled() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let oldTS = Int64(Date().timeIntervalSince1970) - Int64(FeatureFlags.toolIOIndexRecentDays + 5) * 24 * 60 * 60

        try await db.begin()
        try await db.upsertFile(path: "/tmp/old1.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(makeMetaRow(sessionID: "old1", source: "codex", path: "/tmp/old1.jsonl", mtime: 1))
        try await db.upsertSessionSearch(sessionID: "old1", source: "codex", mtime: 1, size: 10, text: "old one")
        try await db.upsertSessionToolIO(sessionID: "old1", source: "codex", mtime: 1, size: 10, refTS: oldTS, text: String(repeating: "x", count: 5_000))
        try await db.commit()

        let service = SearchIngestService(db: db)
        _ = try await service.ingest(
            source: .codex,
            files: [],
            toolIOEnabled: false,
            toolIOOldBytesCap: 1
        )

        let idsAfter = try await db.toolIOSessionIDs(sources: ["codex"])
        XCTAssertTrue(idsAfter.contains("old1"), "prune must not run at all when tool-IO indexing is disabled")
    }

    // MARK: - SearchIngestService: toolIO-window skip gate (old cohort)

    /// The skip-gate must not demand a `session_tool_io` row from a file whose refTS
    /// falls outside `toolIOIndexRecentDays` — the ingest loop itself (`ingestFile`)
    /// deliberately never writes a tool-IO row for such a file (see the `refTS >=
    /// toolIOCutoffTS` guard around the `toolIOText` computation), so requiring one at
    /// the gate makes an old-cohort file permanently un-skippable: every ingest kick
    /// re-parses it forever. This pins the fix.
    func testOldCohortSkipsWithoutToolIORow() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let oldDays = FeatureFlags.toolIOIndexRecentDays + 5
        let oldDate = Date().addingTimeInterval(-Double(oldDays) * 24 * 60 * 60)
        let iso = ISO8601DateFormatter.init()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoTimestamp = iso.string(from: oldDate)

        let url = try makeCodexFixture(named: "old-cohort.jsonl", userText: "ancient content narwhalpewter", assistantText: "ack narwhalpewter", in: ingestTempDir, isoTimestamp: isoTimestamp)
        let service = SearchIngestService(db: db)
        let ref = try fileRef(for: url)

        // First ingest: toolIOEnabled true, but the session's refTS is outside the
        // recent window, so `ingestFile` must produce a search row and deliberately
        // NO tool-IO row.
        let first = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: true, quietSeconds: 0)
        XCTAssertEqual(first.processed, 1)

        let hasSearchRow = try await db.hasSearchData(sources: ["codex"])
        XCTAssertTrue(hasSearchRow, "sanity: old-cohort file must still get a search row")

        let toolIOReady = try await db.fetchToolIOReadyPaths(for: "codex")
        XCTAssertFalse(toolIOReady.contains(url.path), "sanity: old-cohort file must NOT receive a tool-IO row (outside the recency window)")

        // Second ingest, identical file: must be skipped, not re-ingested forever
        // waiting for a tool-IO row that will never come.
        let second = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: true, quietSeconds: 0)
        XCTAssertEqual(second.skipped, 1, "old-cohort file (outside the toolIO window) must be skipped even though it has no session_tool_io row")
        XCTAssertEqual(second.processed, 0)
    }

    /// Inverse pin: a file INSIDE the toolIO window that legitimately has no toolIO row
    /// yet (e.g. the toolIO preference was off during its first ingest, then later
    /// turned on) must still re-ingest exactly once to backfill that row. The new
    /// "outside window" exemption must not accidentally swallow this case.
    func testRecentFileWithoutToolIORowReingestsToGainIt() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoTimestamp = iso.string(from: Date())

        let url = try makeCodexFixture(named: "recent-no-toolio.jsonl", userText: "fresh content ospreyvelvet", assistantText: "ack ospreyvelvet", in: ingestTempDir, isoTimestamp: isoTimestamp)
        let service = SearchIngestService(db: db)
        let ref = try fileRef(for: url)

        // First ingest with toolIO disabled: search row only, no tool-IO row, even
        // though this file's refTS is well within the recent window.
        let first = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: false, quietSeconds: 0)
        XCTAssertEqual(first.processed, 1)

        let toolIOReadyBefore = try await db.fetchToolIOReadyPaths(for: "codex")
        XCTAssertFalse(toolIOReadyBefore.contains(url.path), "sanity: no tool-IO row yet (toolIO was disabled on first ingest)")

        // Second ingest, same unchanged file, toolIO now enabled: must re-ingest (not
        // skip) so the file gains its tool-IO row.
        let second = try await service.ingest(source: .codex, files: [ref], toolIOEnabled: true, quietSeconds: 0)
        XCTAssertEqual(second.processed, 1, "recent file missing its tool-IO row must re-ingest to gain it, not be skipped")
        XCTAssertEqual(second.skipped, 0)

        let toolIOReadyAfter = try await db.fetchToolIOReadyPaths(for: "codex")
        XCTAssertTrue(toolIOReadyAfter.contains(url.path), "file must now have a tool-IO row")
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
