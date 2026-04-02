import XCTest
@testable import AgentSessions

#if DEBUG
final class CoreSessionMetaTests: XCTestCase {
    private var db: IndexDB!
    private var cleanup: (() -> Void)!

    override func setUpWithError() throws {
        let result = try makeTestIndexDB()
        db = result.db
        cleanup = result.cleanup
    }

    override func tearDown() {
        cleanup?()
        db = nil
        cleanup = nil
    }

    // MARK: - upsertSessionMetaCore preserves analytics fields

    func testCoreUpsertPreservesCustomTitle() async throws {
        // Analytics writes a row with custom_title set
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: "gpt-4", cwd: "/home", repo: "repo",
            title: "Session A", codexInternalSessionID: nil,
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: "My Custom Name"
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer writes the same session with nil custom_title
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: "gpt-4", cwd: "/home", repo: "repo",
            title: "Session A updated", codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.customTitle, "My Custom Name", "custom_title should be preserved by core upsert when new value is nil")
    }

    func testCoreUpsertUpdatesCustomTitleWhenNonNil() async throws {
        // Analytics writes a row with no custom title
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer writes with a custom title from /rename parsing
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: "Renamed Session"
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].customTitle, "Renamed Session", "non-nil custom_title should update DB via COALESCE")
    }

    func testCoreUpsertUpdatesCustomTitleOverExisting() async throws {
        // Analytics writes a row with an old custom title
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: "Old Name"
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer writes with a new custom title (user renamed again)
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: "New Name"
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].customTitle, "New Name", "non-nil custom_title should overwrite existing via COALESCE")
    }

    func testCoreUpsertCodexInternalIDCoalesce() async throws {
        // Analytics writes with a backfilled codex internal session ID
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: "backfill-abc",
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer writes with nil hint (lightweight parse didn't find it)
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].codexInternalSessionID, "backfill-abc", "nil codex_internal_session_id should preserve existing")

        // Core write with a DIFFERENT non-nil hint must NOT overwrite the authoritative value
        let coreRow2 = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 120, size: 220, startTS: 10, endTS: 30,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: "new-hint",
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow2)

        let rows2 = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows2[0].codexInternalSessionID, "backfill-abc", "core upsert must not overwrite existing codex_internal_session_id")
    }

    func testCoreUpsertFillsCodexInternalIDWhenNull() async throws {
        // Row exists with no codex_internal_session_id
        let initial = SessionMetaRow(
            sessionID: "s2", source: "codex", path: "/b.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 0, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(initial)

        // Core write fills the missing ID
        let withHint = SessionMetaRow(
            sessionID: "s2", source: "codex", path: "/b.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: "discovered-id",
            isHousekeeping: false, messages: 0, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(withHint)

        let rows = try await db.fetchSessionMeta(for: "codex")
        let row = rows.first { $0.sessionID == "s2" }
        XCTAssertEqual(row?.codexInternalSessionID, "discovered-id", "core upsert should fill NULL codex_internal_session_id")
    }

    func testCoreUpsertPreservesMessages() async throws {
        // Analytics writes with accurate message count
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer writes with lightweight (lower) message count
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/a.jsonl",
            mtime: 110, size: 210, startTS: 10, endTS: 25,
            model: nil, cwd: nil, repo: nil,
            title: nil, codexInternalSessionID: nil,
            isHousekeeping: false, messages: 10, commands: 0,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].messages, 42, "messages should be preserved by core upsert")
        XCTAssertEqual(rows[0].commands, 5, "commands should be preserved by core upsert")
    }

    func testCoreUpsertUpdatesLocationalFields() async throws {
        // Analytics writes initial row
        let analyticsRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/old.jsonl",
            mtime: 100, size: 200, startTS: 10, endTS: 20,
            model: "gpt-4", cwd: "/old", repo: "old-repo",
            title: "Old Title", codexInternalSessionID: "backfill-id-123",
            isHousekeeping: false, messages: 42, commands: 5,
            parentSessionID: nil, subagentType: nil,
            customTitle: "My Name"
        )
        try await db.upsertSessionMeta(analyticsRow)

        // Core indexer updates with new locational data but nil codexInternalSessionID
        let coreRow = SessionMetaRow(
            sessionID: "s1", source: "codex", path: "/new.jsonl",
            mtime: 200, size: 400, startTS: 10, endTS: 30,
            model: "gpt-4o", cwd: "/new", repo: "new-repo",
            title: "New Title", codexInternalSessionID: nil,
            isHousekeeping: true, messages: 10, commands: 0,
            parentSessionID: "p1", subagentType: "task",
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "codex")
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        // Locational fields updated
        XCTAssertEqual(row.path, "/new.jsonl")
        XCTAssertEqual(row.mtime, 200)
        XCTAssertEqual(row.size, 400)
        XCTAssertEqual(row.endTS, 30)
        XCTAssertEqual(row.model, "gpt-4o")
        XCTAssertEqual(row.cwd, "/new")
        XCTAssertEqual(row.repo, "new-repo")
        XCTAssertEqual(row.title, "New Title")
        XCTAssertTrue(row.isHousekeeping)
        XCTAssertEqual(row.parentSessionID, "p1")
        XCTAssertEqual(row.subagentType, "task")
        // Preserved fields
        XCTAssertEqual(row.codexInternalSessionID, "backfill-id-123", "codex_internal_session_id preserved")
        XCTAssertEqual(row.messages, 42, "messages preserved")
        XCTAssertEqual(row.commands, 5, "commands preserved")
        XCTAssertEqual(row.customTitle, "My Name", "custom_title preserved")
    }

    func testCoreUpsertInsertsNewRowWhenNoneExists() async throws {
        let coreRow = SessionMetaRow(
            sessionID: "new1", source: "claude", path: "/new.jsonl",
            mtime: 100, size: 50, startTS: 10, endTS: 20,
            model: "claude-4", cwd: "/home", repo: nil,
            title: "Fresh Session", codexInternalSessionID: nil,
            isHousekeeping: false, messages: 3, commands: 1,
            parentSessionID: nil, subagentType: nil,
            customTitle: nil
        )
        try await db.upsertSessionMetaCore(coreRow)

        let rows = try await db.fetchSessionMeta(for: "claude")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sessionID, "new1")
        XCTAssertEqual(rows[0].title, "Fresh Session")
        // For fresh inserts, messages/commands come from the core row
        XCTAssertEqual(rows[0].messages, 3)
        XCTAssertEqual(rows[0].commands, 1)
    }

    // MARK: - sessionMetaRow conversion

    func testSessionMetaRowFromSession() {
        let session = Session(
            id: "test-id",
            source: .codex,
            startTime: Date(timeIntervalSince1970: 1000),
            endTime: Date(timeIntervalSince1970: 2000),
            model: "gpt-4",
            filePath: "/sessions/test.jsonl",
            fileSizeBytes: 1234,
            eventCount: 10,
            events: [],
            cwd: "/home/user",
            repoName: "my-repo",
            lightweightTitle: "Test Session",
            lightweightCommands: 5,
            isHousekeeping: false,
            parentSessionID: "parent-1",
            subagentType: "task",
            customTitle: "Custom"
        )

        let row = SessionIndexer.sessionMetaRow(from: session)

        XCTAssertEqual(row.sessionID, "test-id")
        XCTAssertEqual(row.source, "codex")
        XCTAssertEqual(row.path, "/sessions/test.jsonl")
        XCTAssertEqual(row.size, 1234)
        XCTAssertEqual(row.startTS, 1000)
        XCTAssertEqual(row.endTS, 2000)
        XCTAssertEqual(row.model, "gpt-4")
        XCTAssertEqual(row.cwd, "/home/user")
        XCTAssertEqual(row.repo, "my-repo")
        XCTAssertEqual(row.title, "Test Session")
        XCTAssertEqual(row.messages, 10)
        XCTAssertEqual(row.commands, 5)
        XCTAssertFalse(row.isHousekeeping)
        XCTAssertEqual(row.parentSessionID, "parent-1")
        XCTAssertEqual(row.subagentType, "task")
        XCTAssertEqual(row.customTitle, "Custom")
    }

    func testSessionMetaRowDefaultsCommandsToZero() {
        let session = Session(
            id: "test-nil-cmds",
            source: .claude,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: "/test.jsonl",
            fileSizeBytes: nil,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: nil,
            isHousekeeping: false
        )

        let row = SessionIndexer.sessionMetaRow(from: session)
        XCTAssertEqual(row.commands, 0, "nil lightweightCommands should map to 0")
        XCTAssertEqual(row.size, 0, "nil fileSizeBytes should map to 0")
    }
}

