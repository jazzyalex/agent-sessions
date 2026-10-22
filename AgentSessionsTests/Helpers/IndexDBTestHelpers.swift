import Foundation
@testable import AgentSessions

#if DEBUG
/// Creates a temporary IndexDB that writes to a unique temp directory.
/// Returns both the db and a cleanup closure. Call cleanup in tearDown/defer.
func makeTestIndexDB() throws -> (db: IndexDB, cleanup: () -> Void) {
    let made = try makeTestIndexDBWithDirectory()
    return (made.db, made.cleanup)
}

/// Same as `makeTestIndexDB()`, plus the directory, for tests about cleanup itself.
///
/// Cleanup is usually called from a `defer` while the test still holds the db, so it
/// removes the folder only once the database has closed
/// (`IndexDBTestHooks.removeWhenDatabasesClose`).
func makeTestIndexDBWithDirectory() throws -> (db: IndexDB, cleanup: () -> Void, directory: URL) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
    IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
    defer { IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider }
    let db = try IndexDB()

    return (db, { IndexDBTestHooks.removeWhenDatabasesClose(tmpDir) }, tmpDir)
}

/// Removes a test folder after closing the OpenClaw store handles cached under it.
/// The reader keeps one read-only handle per store for revision checks; deleting the
/// store first makes SQLite log "vnode unlinked while in use".
func removeTestRoot(_ root: URL) {
    OpenClawSqliteReader.closeRevisionHandlesForTesting(under: root)
    try? FileManager.default.removeItem(at: root)
}

/// Takes an OpenClaw store away from its path mid-test without deleting a file the
/// reader still holds open: the old file is renamed beside it, so the path is empty
/// (or ready for a replacement) and the reader's handle still points at the old store.
/// `removeTestRoot` deletes it once the handles are closed.
func moveStoreAside(_ database: URL) throws {
    let aside = database.deletingLastPathComponent()
        .appendingPathComponent(".replaced-\(UUID().uuidString)-\(database.lastPathComponent)")
    try FileManager.default.moveItem(at: database, to: aside)
}
#endif
