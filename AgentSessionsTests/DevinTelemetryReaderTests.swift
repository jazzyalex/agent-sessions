import XCTest
import SQLite3
@testable import AgentSessions

final class DevinTelemetryReaderTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("sessions.db")
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
        try createDatabase(model: "devin-model", agentMode: "bypass", lastActivity: 200)
    }

    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "DevinTelemetryReaderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func createDatabase(model: String, agentMode: String, lastActivity: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "DevinTelemetryReaderTests", code: 2)
        }
        defer { sqlite3_close(db) }
        try execute(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, working_directory TEXT NOT NULL, backend_type TEXT NOT NULL,
              model TEXT NOT NULL, agent_mode TEXT NOT NULL, created_at INTEGER NOT NULL,
              last_activity_at INTEGER NOT NULL, title TEXT, main_chain_id INTEGER,
              hidden INTEGER NOT NULL DEFAULT 0);
            """)
        let escapedModel = model.replacingOccurrences(of: "'", with: "''")
        let escapedMode = agentMode.replacingOccurrences(of: "'", with: "''")
        try execute(db, """
            INSERT INTO sessions
              (id, working_directory, backend_type, model, agent_mode, created_at,
               last_activity_at, title, main_chain_id, hidden)
            VALUES ('devin-session', '/tmp/project', 'Windsurf', '\(escapedModel)',
                    '\(escapedMode)', 100, \(lastActivity), 'Telemetry', NULL, 0);
            """)
    }

    private func makeSession(model: String? = "stale-model") -> Session {
        Session(id: "devin-session",
                source: .devin,
                startTime: nil,
                endTime: nil,
                model: model,
                filePath: databaseURL.path,
                eventCount: 0,
                events: [])
    }

    func testReaderUsesSharedSessionModelWithUnanchoredProvenance() throws {
        let session = makeSession()
        let scan = try XCTUnwrap(DevinTelemetryReader.loadTelemetry(for: session))
        XCTAssertGreaterThan(scan.bytesScanned, 0)
        XCTAssertEqual(scan.inputRevision, DevinTelemetryReader.telemetryRevision(for: session))

        let telemetry = scan.result.telemetry
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "devin-model")
        XCTAssertEqual(telemetry.currentConfiguration?.provenance, .sessionMetadata)
        XCTAssertNil(telemetry.currentConfiguration?.observedAt)
        XCTAssertNil(telemetry.currentConfiguration?.anchorLine)
        XCTAssertNil(telemetry.currentConfiguration?.modelObservedAt)
        XCTAssertNil(telemetry.currentConfiguration?.modelAnchorLine)
        XCTAssertTrue(telemetry.configurationChanges.isEmpty)
        XCTAssertNil(telemetry.usageSummary)
        XCTAssertNil(telemetry.costEstimate)
    }

    func testEngineDispatchesDevinReaderThroughRegistry() async throws {
        let engine = SessionTelemetryEngine(metrics: SessionInfoMetrics())
        let result = await engine.telemetry(for: makeSession())
        let telemetry = try XCTUnwrap(result)

        XCTAssertEqual(telemetry.source, .devin)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "devin-model")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertNil(telemetry.usageSummary)
    }

    func testRevisionChangesWhenSharedSessionMetadataChanges() throws {
        let session = makeSession()
        let before = try XCTUnwrap(DevinTelemetryReader.telemetryRevision(for: session))

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "DevinTelemetryReaderTests", code: 3)
        }
        defer { sqlite3_close(db) }
        try execute(db, "UPDATE sessions SET last_activity_at = 201 WHERE id = 'devin-session';")

        let after = try XCTUnwrap(DevinTelemetryReader.telemetryRevision(for: session))
        XCTAssertNotEqual(before, after)
    }

    func testDescriptorStatesDevinTokenAndCostLimits() {
        let capabilities = SessionSourceRegistry.descriptor(for: .devin).telemetry
        XCTAssertTrue(capabilities.configuration.isAvailable)
        XCTAssertFalse(capabilities.tokens.isAvailable)
        XCTAssertFalse(capabilities.cost.isAvailable)
        XCTAssertFalse(capabilities.weeklyQuota.isAvailable)
    }
}
