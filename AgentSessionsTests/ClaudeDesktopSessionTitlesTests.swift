import XCTest
@testable import AgentSessions

/// W7 Task 2b: `ClaudeDesktopSessionTitles.records(root:)` enumerates the whole
/// tree every call (there's no cheaper reliable "did anything change" probe for
/// an arbitrarily-nested directory), but caches the parsed record per file path
/// keyed by mtime — an unchanged file is served from cache instead of
/// re-reading + re-parsing its JSON. This was measured running on the main
/// thread once per HUD / transcript-archive-strip rebuild.
final class ClaudeDesktopSessionTitlesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        ClaudeDesktopSessionTitles.debugResetCache()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-desktop-titles-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeSessionDir() throws -> URL {
        let convoDir = root.appendingPathComponent("convoA/sessionB", isDirectory: true)
        try FileManager.default.createDirectory(at: convoDir, withIntermediateDirectories: true)
        return convoDir
    }

    func testCachesUnchangedFilesByMtime() throws {
        let convoDir = try makeSessionDir()
        let fileA = convoDir.appendingPathComponent("local_abc.json")
        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"First title"}
        """.write(to: fileA, atomically: true, encoding: .utf8)

        // First read: nothing cached yet, so the one file present must be parsed.
        let first = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(first["f1d39390-aaaa"]?.title, "First title")
        let afterFirst = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterFirst.parsed, 1)
        XCTAssertEqual(afterFirst.cacheHits, 0)

        // Second read against the SAME unchanged file: served from cache, no re-parse.
        let second = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(second["f1d39390-aaaa"]?.title, "First title")
        let afterSecond = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterSecond.parsed, 1, "unchanged file must not be re-parsed")
        XCTAssertEqual(afterSecond.cacheHits, 1)

        // Touch the file with a new mtime and a new title: must be re-parsed,
        // and the fresh title must win (cache never serves stale content).
        try """
        {"sessionId":"local_abc","cliSessionId":"f1d39390-aaaa","title":"Renamed title"}
        """.write(to: fileA, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: fileA.path
        )

        let third = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(third["f1d39390-aaaa"]?.title, "Renamed title")
        let afterThird = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(afterThird.parsed, 2, "a touched file must be re-parsed")
    }

    // Deletion parity: the cache is rebuilt from what the enumerator actually
    // sees, so a sidecar removed from disk must vanish from the result — never
    // be served from a stale cache entry.
    func testDeletedFileIsNotServedFromCache() throws {
        let convoDir = try makeSessionDir()
        let keep = convoDir.appendingPathComponent("local_keep.json")
        let doomed = convoDir.appendingPathComponent("local_doomed.json")
        try """
        {"sessionId":"local_keep","cliSessionId":"keep-1111","title":"Kept session"}
        """.write(to: keep, atomically: true, encoding: .utf8)
        try """
        {"sessionId":"local_doomed","cliSessionId":"doomed-2222","title":"Doomed session"}
        """.write(to: doomed, atomically: true, encoding: .utf8)

        // Warm the cache with both files present.
        let warm = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(warm["keep-1111"]?.title, "Kept session")
        XCTAssertEqual(warm["doomed-2222"]?.title, "Doomed session")

        try FileManager.default.removeItem(at: doomed)

        let afterDelete = ClaudeDesktopSessionTitles.records(root: root)
        XCTAssertEqual(afterDelete["keep-1111"]?.title, "Kept session",
                       "the surviving file must still resolve (from cache — its mtime is unchanged)")
        XCTAssertNil(afterDelete["doomed-2222"],
                     "a deleted sidecar must not be served from the cache")
    }

    // MARK: - Multi-root (Cowork overlay, 2026-07-19)

    func testRecordsMultiRootMergesNewerMtimeWins() throws {
        let rootA = root.appendingPathComponent("code-sessions", isDirectory: true)
        let rootB = root.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let older = rootA.appendingPathComponent("local_a.json")
        let newer = rootB.appendingPathComponent("local_b.json")
        try """
        {"sessionId":"local_a","cliSessionId":"shared-1111","title":"Older title"}
        """.write(to: older, atomically: true, encoding: .utf8)
        try """
        {"sessionId":"local_b","cliSessionId":"shared-1111","title":"Newer title"}
        """.write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: newer.path
        )

        let merged = ClaudeDesktopSessionTitles.records(roots: [rootA, rootB])
        XCTAssertEqual(merged["shared-1111"]?.title, "Newer title")
    }

    func testRecordsMultiRootToleratesMissingRoot() throws {
        let rootA = root.appendingPathComponent("code-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try """
        {"sessionId":"local_k","cliSessionId":"keep-3333","title":"Kept"}
        """.write(to: rootA.appendingPathComponent("local_k.json"), atomically: true, encoding: .utf8)

        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let merged = ClaudeDesktopSessionTitles.records(roots: [rootA, missing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["keep-3333"]?.title, "Kept")
    }

    func testRecordsSkipsHeavyCoworkDirectories() throws {
        // uploads/outputs/cowork_plugins/skills-plugin can hold thousands of
        // files; the walk must skipDescendants, never parse json inside them.
        let coworkRoot = root.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let sessionDir = coworkRoot.appendingPathComponent("acct/ws", isDirectory: true)
        let uploads = sessionDir.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)

        try """
        {"sessionId":"local_real","cliSessionId":"real-4444","title":"Real Cowork task"}
        """.write(to: sessionDir.appendingPathComponent("local_real.json"), atomically: true, encoding: .utf8)
        try """
        {"sessionId":"local_decoy","cliSessionId":"decoy-5555","title":"Decoy inside uploads"}
        """.write(to: uploads.appendingPathComponent("local_decoy.json"), atomically: true, encoding: .utf8)

        let records = ClaudeDesktopSessionTitles.records(roots: [coworkRoot])
        XCTAssertEqual(records["real-4444"]?.title, "Real Cowork task")
        XCTAssertNil(records["decoy-5555"], "files inside skipped directories must not be parsed")

        let counts = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(counts.parsed, 1, "the decoy must be skipped by skipDescendants, not parsed-and-discarded")
    }
}