// MARK: - Gap detection (set-difference logic)

final class HydrationGapDetectionTests: XCTestCase {
    func testGapDetectsFilesNotInHydratedSet() {
        let diskPaths: Set<String> = ["/a.jsonl", "/b.jsonl", "/c.jsonl"]
        let hydratedPaths: Set<String> = ["/a.jsonl"]
        let changedPaths: Set<String> = ["/b.jsonl"]

        let gap = diskPaths.subtracting(hydratedPaths).subtracting(changedPaths)

        XCTAssertEqual(gap, ["/c.jsonl"])
    }

    func testNoGapWhenHydrationIsComplete() {
        let diskPaths: Set<String> = ["/a.jsonl", "/b.jsonl"]
        let hydratedPaths: Set<String> = ["/a.jsonl", "/b.jsonl"]
        let changedPaths: Set<String> = []

        let gap = diskPaths.subtracting(hydratedPaths).subtracting(changedPaths)

        XCTAssertTrue(gap.isEmpty)
    }

    func testNoGapWhenAllMissingAreAlreadyChanged() {
        let diskPaths: Set<String> = ["/a.jsonl", "/b.jsonl", "/c.jsonl"]
        let hydratedPaths: Set<String> = ["/a.jsonl"]
        let changedPaths: Set<String> = ["/b.jsonl", "/c.jsonl"]

        let gap = diskPaths.subtracting(hydratedPaths).subtracting(changedPaths)

        XCTAssertTrue(gap.isEmpty)
    }

