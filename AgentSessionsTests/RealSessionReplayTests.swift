import XCTest
import SQLite3
import Darwin
@testable import AgentSessions

/// Opt-in, read-only replay through production discovery, parsers and telemetry.
/// No indexer, archive manager, auth client or live rate sampler is constructed.
final class RealSessionReplayTests: XCTestCase {
    private struct Counts: Codable {
        var sessions_read = 0
        var parse_failed = 0
        var zero_events = 0
        var usage_complete = 0
        var usage_unavailable = 0
        var unavailable_reasons: [String: Int] = [:]
        var failure_values: [String: Int] = [:]
    }

    func testRealSessionReplay() async throws {
        guard ProcessInfo.processInfo.environment["AS_REAL_SESSION_REPLAY"] == "1" else {
            throw XCTSkip("Set AS_REAL_SESSION_REPLAY=1 for read-only local replay")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("scripts/probe_scan_output/replay")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Independent process: even a blocked synchronous parser cannot prevent
        // the 180-second watchdog from terminating this test host. EOF disarms it.
        let watchdog = Process()
        let completion = Pipe()
        watchdog.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        watchdog.arguments = [root.appendingPathComponent("scripts/replay_watchdog.py").path, "--seconds", "180"]
        watchdog.standardInput = completion
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()
        defer {
            try? completion.fileHandleForWriting.close()
            watchdog.waitUntilExit()
        }
        let quota = WeeklyQuotaCalibrationStore.makeForTesting()
        let engine = SessionTelemetryEngine(priceTable: .makeForTesting(), quotaStore: quota)
        var report: [String: Counts] = [:]
        func saveCounts() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("counts.json"), options: .atomic)
        }
        try saveCounts()
        let deadline = Date().addingTimeInterval(180)
        // Production DEBUG parsers print paths. Suppress those while replaying;
        // only the counts file is a replay artifact.
        fflush(nil)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        let sink = open("/dev/null", O_WRONLY)
        guard savedOut >= 0, savedErr >= 0, sink >= 0 else { throw XCTSkip("Cannot isolate replay output") }
        dup2(sink, STDOUT_FILENO)
        dup2(sink, STDERR_FILENO)
        defer {
            fflush(nil)
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedErr, STDERR_FILENO)
            close(savedOut)
            close(savedErr)
            close(sink)
        }
        // Core agents first. Further sources can be added once their discovery seam
        // reaches the full parser without creating an index or starting a monitor.
        for (source, discovery) in [(SessionSource.codex, CodexSessionDiscovery() as any SessionDiscovery),
                                    (.claude, ClaudeSessionDiscovery() as any SessionDiscovery)] {
            var counts = Counts()
            let files = discovery.discoverSessionFiles().sorted {
                (SessionFileStat.from($0)?.mtime ?? 0) > (SessionFileStat.from($1)?.mtime ?? 0)
            }.prefix(20)
            let descriptor = SessionSourceRegistry.descriptor(for: source)
            for file in files {
                if Date() > deadline { break }
                counts.sessions_read += 1
                guard let session = descriptor.parseFullByPath?(file) else {
                    counts.parse_failed += 1
                    continue
                }
                if session.events.isEmpty { counts.zero_events += 1 }
                let result = await engine.telemetryReadResult(for: session)
                Self.recordUsage(result.telemetry, nilReason: result.unavailableReason, into: &counts)
                report[source.rawValue] = counts
                try saveCounts()
            }
            report[source.rawValue] = counts
        }
        var counts = Counts()
        let discovery = OpenCodeSessionDiscovery()
        if let database = discovery.databaseURL() {
            let sessions = OpenCodeSqliteReader.listSessions(customRoot: database.path).prefix(20)
            for light in sessions {
                if Date() > deadline { break }
                counts.sessions_read += 1
                guard let session = OpenCodeSqliteReader.loadFullSession(customRoot: database.path, sessionID: light.id) else {
                    counts.parse_failed += 1
                    continue
                }
                if session.events.isEmpty { counts.zero_events += 1 }
                let result = await engine.telemetryReadResult(for: session)
                Self.recordOpenCodeUsage(result.telemetry, nilReason: result.unavailableReason,
                                         database: database, sessionID: light.id, into: &counts)
                report["opencode"] = counts
                try saveCounts()
            }
        }
        report["opencode"] = counts
        try saveCounts()
        // The file is evidence even on a failed run. Unavailability is triaged by
        // reason, not treated as a generic test failure or silently called complete.
        XCTAssertEqual(report.values.reduce(0) { $0 + $1.parse_failed }, 0)
        XCTAssertTrue(report.values.allSatisfy { $0.sessions_read > 0 })
    }

    private static func recordOpenCodeUsage(_ telemetry: SessionTelemetry?,
                                           nilReason: SessionTelemetryEngine.UnavailableReason? = nil, database: URL,
                                           sessionID: String, into counts: inout Counts) {
        recordUsage(telemetry, nilReason: nilReason, into: &counts)
        // A successful session may also contain a refusal or an aborted row.
        // Session-level totals must not hide those discriminator values.
        for (key, count) in failureHistogram(database: database, sessionID: sessionID) {
            counts.failure_values[key, default: 0] += count
        }
    }

    @discardableResult
    private static func recordUsage(_ telemetry: SessionTelemetry?,
                                    nilReason: SessionTelemetryEngine.UnavailableReason? = nil,
                                    into counts: inout Counts) -> Bool {
        guard let telemetry else {
            counts.usage_unavailable += 1
            let category = nilReason.map { "telemetry_" + $0.rawValue } ?? "telemetry_not_available"
            counts.unavailable_reasons[category, default: 0] += 1
            return true
        }
        if let reason = telemetry.usageSummary?.unavailableReason {
            counts.usage_unavailable += 1
            // Only controlled reason categories escape. Never serialize free text.
            let category: String
            if reason.contains("malformed") { category = "malformed_usage" }
            else if reason.contains("fork") { category = "fork_attribution" }
            else if reason.contains("no usable") { category = "no_usable_usage" }
            else if reason.contains("range") { category = "token_range" }
            else { category = "other_unavailable" }
            counts.unavailable_reasons[category, default: 0] += 1
            return true
        } else if telemetry.usageSummary == nil {
            counts.usage_unavailable += 1
            counts.unavailable_reasons["usage_not_emitted", default: 0] += 1
            return true
        } else {
            counts.usage_complete += 1
            return false
        }
    }

    private static func failureHistogram(database: URL, sessionID: String) -> [String: Int] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return ["histogram_read_failed": 1]
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT type, data FROM session_message WHERE session_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ["v2_store_absent": 1] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var histogram: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typePtr = sqlite3_column_text(statement, 0), let dataPtr = sqlite3_column_text(statement, 1),
                  let data = String(cString: dataPtr).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                histogram["malformed_row", default: 0] += 1
                continue
            }
            let error = object["error"] as? [String: Any]
            guard error != nil || object["finish"] != nil else { continue }
            func discriminator(_ raw: String?) -> String {
                guard let raw, !raw.isEmpty else { return "absent" }
                // Schema discriminators only. Arbitrary messages/IDs are withheld.
                guard raw.count <= 64, raw.range(of: "^[a-z][a-z0-9_.-]*$", options: .regularExpression) != nil else {
                    return "non_discriminator_value"
                }
                return raw
            }
            let key = [discriminator(String(cString: typePtr)), discriminator(object["finish"] as? String),
                       discriminator(error?["type"] as? String)].joined(separator: "/")
            histogram[key, default: 0] += 1
        }
        return histogram
    }

    func testNilTelemetryReasonIsRetainedAsCountsOnly() throws {
        var counts = Counts()
        Self.recordUsage(nil, nilReason: .revisionChanged, into: &counts)
        Self.recordUsage(nil, nilReason: .scanWaitCancelled, into: &counts)
        XCTAssertEqual(counts.usage_unavailable, 2)
        XCTAssertEqual(counts.unavailable_reasons, [
            "telemetry_revision_changed_retry_exhausted": 1,
            "telemetry_scan_wait_cancelled": 1
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(counts)) as? [String: Any])
        let reasons = try XCTUnwrap(object["unavailable_reasons"] as? [String: Int])
        XCTAssertEqual(reasons, counts.unavailable_reasons)
    }

    func testMixedSessionKeepsFailuresWithCompleteAndUnavailableUsage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("fixture.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE session_message(session_id TEXT, type TEXT, data TEXT);
        INSERT INTO session_message VALUES ('fixture', 'assistant', '{"finish":"stop","usage":{"inputTokens":7,"outputTokens":3}}');
        INSERT INTO session_message VALUES ('fixture', 'assistant', '{"finish":"error","error":{"type":"provider.new-limit"}}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let telemetry = SessionTelemetry(source: .opencode, initialConfiguration: nil,
            currentConfiguration: nil, configurationChanges: [], usageSlices: [],
            usageSummary: .init(topLineTokens: 10, hasComponentBreakdown: true,
                recordedTotalTokens: 10, usageFamilies: ["message.tokens"], usageFamilyConflict: false),
            costEstimate: nil)
        var complete = Counts()
        Self.recordOpenCodeUsage(telemetry, database: database, sessionID: "fixture", into: &complete)
        XCTAssertEqual(complete.usage_complete, 1)
        XCTAssertEqual(complete.usage_unavailable, 0)
        XCTAssertEqual(complete.failure_values["assistant/error/provider.new-limit"], 1)
        var unavailable = Counts()
        Self.recordOpenCodeUsage(nil, database: database, sessionID: "fixture", into: &unavailable)
        XCTAssertEqual(unavailable.usage_unavailable, 1)
        XCTAssertEqual(unavailable.failure_values, complete.failure_values)
        XCTAssertFalse(complete.failure_values.keys.contains { $0.contains("fixture") })
    }

    func testFixtureHistogramKeepsUnknownFailureValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("fixture.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE session_message(session_id TEXT, type TEXT, data TEXT);
        INSERT INTO session_message VALUES ('fixture', 'assistant', '{"finish":"unknown-new-finish","error":{"type":"provider.new-limit"}}');
        INSERT INTO session_message VALUES ('fixture', 'user', '{"text":"PRIVATE TEXT"}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let histogram = Self.failureHistogram(database: database, sessionID: "fixture")
        XCTAssertEqual(histogram, ["assistant/unknown-new-finish/provider.new-limit": 1])
    }
}
