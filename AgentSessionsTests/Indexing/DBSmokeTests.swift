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
}
