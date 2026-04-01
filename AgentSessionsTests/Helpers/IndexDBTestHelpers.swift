import Foundation
@testable import AgentSessions

#if DEBUG
/// Creates a temporary IndexDB that writes to a unique temp directory.
/// Returns both the db and a cleanup closure. Call cleanup in tearDown/defer.
func makeTestIndexDB() throws -> (db: IndexDB, cleanup: () -> Void) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
    IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
    let db = try IndexDB()
    IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

    let cleanup: () -> Void = {
        try? FileManager.default.removeItem(at: tmpDir)
    }
    return (db, cleanup)
}
#endif
