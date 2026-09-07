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

    /// A source can declare telemetry available and still have no `case` in the
    /// engine's switch. The `default` arm returns nil, which is indistinguishable
    /// from a source that correctly declares nothing — so the feature would look
    /// wired up and produce silence. This pins the two lists together.
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

    func testFirstCallParsesAndSecondCallIsCached() async throws {
        let url = try write(codexLines())
        let engine = SessionTelemetryEngine(priceTable: RunwayPriceTable(loadBundled: true, readCache: false))
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1)
        _ = await engine.telemetry(for: session(url, source: .codex))
        XCTAssertEqual(engine.parseCount, 1, "unchanged file must not be re-parsed")
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
