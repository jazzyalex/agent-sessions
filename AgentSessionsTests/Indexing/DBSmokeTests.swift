import XCTest
@testable import AgentSessions

final class DBSmokeTests: XCTestCase {
    func testOpenAndSchema() async throws {
        let db = try IndexDB()
        // If sqlite is writable, exec on SELECT 1 should succeed
        try await db.exec("SELECT 1;")
        // Ensure core tables exist by attempting trivial statements
        try await db.exec("SELECT name FROM sqlite_master WHERE name='files';")
        try await db.exec("SELECT name FROM sqlite_master WHERE name='session_days';")
        try await db.exec("SELECT name FROM sqlite_master WHERE name='rollups_daily';")
        try await db.exec("SELECT name FROM sqlite_master WHERE name='session_tool_io';")
    }

#if DEBUG
    func testIndexDBThrowsOpenFailedWhenApplicationSupportUnavailable() {
        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        defer { IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider }
        IndexDBTestHooks.applicationSupportDirectoryProvider = { nil }

        do {
            _ = try IndexDB()
            XCTFail("Expected IndexDB init to throw when Application Support is unavailable")
        } catch let IndexDB.DBError.openFailed(message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("application support"),
                "Expected openFailed message to mention Application Support, got: \(message)"
            )
        } catch {
            XCTFail("Expected DBError.openFailed, got: \(error)")
        }
    }

    func testSessionArchiveManagerFailsSoftWhenApplicationSupportUnavailable() {
        let originalProvider = SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider
        defer { SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = originalProvider }
        SessionArchiveManagerTestHooks.applicationSupportDirectoryProvider = { nil }

        let manager = SessionArchiveManager.shared
        let folder = manager.archiveFolderURL(source: .codex, id: "launch-resilience-test")
        XCTAssertNil(folder, "archiveFolderURL(source:id:) should fail soft and return nil")

        let root = manager.archivesRootURL()
        let expectedSuffix = "Library/Application Support/AgentSessions/Archives"
        XCTAssertTrue(
            root.path.hasSuffix(expectedSuffix),
            "archivesRootURL() should stay scoped under \(expectedSuffix), got: \(root.path)"
        )
        XCTAssertNotEqual(
            root.path,
            FileManager.default.homeDirectoryForCurrentUser.path,
            "archivesRootURL() should not collapse to the home root"
        )
    }

    /// An `IndexDB` built with no provider must never reach the developer's real index.
    ///
    /// The test bundle is hosted by `AgentSessions.app`, so the app's startup constructs an
    /// `IndexDB` before any test installs a provider — and `testOpenAndSchema` above does the
    /// same deliberately. Both used to open `~/Library/Application Support/AgentSessions/`
    /// and run `bootstrap` against it, so whatever migrations the current branch carried
    /// executed on live data.
    ///
    /// Asserted the failing way round: the real file's modification date must be untouched
    /// across an unprovided open. A guard that cannot fail is not a guard, so this also
    /// pins the detector itself — if `isRunningTests` ever stops being true under XCTest,
    /// the redirect is silently inert and the first assertion says so.
    func testUnprovidedIndexDBStaysOutOfTheRealApplicationSupport() throws {
        XCTAssertTrue(IndexDBTestHooks.isRunningTests,
                      "XCTestConfigurationFilePath is unset, so the host-app redirect is inert")

        let fm = FileManager.default
        let realDB = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentSessions/index.db", isDirectory: false)
        let modifiedDate: () -> Date? = {
            (try? realDB.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let before = modifiedDate()

        let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
        defer { IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider }
        IndexDBTestHooks.applicationSupportDirectoryProvider = nil
        _ = try IndexDB()

        let sandboxed = IndexDBTestHooks.hostSandboxDirectory
            .appendingPathComponent("AgentSessions/index.db", isDirectory: false)
        XCTAssertTrue(fm.fileExists(atPath: sandboxed.path),
                      "an unprovided IndexDB should have been created under the host sandbox")
        XCTAssertEqual(modifiedDate(), before,
                       "an unprovided IndexDB wrote to the real index at \(realDB.path)")
    }
#endif
}
