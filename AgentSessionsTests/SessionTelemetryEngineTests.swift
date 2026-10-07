import XCTest
import SQLite3
@testable import AgentSessions

private final class OneShotAction: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var didRun = false

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func run() {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        action()
    }
}

private final class ArmableOneShotAction: @unchecked Sendable {
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var armed = false
    private var didRun = false

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func run() {
        lock.lock()
        guard armed, !didRun else {
            lock.unlock()
            return
        }
        didRun = true
        lock.unlock()
        action()
    }
}

private final class TaskCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (@Sendable () -> Void)?

    func install<T>(_ task: Task<T, Never>) {
        lock.lock()
        cancelAction = { task.cancel() }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let action = cancelAction
        lock.unlock()
        action?()
    }
}

private final class BlockingAction: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    private var shouldBlock = true

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func run() {
        lock.lock()
        entered = true
        let shouldBlock = self.shouldBlock
        lock.unlock()
        if shouldBlock {
            gate.wait()
        }
    }

    func release() {
        lock.lock()
        shouldBlock = false
        lock.unlock()
        gate.signal()
    }
}

private final class AppendOnEveryCall: @unchecked Sendable {
    private let url: URL
    private let data: Data

    init(url: URL, line: String) {
        self.url = url
        data = Data("\n\(line)".utf8)
    }

