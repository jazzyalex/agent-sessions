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
#endif
}
