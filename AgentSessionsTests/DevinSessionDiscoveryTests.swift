import XCTest
@testable import AgentSessions

final class DevinSessionDiscoveryTests: XCTestCase {
    private func makeStore(withDatabase: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-discovery-\(UUID().uuidString)", isDirectory: true)
        let cli = root.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        if withDatabase {
            try Data().write(to: cli.appendingPathComponent("sessions.db"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Devin keeps every session in one database, so discovery yields that file
    /// rather than a list of per-session paths.
    func testDiscoveryReturnsTheDatabaseItself() throws {
        let root = try makeStore(withDatabase: true)
        let discovery = DevinSessionDiscovery(customRoot: root.path)

        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.lastPathComponent, "sessions.db")
        XCTAssertTrue(discovery.hasDatabase())
    }

    func testDiscoveryIsEmptyWithoutTheDatabase() throws {
        let root = try makeStore(withDatabase: false)
        let discovery = DevinSessionDiscovery(customRoot: root.path)

        XCTAssertTrue(discovery.discoverSessionFiles().isEmpty)
        XCTAssertFalse(discovery.hasDatabase())
    }

    /// A custom root may name the data directory, its `cli/` child, or the
    /// database file; all three resolve to the same database.
    func testCustomRootAcceptsDataDirCliDirOrDatabaseFile() throws {
        let root = try makeStore(withDatabase: true)
        let cli = root.appendingPathComponent("cli")
        let db = cli.appendingPathComponent("sessions.db")

        for candidate in [root.path, cli.path, db.path] {
            let discovery = DevinSessionDiscovery(customRoot: candidate)
            XCTAssertEqual(discovery.databaseURL().path, db.path, "failed for \(candidate)")
            XCTAssertTrue(discovery.hasDatabase(), "failed for \(candidate)")
        }
    }

    func testDefaultRootIsTheDevinCLIDataDirectory() {
        let discovery = DevinSessionDiscovery()
        XCTAssertTrue(discovery.databaseURL().path.hasSuffix(".local/share/devin/cli/sessions.db"),
                      discovery.databaseURL().path)
    }
}