    func run() {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

private final class SQLiteWALWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    init(url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK else {
            sqlite3_close(opened)
            throw NSError(domain: "OpenCodeTelemetryFixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "failed to open WAL writer"])
        }
        db = opened
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenCodeTelemetryFixture", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// The engine re-reads transcripts on demand and caches by file signature. The
/// cache key must include SIZE as well as mtime — the repo already has a runway
/// test pinning that lesson, because an append inside the same mtime second is a
/// real and silent staleness source.
final class SessionTelemetryEngineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telemetry-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func write(_ lines: [String], name: String = "session.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session(_ url: URL, source: SessionSource, id: String = "s1",
                         model: String? = nil) -> Session {
        Session(id: id, source: source, startTime: nil, endTime: nil, model: model,
                filePath: url.path, eventCount: 0, events: [])
    }

    private func createOpenCodeTelemetryFixture(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return XCTFail("failed to open OpenCode telemetry fixture")
        }
        defer { sqlite3_close(db) }

        func execute(_ sql: String) throws {
            var error: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
                sqlite3_free(error)
                throw NSError(domain: "OpenCodeTelemetryFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try execute("""
        CREATE TABLE session (
            id TEXT PRIMARY KEY,
            time_updated INTEGER NOT NULL
        );
        CREATE TABLE message (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO session (id, time_updated) VALUES ('session-a', 1000);
        INSERT INTO session (id, time_updated) VALUES ('session-b', 1000);
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-a', 'session-a', 1000, 1000,
                '{"role":"assistant","modelID":"shared-model","tokens":{"input":3,"output":2,"total":5}}');
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-b', 'session-b', 1000, 1000,
                '{"role":"assistant","modelID":"shared-model","tokens":{"input":3,"output":2,"total":5}}');
        """)
    }

    private func executeSQLite(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "OpenCodeTelemetryFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "failed to reopen fixture"])
        }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenCodeTelemetryFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func codexLines() -> [String] {
        [
            #"{"timestamp":"2026-08-26T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-codex","effort":"medium"}}"#,
            #"{"timestamp":"2026-08-26T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}"#
        ]
    }

    private func codexLines(accountID: String) -> [String] {
        let metadata = "{\"timestamp\":\"2026-08-26T09:59:59.000Z\",\"type\":\"session_meta\",\"payload\":{\"account_id\":\"\(accountID)\"}}"
        return [metadata] + codexLines()
    }

    private func claudeLines() -> [String] {
        [
            #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"effort":"medium","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"speed":"standard"}}}"#
        ]
    }

    private func configuredCodexQuota(prices: RunwayPriceTable,
                                      now: Date,
                                      reset: Date,
                                      accountID: String = "account-a") -> WeeklyQuotaCalibrationStore {
        let quota = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: now)
        var bootstrap = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 19.5, dollars: 100, unpricedVolumeShare: 0,
            windowStart: now.addingTimeInterval(-3600), resetsAt: reset, scannedAt: now)
        bootstrap.priceRevision = prices.revision
        bootstrap.limitShape = "weekly"
        bootstrap.sourceFamily = "oauth"
        bootstrap.activityAccountingRevision = WeeklyQuotaBootstrapResult.codexActivityAccountingRevision
        bootstrap.accountHash = WeeklyQuotaCalibrationScope.hashAccount(accountID)
        bootstrap.accountAttributionSafe = true
        quota.setBootstrapForTesting(provider: "codex", result: bootstrap)
        let scope = WeeklyQuotaCalibrationScope(
            provider: "codex",
            accountHash: WeeklyQuotaCalibrationScope.hashAccount(accountID),
            sourceFamily: "oauth",
            limitShape: "weekly",
            priceRevision: prices.revision)
        quota.observeQuota(provider: "codex", remainingPercent: 80,
                           hasExactPercent: false, resetAt: reset, observedAt: now,
                           scope: scope, now: now)
        return quota
    }

    // MARK: - Dispatch / descriptor agreement

    /// A source can declare telemetry available and still have no registry-owned
    /// provider. The engine would then return nil and make the feature look wired
    /// up while producing silence. This pins the descriptor and provider together.
    func testEveryDispatchableSourceDeclaresTelemetryAvailable() {
        for source in SessionTelemetryEngine.dispatchableSources {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            XCTAssertTrue(t.configuration.isAvailable || t.tokens.isAvailable,
                          "\(source) is dispatchable but declares no telemetry, so the engine's own gate rejects it")
        }
    }

    func testEverySourceDeclaringTelemetryIsDispatchable() {
        for source in SessionSource.allCases {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            guard t.configuration.isAvailable || t.tokens.isAvailable else { continue }
            XCTAssertTrue(SessionTelemetryEngine.dispatchableSources.contains(source),
                          "\(source) declares telemetry but the engine has no accumulator for it")
        }
    }

    // MARK: - Computation

    func testCodexSessionProducesTelemetry() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let telemetry = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(telemetry?.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertEqual(telemetry?.usageSummary?.topLineTokens, 110)
    }

    func testOpenCodeTelemetryCacheKeyIncludesSessionIdentityForSharedDatabase() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics)

        let firstValue = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let first = try XCTUnwrap(firstValue)
        let secondValue = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-b"))
        let second = try XCTUnwrap(secondValue)

        XCTAssertEqual(first.usageEvents.first?.recordID, "message-a")
        XCTAssertEqual(second.usageEvents.first?.recordID, "message-b")
        XCTAssertEqual(first.currentConfiguration?.model, "shared-model")
        XCTAssertEqual(second.currentConfiguration?.model, "shared-model")
        XCTAssertEqual(engine.parseCount, 2,
                       "two session identities in one SQLite file must not share a cache entry")
        XCTAssertEqual(metrics.snapshot.cacheHitCount, 0)
    }

    func testOpenCodeTelemetryCacheInvalidatesWhenLogicalSessionRevisionChanges() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let selected = session(dbURL, source: .opencode, id: "session-a")

        let beforeValue = await engine.telemetry(for: selected)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.usageSummary?.topLineTokens, 5)

        try executeSQLite("""
        UPDATE session SET time_updated = 2000 WHERE id = 'session-a';
        UPDATE message SET time_updated = 2000,
            data = '{"role":"assistant","modelID":"shared-model","tokens":{"input":9,"output":2,"total":11}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let afterValue = await engine.telemetry(for: selected)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.usageSummary?.topLineTokens, 11)
        XCTAssertEqual(engine.parseCount, 2,
                       "a committed SQLite revision must bypass the old session cache")
    }

    func testOpenCodeRevisionDetectsSameLengthMutationWithoutTimestampChange() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let selected = session(dbURL, source: .opencode, id: "session-a")

        let beforeValue = await engine.telemetry(for: selected)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.usageSummary?.topLineTokens, 5)

        // Keep row timestamps and payload length unchanged. A statistical
        // COUNT/MAX/SUM revision would alias this update.
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"input":4,"output":2,"total":6}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let afterValue = await engine.telemetry(for: selected)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.usageSummary?.topLineTokens, 6)
        XCTAssertEqual(engine.parseCount, 2,
                       "same-length content changes must invalidate the logical revision")
    }

    func testOpenCodeStepFinishPartsAreAuthoritativeAndNormalizeReasoning() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-a-1', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":3,"output":7,"reasoning":2,"cache":{"read":0,"write":0},"total":12}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-a-2', 'message-a', 'session-a', 1002, 1002,
                '{"type":"step-finish","tokens":{"input":2,"output":4,"reasoning":1,"cache":{"read":0,"write":0},"total":7}}');
        """, at: dbURL)

        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics)
        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageEvents.count, 2)
        XCTAssertEqual(telemetry.usageEvents.map(\.usageFamily),
                       ["opencode.step-finish.tokens", "opencode.step-finish.tokens"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 19)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 19)
        XCTAssertEqual(telemetry.usageEvents.first?.outputTokens, 9,
                       "OpenCode output excludes reasoning; normalize it into common output")
        XCTAssertEqual(telemetry.usageEvents.first?.reasoningOutputTokens, 2)
        XCTAssertGreaterThan(metrics.snapshot.telemetryBytesScanned, 0)
    }

    func testOpenCodeConfigurationSeparatesFirstAssistantObservationFromCurrentSessionMetadata() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN model TEXT;
        UPDATE session SET model = '{"id":"current-model"}' WHERE id = 'session-a';
        UPDATE message SET data = '{"role":"assistant","modelID":"assistant-model","tokens":{"input":3,"output":2,"total":5}}'
        WHERE id = 'message-a';
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-user', 'session-a', 999, 999,
                '{"role":"user","model":{"providerID":"opencode","modelID":"user-model"}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a", model: "stale-caller-model"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.initialConfiguration?.model, "assistant-model")
        XCTAssertEqual(telemetry.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "current-model")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertTrue(telemetry.configurationChanges.contains {
            $0.oldValue == "assistant-model"
                && $0.newValue == "current-model"
                && $0.provenance == .sessionMetadata
        })
    }

    func testOpenCodeCurrentSchemaUnknownModelDoesNotFallBackToAssistantModel() async throws {
        for storedModel in [
            "NULL",
            "'{\"providerID\":\"opencode\"}'",
            "'{\"id\":}'"
        ] {
            let root = directory.appendingPathComponent("unknown-model-\(UUID().uuidString)",
                                                         isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let dbURL = root.appendingPathComponent("opencode.db")
            try createOpenCodeTelemetryFixture(at: dbURL)
            try executeSQLite("""
            ALTER TABLE "session" ADD COLUMN model TEXT;
            UPDATE "session" SET model = \(storedModel) WHERE id = 'session-a';
            """, at: dbURL)

            let engine = SessionTelemetryEngine(
                priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
            let value = await engine.telemetry(
                for: session(dbURL, source: .opencode, id: "session-a", model: "stale-caller-model"))
            let telemetry = try XCTUnwrap(value, "stored model \(storedModel)")

            XCTAssertEqual(telemetry.initialConfiguration?.model, "shared-model")
            XCTAssertNil(telemetry.currentConfiguration?.model,
                         "current-schema NULL/malformed metadata must remain unknown")
        }
    }

    func testOpenCodeModernPartSchemaDoesNotFallbackToMessageTokens() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-a-text', 'message-a', 'session-a', 1001, 1001,
                '{"type":"text","text":"No usage evidence"}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "OpenCode parts contain no usable step-finish usage record.")
    }

    func testOpenCodeMixedValidAndMalformedStepFinishFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-valid', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":3,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-malformed', 'message-a', 'session-a', 1002, 1002,
                '{"type":"step-finish","tokens":{"input":4,"output":2,"reasoning":0,"cache":{"read":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty,
                      "a valid neighbor must not make an incomplete step-finish set look complete")
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "step-finish usage is incomplete") == true)
    }

    func testOpenCodeValidAndMalformedPartJSONFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-valid', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":3,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-invalid-json', 'message-a', 'session-a', 1002, 1002, 'not-json');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "stored JSON records is malformed") == true)
    }

    func testOpenCodeMalformedLegacyMessageJSONFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-invalid-json', 'session-a', 1001, 1001, 'not-json');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "stored JSON records is malformed") == true)
    }

    func testOpenCodeMalformedMessageSuppressesTranscriptConfiguration() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN model TEXT;
        UPDATE session SET model = '{"id":"metadata-model"}' WHERE id = 'session-a';
        UPDATE message
        SET data = 'not-json'
        WHERE id = 'message-a';
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-readable-later', 'session-a', 2000, 2000,
                '{"role":"assistant","modelID":"later-model","variant":"later-effort","tokens":{"input":5,"output":2}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertEqual(telemetry.currentConfiguration?.model, "metadata-model")
        XCTAssertEqual(telemetry.currentConfiguration?.modelProvenance, .sessionMetadata)
        XCTAssertTrue(telemetry.configurationChanges.isEmpty)
    }

    func testOpenCodePartialStepFinishTokensFailClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-partial', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":100}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "step-finish usage is incomplete") == true)
    }

    func testOpenCodeMalformedStepFinishValuesFailClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-valid', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":3,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-boolean', 'message-a', 'session-a', 1002, 1002,
                '{"type":"step-finish","tokens":{"input":4,"output":2,"reasoning":0,"cache":{"read":false,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-string', 'message-a', 'session-a', 1003, 1003,
                '{"type":"step-finish","tokens":{"input":4,"output":"2","reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-negative', 'message-a', 'session-a', 1004, 1004,
                '{"type":"step-finish","tokens":{"input":4,"output":2,"reasoning":-1,"cache":{"read":0,"write":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "step-finish usage is incomplete") == true)
    }

    func testOpenCodeSingleRowAggregationOverflowFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-overflow', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":0,"output":9223372036854775807,"reasoning":1,"cache":{"read":0,"write":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "exceed the supported integer range") == true)
    }

    func testOpenCodeCrossRowAggregationOverflowFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-first', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":9223372036854775807,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-second', 'message-a', 'session-a', 1002, 1002,
                '{"type":"step-finish","tokens":{"input":1,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "aggregated token totals exceed the supported integer range") == true)
    }

    func testOpenCodeOutOfRangeRecordedTotalFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-total-overflow', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":1,"output":1,"reasoning":0,"total":9223372036854775808,"cache":{"read":0,"write":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "recorded total is malformed or out of range") == true)
    }

    func testOpenCodeStringRecordedTotalFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-total-string', 'message-a', 'session-a', 1001, 1001,
                '{"type":"step-finish","tokens":{"input":1,"output":1,"reasoning":0,"total":"2","cache":{"read":0,"write":0}}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "recorded total is malformed or out of range") == true)
    }

    func testOpenCodeLegacyTotalOnlySessionKeepsRecordedTotalWithoutZeroEvent() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"total":4242}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 4_242)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown == true)
    }

    func testOpenCodeZeroComponentsDoNotMaskPositiveRecordedTotal() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":4242}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 4_242)
        XCTAssertEqual(TranscriptTelemetryPresentation.tokens(telemetry), 4_242)
    }

    func testOpenCodeMixedLegacyTotalsUseKnownDisplayTotal() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"total":100}}'
        WHERE id = 'message-a';
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-components', 'session-a', 2000, 2000,
                '{"role":"assistant","modelID":"shared-model","tokens":{"input":5,"output":2}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageSummary?.recordedTotalTokens, 100)
        XCTAssertEqual(telemetry.usageSummary?.displayTotalTokens, 107)
        XCTAssertFalse(telemetry.usageSummary?.hasComponentBreakdown == true)
        XCTAssertEqual(TranscriptTelemetryPresentation.tokens(telemetry), 107)
    }

    func testOpenCodeLegacyCacheAliasesCountAsComponentEvidence() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"cacheRead":50,"cacheWrite":7}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageEvents.count, 1)
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 57)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheReadTokens, 50)
        XCTAssertEqual(telemetry.usageEvents.first?.cacheWrite5mTokens, 7)
        XCTAssertTrue(telemetry.usageSummary?.hasComponentBreakdown == true)
    }

    func testOpenCodeLegacyOutOfRangeComponentFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        UPDATE message
        SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"input":9223372036854775808,"output":2,"total":2}}'
        WHERE id = 'message-a';
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(
            for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageSummary?.unavailableReason?.contains(
            "token component is malformed or out of range") == true)
    }

    func testOpenCodeForkedSessionExcludesInheritedUsageBeforeCreationBoundary() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN time_created INTEGER;
        ALTER TABLE session ADD COLUMN parent_id TEXT;
        UPDATE session SET time_created = 1000;
        UPDATE session SET time_created = 2000
        WHERE id = 'session-a';
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-child', 'session-a', 3000, 3000,
                '{"role":"assistant","modelID":"child-model","variant":"child-effort","tokens":{"input":5,"output":3,"total":8}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageEvents.map(\.recordID), ["message-child"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 8)
        XCTAssertEqual(telemetry.initialConfiguration?.model, "child-model")
        XCTAssertEqual(telemetry.initialConfiguration?.reasoningEffort, "child-effort")
        XCTAssertEqual(telemetry.currentConfiguration?.model, "child-model")
        XCTAssertEqual(telemetry.currentConfiguration?.reasoningEffort, "child-effort")
    }

    func testOpenCodeForkedModernPartUsesOwningMessageBoundary() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN time_created INTEGER;
        ALTER TABLE session ADD COLUMN parent_id TEXT;
        UPDATE session SET time_created = 1000;
        UPDATE session SET time_created = 2000 WHERE id = 'session-a';
        CREATE TABLE part (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data TEXT NOT NULL
        );
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-inherited', 'message-a', 'session-a', 2001, 2001,
                '{"type":"step-finish","tokens":{"input":3,"output":2,"reasoning":0,"cache":{"read":0,"write":0},"total":5}}');
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('message-child', 'session-a', 3000, 3000,
                '{"role":"assistant","modelID":"child-model"}');
        INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
        VALUES ('part-child', 'message-child', 'session-a', 3001, 3001,
                '{"type":"step-finish","tokens":{"input":5,"output":3,"reasoning":0,"cache":{"read":0,"write":0},"total":8}}');
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageEvents.map(\.recordID), ["part-child"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 8)
        XCTAssertEqual(telemetry.usageEvents.first?.observedAt,
                       Date(timeIntervalSince1970: 3.001),
                       "display timing remains the part timestamp even when attribution uses the message")
    }

    func testOpenCodeForkedSessionWithoutCreationBoundaryFailsClosedForUsage() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        try executeSQLite("""
        ALTER TABLE session ADD COLUMN parent_id TEXT;
        UPDATE session SET parent_id = 'parent-session' WHERE id = 'session-a';
        """, at: dbURL)

        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertTrue(telemetry.usageEvents.isEmpty)
        XCTAssertEqual(telemetry.usageSummary?.unavailableReason,
                       "OpenCode fork usage is unavailable because the session creation boundary is missing.")
        XCTAssertNil(telemetry.initialConfiguration)
        XCTAssertNil(telemetry.currentConfiguration)
    }

    func testOpenCodeLateCancellationPreservesScannedBytes() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let blocker = BlockingAction()
        let selected = session(dbURL, source: .opencode, id: "session-a")
        let scan = Task {
            OpenCodeSqliteReader.loadTelemetry(
                for: selected,
                afterRowsLoaded: { blocker.run() })
        }

        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        scan.cancel()
        blocker.release()
        let result = await scan.value

        XCTAssertGreaterThan(result?.bytesScanned ?? 0, 0)
        XCTAssertTrue(result?.result.telemetry.usageEvents.isEmpty == true)
    }

    func testOpenCodeRevisionRetrySeesCommittedWALUpdate() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let writer = try SQLiteWALWriter(url: dbURL)
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try writer.execute("UPDATE session SET time_updated = 1001 WHERE id = 'session-a';")
        let mutation = OneShotAction {
            try? writer.execute("""
            UPDATE message
            SET data = '{"role":"assistant","modelID":"shared-model","tokens":{"input":4,"output":3,"total":7}}'
            WHERE id = 'message-a';
            """)
        }
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryScan: { mutation.run() })

        let value = await engine.telemetry(for: session(dbURL, source: .opencode, id: "session-a"))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 7)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2,
                       "a committed WAL update between revision and scan must trigger one bounded retry")
        XCTAssertEqual(engine.parseCount, 1,
                       "the rejected first pass must not count as an accepted parse")
    }

    func testCancellingFinalOpenCodeSubscriberDoesNotPublishTelemetry() async throws {
        let dbURL = directory.appendingPathComponent("opencode.db")
        try createOpenCodeTelemetryFixture(at: dbURL)
        let blocker = BlockingAction()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            beforeTelemetryScan: { blocker.run() })
        let selected = session(dbURL, source: .opencode, id: "session-a")

        let cancelled = Task { await engine.telemetry(for: selected) }
        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        XCTAssertNil(cancelledValue)

        blocker.release()
        let replacement = await engine.telemetry(for: selected)
        XCTAssertNotNil(replacement)
        XCTAssertEqual(engine.parseCount, 1)
    }

    func testFirstCallParsesAndSecondCallIsCached() async throws {
        let url = try write(codexLines())
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics)
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1)
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1, "unchanged file must not be re-parsed")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        XCTAssertEqual(metrics.snapshot.cacheHitCount, 1)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 1)
        XCTAssertEqual(metrics.snapshot.telemetryBytesScanned, byteCount)
    }

    func testRevisionChangesImmediatelyBeforeComputedPublicationAreRetried() async throws {
        let initial = claudeLines()
        let appended = #"{"type":"assistant","timestamp":"2026-08-26T10:00:01.000Z","isSidechain":false,"effort":"medium","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"speed":"standard"}}}"#
        let url = try write(initial)
        let mutation = OneShotAction {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\n\(appended)".utf8))
            try? handle.close()
        }
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryPublication: { mutation.run() })

        let value = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 1_800)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2,
                       "a late file mutation must trigger one bounded retry")
    }

    func testRevisionChangesImmediatelyBeforeCachedPublicationAreRetried() async throws {
        let initial = claudeLines()
        let appended = #"{"type":"assistant","timestamp":"2026-08-26T10:00:01.000Z","isSidechain":false,"effort":"medium","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":200,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"speed":"standard"}}}"#
        let url = try write(initial)
        let mutation = ArmableOneShotAction {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\n\(appended)".utf8))
            try? handle.close()
        }
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryPublication: { mutation.run() })
        _ = await engine.telemetry(for: session(url, source: .claude))
        mutation.arm()

        let value = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(value)

        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 1_800)
        XCTAssertEqual(engine.parseCount, 2)
        XCTAssertEqual(metrics.snapshot.cacheHitCount, 0,
                       "a cache lookup invalidated by a late mutation must not be counted as a hit")
    }

    func testCancellationDuringPublicationDoesNotReturnTelemetry() async throws {
        let url = try write(claudeLines())
        let blocker = BlockingAction()
        let cancellation = TaskCancellationController()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            beforeTelemetryScan: { blocker.run() },
            beforeTelemetryPublication: { cancellation.cancel() })
        let request = Task { await engine.telemetry(for: session(url, source: .claude)) }

        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        cancellation.install(request)
        blocker.release()

        let value = await request.value
        XCTAssertNil(value)
    }

    func testCancelledSubscriberDoesNotReturnCachedTelemetry() async throws {
        let url = try write(codexLines())
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics)
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1)

        let cancelled = Task {
            await Task.yield()
            return await engine.telemetry(for: session(url, source: .codex))
        }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        XCTAssertNil(cancelledValue)
        XCTAssertEqual(metrics.snapshot.cacheHitCount, 0,
                       "a cancelled subscriber must not record or receive a cache hit")
    }

    func testConcurrentIdenticalScansShareOneProducer() async throws {
        let url = try write(codexLines())
        let metrics = SessionInfoMetrics()
        let blocker = BlockingAction()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryScan: { blocker.run() })

        let first = Task { await engine.telemetry(for: session(url, source: .codex)) }
        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        let second = Task { await engine.telemetry(for: session(url, source: .codex)) }
        for _ in 0..<10_000 where metrics.snapshot.inFlightJoinCount == 0 {
            await Task.yield()
        }
        blocker.release()
        let firstValue = await first.value
        let secondValue = await second.value

        XCTAssertNotNil(firstValue)
        XCTAssertNotNil(secondValue)
        XCTAssertEqual(engine.parseCount, 1)
        XCTAssertEqual(metrics.snapshot.inFlightJoinCount, 1)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 1)
    }

    func testCancellingOneSubscriberLeavesSharedProducerForAnother() async throws {
        let url = try write(codexLines())
        let metrics = SessionInfoMetrics()
        let blocker = BlockingAction()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryScan: { blocker.run() })

        let first = Task { await engine.telemetry(for: session(url, source: .codex)) }
        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        let second = Task { await engine.telemetry(for: session(url, source: .codex)) }
        for _ in 0..<10_000 where metrics.snapshot.inFlightJoinCount == 0 {
            await Task.yield()
        }

        first.cancel()
        let firstValue = await first.value
        XCTAssertNil(firstValue, "a cancelled subscriber should return without waiting for the producer")

        blocker.release()
        let secondValue = await second.value
        XCTAssertNotNil(secondValue, "cancelling one subscriber must not cancel the shared producer")
        XCTAssertEqual(engine.parseCount, 1)
        XCTAssertEqual(metrics.snapshot.inFlightJoinCount, 1)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 1)
    }

    func testCancellingFinalSubscriberCancelsProducerAndNextRequestStartsFresh() async throws {
        let url = try write(codexLines())
        let metrics = SessionInfoMetrics()
        let blocker = BlockingAction()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            beforeTelemetryScan: { blocker.run() })

        let cancelled = Task { await engine.telemetry(for: session(url, source: .codex)) }
        for _ in 0..<10_000 where !blocker.hasEntered {
            await Task.yield()
        }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        XCTAssertNil(cancelledValue)

        // The final lease removes the producer before it finishes. Releasing
        // the test gate lets its cooperative cancellation check return without
        // counting a completed parse or populating the cache.
        blocker.release()
        for _ in 0..<10_000 where metrics.snapshot.telemetryRequestCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(engine.parseCount, 0)

        let next = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertNotNil(next, "a request after final-subscriber cancellation must not join the cancelled producer")
        XCTAssertEqual(engine.parseCount, 1)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2)
    }

    func testAppendDuringScanDoesNotCacheStaleRevision() async throws {
        let url = try write(codexLines())
        let initialBytes = UInt64(try Data(contentsOf: url).count)
        let appendedLine = codexLines().last!
        let appendOnce = OneShotAction {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\n\(appendedLine)".utf8))
            try? handle.close()
        }
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            afterFirstTelemetryLine: { appendOnce.run() })

        let telemetry = await engine.telemetry(for: session(url, source: .codex))
        let finalBytes = UInt64(try Data(contentsOf: url).count)

        XCTAssertNotNil(telemetry)
        XCTAssertGreaterThan(finalBytes, initialBytes)
        XCTAssertEqual(engine.parseCount, 1, "the stale first pass must not count as a completed parse")
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2,
                       "a changed file is retried once against its new signature")
        XCTAssertEqual(metrics.snapshot.telemetryBytesScanned, initialBytes + finalBytes,
                       "bytes scanned must report each bounded physical read")
    }

    func testRepeatedChangesRetryOnlyOnceAndFailClosed() async throws {
        let url = try write(codexLines())
        let appendEveryTime = AppendOnEveryCall(url: url, line: codexLines().last!)
        let metrics = SessionInfoMetrics()
        let engine = SessionTelemetryEngine(
            priceTable: RunwayPriceTable(loadBundled: true, readCache: false),
            metrics: metrics,
            afterFirstTelemetryLine: { appendEveryTime.run() })

        let telemetry = await engine.telemetry(for: session(url, source: .codex))

        XCTAssertNil(telemetry, "a continuously changing transcript must not publish a stale result")
        XCTAssertEqual(engine.parseCount, 0)
        XCTAssertEqual(metrics.snapshot.telemetryRequestCount, 2,
                       "the retry budget is exactly one additional bounded scan")
    }

    func testManifestChangeDuringScanUsesOnePricingSnapshot() async throws {
        let url = try write(codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let firstManifest = Data(#"{"version":1,"updated":"2098-01-01","models":{"gpt-5.5":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        let secondManifest = Data(#"{"version":1,"updated":"2099-01-01","models":{"gpt-5.5":{"inputPerMTok":8,"cachedInputPerMTok":0.8,"outputPerMTok":40,"cacheWritePerMTok":null}}}"#.utf8)
        XCTAssertTrue(prices.loadForTesting(json: firstManifest))
        let refreshOnce = OneShotAction {
            _ = prices.loadForTesting(json: secondManifest)
        }
        let engine = SessionTelemetryEngine(
            priceTable: prices,
            beforeTelemetryScan: { refreshOnce.run() })

        let firstValue = await engine.telemetry(for: session(url, source: .codex))
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.costEstimate?.priceTableUpdated, "2098-01-01")
        XCTAssertEqual(engine.parseCount, 1)

        let secondValue = await engine.telemetry(for: session(url, source: .codex))
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.costEstimate?.priceTableUpdated, "2099-01-01")
        XCTAssertEqual(engine.parseCount, 2,
                       "the second pricing identity must not reuse the first snapshot")
    }

    func testPriceRevisionChangeInvalidatesCachedCost() async throws {
        let url = try write(codexLines())
        let prices = RunwayPriceTable.makeForTesting()
        let engine = SessionTelemetryEngine(priceTable: prices)
        let firstValue = await engine.telemetry(for: session(url, source: .codex))
        let first = try XCTUnwrap(firstValue)
        let firstRevision = try XCTUnwrap(first.costEstimate?.priceTableRevision)

        let replacement = Data(#"{"version":1,"updated":"2099-01-01","models":{"gpt-5.6-codex":{"inputPerMTok":8,"cachedInputPerMTok":0.8,"outputPerMTok":40,"cacheWritePerMTok":10}}}"#.utf8)
        XCTAssertTrue(prices.loadForTesting(json: replacement))
        let secondValue = await engine.telemetry(for: session(url, source: .codex))
        let second = try XCTUnwrap(secondValue)

        XCTAssertNotEqual(second.costEstimate?.priceTableRevision, firstRevision)
        XCTAssertEqual(engine.parseCount, 2, "same bytes must be re-priced after a manifest revision")
        XCTAssertEqual(second.usageEvents.first?.priceTableRevision, prices.revision)
    }

    func testPriceMetadataChangeInvalidatesCachedProvenance() async throws {
        let url = try write(codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let firstManifest = Data(#"{"version":1,"updated":"2098-01-01","models":{"gpt-5.5":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        let secondManifest = Data(#"{"version":1,"updated":"2099-01-01","models":{"gpt-5.5":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        XCTAssertTrue(prices.loadForTesting(json: firstManifest))
        let semanticRevision = prices.revision
        let engine = SessionTelemetryEngine(priceTable: prices)
        let firstValue = await engine.telemetry(for: session(url, source: .codex))
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.costEstimate?.priceTableUpdated, "2098-01-01")
        XCTAssertEqual(engine.parseCount, 1)

        XCTAssertTrue(prices.loadForTesting(json: secondManifest))
        XCTAssertEqual(prices.revision, semanticRevision,
                       "metadata-only edits must not invalidate calibration")
        let secondValue = await engine.telemetry(for: session(url, source: .codex))
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.costEstimate?.priceTableUpdated, "2099-01-01")
        XCTAssertEqual(engine.parseCount, 2,
                       "cache must refresh the exact manifest provenance even when rates are unchanged")
    }

    func testSameDateManifestMetadataChangeInvalidatesExactProvenance() async throws {
        let url = try write(codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let firstManifest = Data(#"{"version":1,"updated":"2099-01-01","_note":"first","models":{"gpt-5.5":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        let secondManifest = Data(#"{"version":1,"updated":"2099-01-01","_note":"second","models":{"gpt-5.5":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        XCTAssertTrue(prices.loadForTesting(json: firstManifest))
        let engine = SessionTelemetryEngine(priceTable: prices)
        let firstValue = await engine.telemetry(for: session(url, source: .codex))
        let first = try XCTUnwrap(firstValue)
        let firstFingerprint = try XCTUnwrap(first.costEstimate?.priceManifestFingerprint)

        XCTAssertTrue(prices.loadForTesting(json: secondManifest))
        let secondValue = await engine.telemetry(for: session(url, source: .codex))
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(second.costEstimate?.priceManifestFingerprint, firstFingerprint)
        XCTAssertEqual(second.costEstimate?.priceManifestFingerprint, prices.manifestFingerprint)
        XCTAssertEqual(engine.parseCount, 2)
    }

    /// The exact staleness case a mtime-only key misses.
    func testSizeChangeWithFixedMtimeRecomputes() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1)

        let fixedMtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        try (codexLines() + codexLines()).joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixedMtime], ofItemAtPath: url.path)

        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 2, "size changed; the cached result is stale")
    }

    func testUnsupportedSourceReturnsNil() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let telemetry = await engine.telemetry(for: session(url, source: .fx))
        XCTAssertNil(telemetry, "fx telemetry is only supported for checkpoint.json sessions")
    }

    func testMissingFileReturnsNil() async {
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let missing = directory.appendingPathComponent("nope.jsonl")
        let telemetry = await engine.telemetry(for: session(missing, source: .codex))
        XCTAssertNil(telemetry)
    }

    // MARK: - Cost wiring

    /// Guards the failure mode where Claude telemetry computes fine but silently
    /// never gets a dollar figure.
    func testClaudeSessionWithBreakdownGetsCostEstimate() async throws {
        let url = try write(claudeLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let telemetry = await engine.telemetry(for: session(url, source: .claude))
        let cost = try XCTUnwrap(telemetry?.costEstimate)
        // 1000 fresh @ $5/MTok + 500 output @ $25/MTok
        XCTAssertEqual(try XCTUnwrap(cost.apiEquivalentUSD), 0.0175, accuracy: 0.000001)
        XCTAssertFalse(cost.priceTableUpdated.isEmpty)
        XCTAssertEqual(try XCTUnwrap(telemetry?.usageEvents.first?.apiEquivalentUSD),
                       0.0175, accuracy: 0.000001)
    }

    func testClaudeWeeklyQuotaFailsClosedWithoutStableAccountIdentity() async throws {
        let url = try write(claudeLines())
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: now)
        var bootstrap = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 19.5, dollars: 100, unpricedVolumeShare: 0,
            windowStart: now.addingTimeInterval(-3600), resetsAt: reset, scannedAt: now)
        bootstrap.priceRevision = prices.revision
        bootstrap.limitShape = "weekly"
        bootstrap.sourceFamily = "oauth"
        quota.setBootstrapForTesting(provider: "claude", result: bootstrap)
        let scope = WeeklyQuotaCalibrationScope(provider: "claude", accountHash: nil,
                                                sourceFamily: "oauth", limitShape: "weekly",
                                                priceRevision: prices.revision)
        quota.observeQuota(provider: "claude", remainingPercent: 80, hasExactPercent: false,
                           resetAt: reset, observedAt: now, scope: scope, now: now)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertEqual(estimate.unavailableReason,
                       "provider does not expose a stable account identity")
        XCTAssertEqual(try XCTUnwrap(estimate.percentPointsPerAPIDollar), 0.2, accuracy: 0.000001)
        XCTAssertNil(estimate.percentPoints)
        XCTAssertFalse(estimate.accountScoped, "Claude exposes no stable account identity")
    }

    func testCodexWeeklyQuotaFailsClosedWithoutDurableTranscriptAccountIdentity() async throws {
        let url = try write(codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = configuredCodexQuota(prices: prices, now: now, reset: reset)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .codex))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertEqual(estimate.unavailableReason,
                       "session has no durable account identity matching the calibration account")
        XCTAssertNil(estimate.percentPoints)
        XCTAssertFalse(estimate.accountScoped)
        XCTAssertEqual(estimate.calibrationProvenance?.origin, .bootstrap)
        XCTAssertEqual(estimate.calibrationProvenance?.accountHash,
                       WeeklyQuotaCalibrationScope.hashAccount("account-a"))
    }

    func testCodexWeeklyQuotaFailsClosedForMismatchedDurableTranscriptAccount() async throws {
        let url = try write(codexLines(accountID: "account-b").map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = configuredCodexQuota(prices: prices, now: now, reset: reset)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .codex))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertEqual(estimate.unavailableReason,
                       "session has no durable account identity matching the calibration account")
        XCTAssertNil(estimate.percentPoints)
        XCTAssertFalse(estimate.accountScoped)
    }

    func testCodexWeeklyQuotaUsesMatchingDurableTranscriptAccountIdentity() async throws {
        let url = try write(codexLines(accountID: "account-a").map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = configuredCodexQuota(prices: prices, now: now, reset: reset)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .codex))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .estimated)
        XCTAssertNotNil(estimate.percentPoints)
        XCTAssertTrue(estimate.accountScoped)
        XCTAssertEqual(estimate.calibrationProvenance?.origin, .bootstrap)
        XCTAssertEqual(estimate.calibrationProvenance?.sourceFamily, "oauth")
        XCTAssertEqual(estimate.calibrationProvenance?.accountHash,
                       WeeklyQuotaCalibrationScope.hashAccount("account-a"))
        XCTAssertEqual(estimate.calibrationProvenance?.scannedAt, now)
        XCTAssertEqual(estimate.quotaObservedAt, now,
                       "the latest raw observation remains separate from scan provenance")
    }

    func testCodexWeeklyQuotaFailsClosedForConflictingTranscriptAccountIdentities() async throws {
        let lines = [
            #"{"type":"session_meta","payload":{"account_id":"account-a"}}"#,
            #"{"type":"session_started","payload":{"accountId":"account-b"}}"#
        ] + codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        }
        let url = try write(lines)
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = configuredCodexQuota(prices: prices, now: now, reset: reset)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .codex))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertNil(estimate.percentPoints)
        XCTAssertFalse(estimate.accountScoped)
    }

    func testCodexWeeklyQuotaFailsClosedForConflictingAccountIDsInOneMetadataRecord() async throws {
        let lines = [
            #"{"type":"session_meta","account_id":"account-a","payload":{"account_id":"account-a","accountId":"account-b"}}"#
        ] + codexLines().map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        }
        let url = try write(lines)
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = configuredCodexQuota(prices: prices, now: now, reset: reset)

        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })
        let telemetryValue = await engine.telemetry(for: session(url, source: .codex))
        let telemetry = try XCTUnwrap(telemetryValue)
        let estimate = try XCTUnwrap(telemetry.weeklyQuotaEstimate)
        XCTAssertEqual(estimate.status, .unavailable)
        XCTAssertNil(estimate.percentPoints)
        XCTAssertFalse(estimate.accountScoped)
    }

    func testCachedTranscriptRefreshesWeeklyQuotaWithoutReparsing() async throws {
        let url = try write(codexLines(accountID: "account-a").map {
            $0.replacingOccurrences(of: "gpt-5.6-codex", with: "gpt-5.5")
        })
        let prices = RunwayPriceTable.makeForTesting()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let reset = now.addingTimeInterval(604_800)
        let quota = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: now)
        let engine = SessionTelemetryEngine(priceTable: prices, quotaStore: quota, now: { now })

        let beforeValue = await engine.telemetry(for: session(url, source: .codex))
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.weeklyQuotaEstimate?.status, .unavailable)
        XCTAssertEqual(engine.parseCount, 1)

        var bootstrap = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 19.5, dollars: 100, unpricedVolumeShare: 0,
            windowStart: now.addingTimeInterval(-3600), resetsAt: reset, scannedAt: now)
        bootstrap.priceRevision = prices.revision
        bootstrap.limitShape = "weekly"
        bootstrap.sourceFamily = "oauth"
        bootstrap.activityAccountingRevision = WeeklyQuotaBootstrapResult.codexActivityAccountingRevision
        bootstrap.accountHash = WeeklyQuotaCalibrationScope.hashAccount("account-a")
        bootstrap.accountAttributionSafe = true
        quota.setBootstrapForTesting(provider: "codex", result: bootstrap)
        let scope = WeeklyQuotaCalibrationScope(provider: "codex",
                                                accountHash: WeeklyQuotaCalibrationScope.hashAccount("account-a"),
                                                sourceFamily: "oauth", limitShape: "weekly",
                                                priceRevision: prices.revision)
        quota.observeQuota(provider: "codex", remainingPercent: 80, hasExactPercent: false,
                           resetAt: reset, observedAt: now, scope: scope, now: now)

        let afterValue = await engine.telemetry(for: session(url, source: .codex))
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.weeklyQuotaEstimate?.status, .estimated)
        XCTAssertEqual(try XCTUnwrap(after.weeklyQuotaEstimate?.percentPointsPerAPIDollar),
                       0.2, accuracy: 0.000001)
        XCTAssertTrue(after.weeklyQuotaEstimate?.accountScoped == true)
        XCTAssertEqual(engine.parseCount, 1, "quota changes must reuse the parsed transcript")
    }

    func testCodexLegacyTotalOnlySessionHasNoCostEstimate() async throws {
        let legacy = [
            #"{"timestamp":"2026-08-26T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-codex","effort":"medium"}}"#,
            #"{"timestamp":"2026-08-26T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":4242}}}}"#
        ]
        let url = try write(legacy)
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let telemetry = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(telemetry?.usageSummary?.recordedTotalTokens, 4_242)
        XCTAssertNil(telemetry?.costEstimate, "no component breakdown means nothing to price")
        XCTAssertEqual(telemetry?.weeklyQuotaEstimate?.status, .unavailable)
        XCTAssertEqual(telemetry?.weeklyQuotaEstimate?.unavailableReason,
                       "session has no priceable component breakdown")
    }

    func testManifestChangeDuringTotalOnlyScanKeepsCapturedQuotaRevision() async throws {
        let legacy = [
            #"{"timestamp":"2026-08-26T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-codex","effort":"medium"}}"#,
            #"{"timestamp":"2026-08-26T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":4242}}}}"#
        ]
        let url = try write(legacy)
        let prices = RunwayPriceTable.makeForTesting()
        let firstManifest = Data(#"{"version":1,"updated":"2098-01-01","models":{"gpt-5.6-codex":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":30,"cacheWritePerMTok":null}}}"#.utf8)
        let secondManifest = Data(#"{"version":1,"updated":"2099-01-01","models":{"gpt-5.6-codex":{"inputPerMTok":8,"cachedInputPerMTok":0.8,"outputPerMTok":40,"cacheWritePerMTok":null}}}"#.utf8)
        XCTAssertTrue(prices.loadForTesting(json: firstManifest))
        let firstRevision = prices.revision
        let refreshOnce = OneShotAction {
            _ = prices.loadForTesting(json: secondManifest)
        }
        let engine = SessionTelemetryEngine(
            priceTable: prices,
            beforeTelemetryScan: { refreshOnce.run() })

        let firstValue = await engine.telemetry(for: session(url, source: .codex))
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.weeklyQuotaEstimate?.priceTableRevision, firstRevision)

        let secondValue = await engine.telemetry(for: session(url, source: .codex))
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.weeklyQuotaEstimate?.priceTableRevision, prices.revision)
        XCTAssertNotEqual(second.weeklyQuotaEstimate?.priceTableRevision, firstRevision)
    }

    // MARK: - Parity with direct accumulation

    func testMatchesAccumulatorCalledDirectly() async throws {
        let lines = claudeLines()
        let url = try write(lines)
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let computed = await engine.telemetry(for: session(url, source: .claude))
        let viaEngine = try XCTUnwrap(computed)
        let direct = ClaudeTelemetryAccumulator.accumulate(lines: lines)
        XCTAssertEqual(viaEngine.usageSlices, direct.usageSlices)
        XCTAssertEqual(viaEngine.initialConfiguration, direct.initialConfiguration)
        XCTAssertEqual(viaEngine.configurationChanges, direct.configurationChanges)
    }

    func testClaudeInferenceGeoIsPreservedAndPriced() async throws {
        let line = #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"speed":"standard","inference_geo":"us"}}}"#
        let url = try write([line])
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable.makeForTesting())
        let computed = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(computed)
        XCTAssertEqual(telemetry.usageSlices.first?.inferenceGeo, "us")
        XCTAssertEqual(telemetry.usageEvents.first?.inferenceGeo, "us")
        XCTAssertEqual(try XCTUnwrap(telemetry.costEstimate?.apiEquivalentUSD),
                       5.5, accuracy: 0.000_001)
    }

    func testClaudeUnavailableInferenceGeoIsPreservedAndPricedAtBaseRate() async throws {
        let line = #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0,"inference_geo":"not_available"}}}"#
        let url = try write([line])
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable.makeForTesting())
        let computed = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(computed)
        XCTAssertEqual(telemetry.usageSlices.first?.inferenceGeo, "not_available")
        XCTAssertEqual(telemetry.usageEvents.first?.inferenceGeo, "not_available")
        XCTAssertEqual(try XCTUnwrap(telemetry.costEstimate?.apiEquivalentUSD),
                       5.0, accuracy: 0.000_001)
        XCTAssertEqual(telemetry.costEstimate?.missingPriceComponents, [])
    }

    func testClaudeEmptyInferenceGeoIsPreservedAndPricedAtBaseRate() async throws {
        let line = #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0,"inference_geo":""}}}"#
        let url = try write([line])
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable.makeForTesting())
        let computed = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(computed)
        XCTAssertEqual(telemetry.usageEvents.first?.inferenceGeo, "")
        XCTAssertEqual(try XCTUnwrap(telemetry.costEstimate?.apiEquivalentUSD),
                       5.0, accuracy: 0.000_001)
    }

    func testClaudeMalformedInferenceGeoFailsClosed() async throws {
        let line = #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":0,"inference_geo":"moon"}}}"#
        let url = try write([line])
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable.makeForTesting())
        let computed = await engine.telemetry(for: session(url, source: .claude))
        let telemetry = try XCTUnwrap(computed)
        XCTAssertEqual(telemetry.usageEvents.first?.inferenceGeo, "unknown")
        XCTAssertNil(telemetry.costEstimate?.apiEquivalentUSD)
        XCTAssertEqual(telemetry.costEstimate?.missingPriceComponents,
                       ["claude-opus-5:inferenceGeo:unknown"])
    }
}