    func testGapWithEqualCountButDifferentSets() {
        // Both sets have 2 elements but only 1 overlaps — count comparison would miss this
        let diskPaths: Set<String> = ["/a.jsonl", "/b.jsonl"]
        let hydratedPaths: Set<String> = ["/a.jsonl", "/x.jsonl"]
        let changedPaths: Set<String> = []

        let gap = diskPaths.subtracting(hydratedPaths).subtracting(changedPaths)

        XCTAssertEqual(gap, ["/b.jsonl"], "Set-difference catches gap even when counts are equal")
    }

    func testEmptyDiskProducesEmptyGap() {
        let diskPaths: Set<String> = []
        let hydratedPaths: Set<String> = ["/a.jsonl"]
        let changedPaths: Set<String> = []

        let gap = diskPaths.subtracting(hydratedPaths).subtracting(changedPaths)

        XCTAssertTrue(gap.isEmpty)
    }

    /// Validates that the existing Codex helper function still works correctly
    /// (kept as a tested utility even though the main path uses inline set-difference).
    func testCodexHelperStillMatchesSetDifference() {
        let pathA = "/a.jsonl"
        let pathB = "/b.jsonl"
        let pathC = "/c.jsonl"

        let currentByPath: [String: SessionFileStat] = [
            pathA: SessionFileStat(mtime: 100, size: 10),
            pathB: SessionFileStat(mtime: 100, size: 10),
            pathC: SessionFileStat(mtime: 100, size: 10)
        ]
        let existingPaths = Set([pathA])
        let changed = [URL(fileURLWithPath: pathB)]

        let helperResult = Set(SessionIndexer.additionalChangedFilesForMissingHydratedSessions(
            currentByPath: currentByPath,
            existingSessionPaths: existingPaths,
            changedFiles: changed
        ).map(\.path))

        // Set-difference equivalent
        let diskPaths = Set(currentByPath.keys)
        let changedPaths = Set(changed.map(\.path))
        let setDiffResult = diskPaths.subtracting(existingPaths).subtracting(changedPaths)

        XCTAssertEqual(helperResult, setDiffResult, "Helper and set-difference should produce identical results")
    }
}
#endif
