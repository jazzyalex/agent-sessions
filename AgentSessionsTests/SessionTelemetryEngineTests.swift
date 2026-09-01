import XCTest
@testable import AgentSessions

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

    private func session(_ url: URL, source: SessionSource) -> Session {
        Session(id: "s1", source: source, startTime: nil, endTime: nil, model: nil,
                filePath: url.path, eventCount: 0, events: [])
    }

    private func codexLines() -> [String] {
        [
            #"{"timestamp":"2026-08-26T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-codex","effort":"medium"}}"#,
            #"{"timestamp":"2026-08-26T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}}}}"#
        ]
    }

    private func claudeLines() -> [String] {
        [
            #"{"type":"assistant","timestamp":"2026-08-26T10:00:00.000Z","isSidechain":false,"effort":"medium","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"speed":"standard"}}}"#
        ]
    }

    // MARK: - Computation

    func testCodexSessionProducesTelemetry() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        let telemetry = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(telemetry?.initialConfiguration?.model, "gpt-5.6-codex")
        XCTAssertEqual(telemetry?.usageSummary?.topLineTokens, 110)
    }

    func testFirstCallParsesAndSecondCallIsCached() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1)
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1, "unchanged file must not be re-parsed")
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
        let telemetry = await engine.telemetry(for: session(url, source: .qwen))
        XCTAssertNil(telemetry, "qwen declares telemetry unavailable")
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
}
