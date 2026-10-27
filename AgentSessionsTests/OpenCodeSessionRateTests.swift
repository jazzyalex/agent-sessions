import XCTest
import SQLite3
@testable import AgentSessions

/// OpenCode per-session rates in the Quota Meter: burst selection, burst-scoped
/// pricing, and the value a row shows.
final class OpenCodeSessionRateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var prices: RunwayPriceSnapshot { RunwayPriceTable.makeForTesting().snapshot() }

    @MainActor
    override func tearDown() async throws {
        // A sampler left running would keep hopping to the main actor for the rest of
        // the test process.
        SamplerHarness.started.forEach { $0.stop() }
        SamplerHarness.started.removeAll()
        try await super.tearDown()
    }

    // MARK: - Task 4: burst first, then price exactly the burst

    func testBurstSpanAndWeight() throws {
        // 24 000 weighted tokens over 120 s → 720 000 tk/h.
        let events = [
            event(start: 0, end: 50, fresh: 10_000, output: 2_000, cacheRead: 0),
            event(start: 60, end: 120, fresh: 8_000, output: 2_000, cacheRead: 20_000),
        ]
        let burst = try XCTUnwrap(OpenCodeSessionRate.burst(events))
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        XCTAssertEqual(activity.tokensPerHour, 720_000, accuracy: 0.001)
        XCTAssertEqual(activity.newestCompletion, t0.addingTimeInterval(120))
    }

    func testGapStartsNewBurst() throws {
        let events = [
            event(start: 0, end: 100, fresh: 1),
            event(start: 100 + 31 * 60, end: 100 + 31 * 60 + 90, fresh: 1, id: "late"),
        ]
        let burst = try XCTUnwrap(OpenCodeSessionRate.burst(events))
        XCTAssertEqual(burst.map(\.recordID), ["late"])
    }

    func testShortSpanHasNoBurst() {
        XCTAssertNil(OpenCodeSessionRate.burst([event(start: 0, end: 20, fresh: 50_000)]))
    }

    func testOldUnpricedOutsideBurstDoesNotHideRate() throws {
        let events = [
            event(start: 0, end: 30, fresh: 1_000, model: "made-up-model"),
            event(start: 40 * 60, end: 40 * 60 + 60, fresh: 1_000, model: "gpt-5"),
            event(start: 40 * 60 + 70, end: 40 * 60 + 130, fresh: 1_000, model: "gpt-5"),
        ]
        let burst = try XCTUnwrap(OpenCodeSessionRate.burst(events))
        guard case .priced = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing else {
            return XCTFail("an unpriced request outside the burst must not hide its rate")
        }
    }

    func testMixedFreeAndPaidIsNotFree() throws {
        let burst = [event(start: 0, end: 60, fresh: 1_000, model: "minimax-m3.1-flash-free"),
                     event(start: 70, end: 130, fresh: 1_000, model: "gpt-5")]
        guard case .priced = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing else {
            return XCTFail("free only when every burst request used a free route")
        }
    }

    func testAllFreeIsFree() {
        let burst = [event(start: 0, end: 60, fresh: 1_000, model: "minimax-m3.1-flash-free"),
                     event(start: 70, end: 130, fresh: 1_000, model: "minimax-m3.1-flash-free")]
        XCTAssertEqual(OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing, .allFreeRoute)
    }

    func testUnknownModelReasonIsKept() {
        let burst = [event(start: 0, end: 90, fresh: 1_000, model: "made-up-model")]
        XCTAssertEqual(OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing,
                       .unpriced(unknownModels: ["made-up-model"], missingComponents: []))
    }

    func testMissingWriteRateReasonIsKept() {
        let burst = [event(start: 0, end: 90, fresh: 1_000, cacheWrite: 500, model: "gpt-5")]
        guard case .unpriced(let models, let components) = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing else {
            return XCTFail("a positive write with no published write rate is unpriced")
        }
        XCTAssertEqual(models, [])
        XCTAssertTrue(components.contains { $0.hasPrefix("gpt-5:cacheWrite") }, "\(components)")
    }

    func testMixedReasonsBothKept() {
        let burst = [event(start: 0, end: 60, fresh: 1_000, model: "made-up-model"),
                     event(start: 70, end: 130, fresh: 1_000, cacheWrite: 500, model: "gpt-5")]
        guard case .unpriced(let models, let components) = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing else {
            return XCTFail("expected unpriced")
        }
        XCTAssertEqual(models, ["made-up-model"])
        XCTAssertFalse(components.isEmpty)
    }

    func testNilUSDWithNoReasonsIsUnpricedWithEmptyLists() {
        XCTAssertEqual(OpenCodeSessionRate.pricing(burstUSD: [1.0, nil], estimate: estimate()),
                       .unpriced(unknownModels: [], missingComponents: []))
    }

    func testPeriodBoundaryPricesEachEventAtItsDate() throws {
        // gemini-3.8-flash doubles on 2027-01-01 (UTC).
        let boundary = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        let before = TestEvent(start: boundary.addingTimeInterval(-120), end: boundary.addingTimeInterval(-60))
        let after = TestEvent(start: boundary.addingTimeInterval(60), end: boundary.addingTimeInterval(120))
        let priced = TelemetryCostCalculator.price(
            events: [before.event(fresh: 1_000_000, model: "gemini-3.8-flash"),
                     after.event(fresh: 1_000_000, model: "gemini-3.8-flash")],
            fallbackSlices: [], snapshot: prices).events.map(\.apiEquivalentUSD)
        XCTAssertEqual(priced[0] ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(priced[1] ?? 0, 1.5, accuracy: 0.0001)
        let activity = OpenCodeSessionRate.activity(
            burst: [before.event(fresh: 1_000_000, model: "gemini-3.8-flash"),
                    after.event(fresh: 1_000_000, model: "gemini-3.8-flash")],
            prices: prices)
        guard case .priced(let perHour) = activity.pricing else { return XCTFail("expected priced") }
        XCTAssertEqual(perHour, (0.75 + 1.5) / 240 * 3600, accuracy: 0.0001)
    }

    func testLongContextEventPricedAtItsTier() {
        let small = event(start: 0, end: 60, fresh: 100_000, model: "gpt-5.4", context: 100_000)
        let large = event(start: 70, end: 130, fresh: 300_000, model: "gpt-5.4", context: 300_000)
        guard case .priced(let perHour) = OpenCodeSessionRate.activity(burst: [small, large], prices: prices).pricing else {
            return XCTFail("expected priced")
        }
        let usd = (100_000 * 2.5 + 300_000 * 2.5 * 2.0) / 1_000_000
        XCTAssertEqual(perHour, usd / 130 * 3600, accuracy: 0.0001)
    }

    func testDollarsMatchSessionInfoForSameEvents() {
        let burst = [event(start: 0, end: 60, fresh: 2_000, output: 500, cacheRead: 9_000, model: "gpt-5"),
                     event(start: 70, end: 130, fresh: 1_000, output: 300, model: "gpt-5.4", context: 1_000)]
        let sessionInfo = sessionInfoPricing(burst)
        guard case .priced(let perHour) = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing,
              let total = sessionInfo.estimate.apiEquivalentUSD else { return XCTFail("expected priced") }
        XCTAssertEqual(perHour, total / 130 * 3600, accuracy: 0.000001)
    }

    func testUnverifiedWriteTTLIsUnpricedLikeSessionInfo() {
        // OpenCode records one cache-write count with no TTL. A model whose 5-minute and
        // 1-hour writes cost differently cannot be priced, exactly as Session Info decides.
        let burst = [event(start: 0, end: 60, fresh: 1_000, cacheWrite: 4_000, model: "claude-sonnet-4-6"),
                     event(start: 70, end: 130, fresh: 1_000, model: "claude-sonnet-4-6")]
        let sessionInfo = sessionInfoPricing(burst).estimate
        XCTAssertNil(sessionInfo.apiEquivalentUSD, "Session Info refuses it")
        guard case .unpriced(_, let components) = OpenCodeSessionRate.activity(burst: burst, prices: prices).pricing else {
            return XCTFail("the Quota Meter must agree with Session Info")
        }
        XCTAssertEqual(components, sessionInfo.missingPriceComponents.sorted())
    }

    /// Prices exactly as Session Info does for OpenCode: the engine passes the source
    /// descriptor's telemetry flags.
    private func sessionInfoPricing(_ events: [TelemetryUsageEvent]) -> TelemetryCostCalculator.Result {
        let capabilities = SessionSourceDescriptor.opencode.telemetry
        return TelemetryCostCalculator.price(events: events, fallbackSlices: [], snapshot: prices,
                                             cacheWriteTTLVerified: capabilities.cacheWriteTTLVerified,
                                             recordsCacheWrites: capabilities.recordsCacheWrites)
    }

    func testFreshnessAtValueTime() throws {
        let burst = [event(start: 0, end: 60, fresh: 1_000), event(start: 70, end: 130, fresh: 1_000)]
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        let newest = t0.addingTimeInterval(130)
        let window = OpenCodeRecentWindow.usage(burst)
        guard case .rate = OpenCodeSessionRate.value(window: window, activity: activity, isWorking: true,
                                                     unit: .tokensPerHour, now: newest.addingTimeInterval(4 * 60)) else {
            return XCTFail("fresh at 4 min")
        }
        XCTAssertEqual(OpenCodeSessionRate.value(window: window, activity: activity, isWorking: true,
                                                 unit: .tokensPerHour, now: newest.addingTimeInterval(6 * 60)),
                       .working)
    }

    func testIdleWins() {
        let burst = [event(start: 0, end: 60, fresh: 1_000), event(start: 70, end: 130, fresh: 1_000)]
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        XCTAssertEqual(OpenCodeSessionRate.value(window: .unavailable, activity: activity, isWorking: false,
                                                 unit: .tokensPerHour, now: t0.addingTimeInterval(140)), .idle)
    }

    func testIdleKeepsFreshRate() {
        let burst = [event(start: 0, end: 60, fresh: 1_000), event(start: 70, end: 130, fresh: 1_000)]
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        let window = OpenCodeRecentWindow.usage(burst)
        let newest = t0.addingTimeInterval(130)
        guard case .idleRecent(.rate(let amount, .tokensPerHour)) = OpenCodeSessionRate.value(
            window: window, activity: activity, isWorking: false, unit: .tokensPerHour,
            now: newest.addingTimeInterval(4 * 60)) else {
            return XCTFail("an idle row keeps the burst's rate while it is fresh")
        }
        XCTAssertEqual(amount, activity.tokensPerHour)
        XCTAssertEqual(OpenCodeSessionRate.value(window: window, activity: activity, isWorking: false,
                                                 unit: .tokensPerHour, now: newest.addingTimeInterval(6 * 60)),
                       .idle, "after the freshness window the row is plain idle")
        XCTAssertEqual(OpenCodeSessionRate.value(window: window, activity: nil, isWorking: false,
                                                 unit: .tokensPerHour, now: newest), .idle,
                       "no burst of at least the minimum span: plain idle")
    }

    func testIdleKeepsFreeAndUnpricedInDollarLens() {
        let free = [event(start: 0, end: 60, fresh: 1_000, model: "minimax-m3.1-flash-free"),
                    event(start: 70, end: 130, fresh: 1_000, model: "minimax-m3.1-flash-free")]
        let freeActivity = OpenCodeSessionRate.activity(burst: free, prices: prices)
        let now = t0.addingTimeInterval(140)
        XCTAssertEqual(OpenCodeSessionRate.value(window: .usage(free), activity: freeActivity, isWorking: false,
                                                 unit: .dollarsPerHour, now: now), .idleRecent(.free))
        let unknown = [event(start: 0, end: 60, fresh: 1_000, model: "no-such-model"),
                       event(start: 70, end: 130, fresh: 1_000, model: "no-such-model")]
        let unknownActivity = OpenCodeSessionRate.activity(burst: unknown, prices: prices)
        guard case .idleRecent(.unpriced) = OpenCodeSessionRate.value(
            window: .usage(unknown), activity: unknownActivity, isWorking: false,
            unit: .dollarsPerHour, now: now) else {
            return XCTFail("an idle unpriced burst keeps its reason")
        }
    }

    func testUnavailableWins() {
        let burst = [event(start: 0, end: 60, fresh: 1_000), event(start: 70, end: 130, fresh: 1_000)]
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        XCTAssertEqual(OpenCodeSessionRate.value(window: .unavailable, activity: activity, isWorking: true,
                                                 unit: .tokensPerHour, now: t0.addingTimeInterval(140)), .unavailable)
    }

    func testLensMapping() {
        XCTAssertEqual(OpenCodeSessionRate.unit(for: .dollar), .dollarsPerHour)
        for presentation in [RunwayPresentation.fiveHour, .weekly, .token] {
            XCTAssertEqual(OpenCodeSessionRate.unit(for: presentation), .tokensPerHour)
        }
        let burst = [event(start: 0, end: 60, fresh: 1_000, model: "minimax-m3.1-flash-free"),
                     event(start: 70, end: 130, fresh: 1_000, model: "minimax-m3.1-flash-free")]
        let activity = OpenCodeSessionRate.activity(burst: burst, prices: prices)
        let now = t0.addingTimeInterval(140)
        XCTAssertEqual(OpenCodeSessionRate.value(window: .usage(burst), activity: activity, isWorking: true,
                                                 unit: .dollarsPerHour, now: now), .free)
        guard case .rate(_, .tokensPerHour) = OpenCodeSessionRate.value(window: .usage(burst), activity: activity,
                                                                        isWorking: true, unit: .tokensPerHour, now: now) else {
            return XCTFail("the token lens shows tk/h even for a free route")
        }
    }

    // MARK: - Task 5: one shared sampler with an ordered demand mailbox

    @MainActor
    func testNoDemandNoIO() async throws {
        let harness = SamplerHarness()
        harness.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(harness.reader.callCount, 0)
    }

    @MainActor
    func testDemandStartsAndNilStops() async throws {
        let harness = SamplerHarness()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount >= 1 }
        harness.store.setDemand(surface, nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        let stopped = harness.reader.callCount
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(harness.reader.callCount, stopped, "no reads once no surface wants rates")
    }

    @MainActor
    func testDisjointSurfacesAllSampled() async throws {
        let harness = SamplerHarness()
        harness.start()
        harness.store.setDemand(UUID(), demand(["a1", "a2", "a3", "a4"]))
        harness.store.setDemand(UUID(), demand(["b1", "b2", "b3", "b4"]))
        try await waitUntil { harness.reader.lastRequestIDs.count == 8 }
        XCTAssertEqual(Set(harness.reader.lastRequestIDs), ["a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4"])
    }

    @MainActor
    func testUpdatesAppliedInCallOrder() async throws {
        let harness = SamplerHarness()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        harness.store.setDemand(surface, nil)
        harness.store.setDemand(surface, demand(["ses_b"]))
        XCTAssertEqual(harness.store.currentDemandRevision, 3)
        try await waitUntil { harness.store.snapshot.values["ses_b"] != nil }
        XCTAssertNil(harness.store.snapshot.values["ses_a"], "the final state is the last call")
        let count = harness.reader.callCount
        try await waitUntil { harness.reader.callCount > count }   // the loop is alive
    }

    @MainActor
    func testHideShowDuringBlockedRead() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount == 1 }
        harness.store.setDemand(surface, nil)
        harness.store.setDemand(surface, demand(["ses_a"]))
        harness.reader.release()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.reader.maxInFlight, 1, "never two reads at once")
        try await waitUntil { harness.store.snapshot.demandRevision == 3 && !harness.store.snapshot.values.isEmpty }
    }

    @MainActor
    func testCollapseExpandDuringBlockedRead() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        let window = UUID(), strip = UUID()
        harness.store.setDemand(window, demand(["ses_w"]))
        harness.store.setDemand(strip, demand(["ses_s"]))
        try await waitUntil { harness.reader.callCount >= 1 }
        harness.store.setDemand(strip, nil)              // strip collapses
        harness.store.setDemand(strip, demand(["ses_s"])) // and expands again
        harness.reader.release()
        try await waitUntil { harness.store.snapshot.values.keys.sorted() == ["ses_s", "ses_w"] }
        XCTAssertEqual(harness.reader.maxInFlight, 1)
    }

    @MainActor
    func testPathChangeDuringBlockedReadDiscardsResult() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        harness.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount == 1 }
        harness.setPath("/tmp/other/opencode.db")
        harness.reader.release()
        try await waitUntil { harness.store.snapshot.databasePath == "/tmp/other/opencode.db" && !harness.store.snapshot.values.isEmpty }
        XCTAssertFalse(harness.published.contains { $0.databasePath == "/tmp/first/opencode.db" && !$0.values.isEmpty },
                       "no values were published under the old path")
    }

    @MainActor
    func testStorePublishRejectsStaleRevisionOrVersion() {
        let store = OpenCodeRateStore()
        store.setDemand(UUID(), demand(["ses_a"]))
        let values: [String: OpenCodeRateValue] = ["ses_a": .working]
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 0, version: 5, values: values))
        XCTAssertEqual(store.snapshot, .empty, "stale demand revision")
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 2, values: values))
        XCTAssertEqual(store.snapshot.version, 2)
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 1, values: [:]))
        XCTAssertEqual(store.snapshot.version, 2, "older version")
    }

    @MainActor
    func testStaleResultNeverEntersCache() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount == 1 }
        harness.store.setDemand(surface, demand(["ses_a"], working: false))  // new revision, same session
        harness.reader.release()
        try await waitUntil { harness.reader.callCount >= 2 }
        XCTAssertEqual(harness.reader.requestLog[1].first?.previousTail, nil,
                       "the discarded result's tail was not cached, so the next read cannot skip")
    }

    @MainActor
    func testLiveRevisionCheckedNotMailboxRevision() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount == 1 }
        // Bump the store's revision; the sampler may not have consumed it yet when the read returns.
        harness.store.setDemand(surface, demand(["ses_a"]))
        harness.reader.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(harness.published.contains { $0.demandRevision == 1 && !$0.values.isEmpty },
                       "a result read under revision 1 is never published")
    }

    @MainActor
    func testOnlyRefreshTaskCallsReader() async throws {
        let harness = SamplerHarness()
        harness.reader.block()
        harness.start()
        let surface = UUID()
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount == 1 }
        for index in 0..<20 { harness.store.setDemand(surface, index.isMultiple(of: 2) ? nil : demand(["ses_a"])) }
        harness.store.setDemand(surface, demand(["ses_a"]))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(harness.reader.callCount, 1, "mailbox bursts start no reads while one is in flight")
        harness.reader.release()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(harness.reader.maxInFlight, 1)
    }

    @MainActor
    func testCachedActivityExpiresAtFreshness() async throws {
        let harness = SamplerHarness()
        let burst = [event(start: 0, end: 60, fresh: 1_000), event(start: 70, end: 130, fresh: 1_000)]
        harness.clock.set(t0.addingTimeInterval(140))
        harness.reader.respond = { requests in
            Dictionary(uniqueKeysWithValues: requests.map { request in
                (request.sessionID, request.previousTail == nil
                    ? OpenCodeRecentUsageResult.loaded(tail: "t1", window: .usage(burst))
                    : .unchanged(tail: "t1"))
            })
        }
        harness.start()
        harness.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil {
            if case .rate = harness.store.snapshot.values["ses_a"] { return true } else { return false }
        }
        harness.clock.set(t0.addingTimeInterval(130 + 6 * 60))
        try await waitUntil { harness.store.snapshot.values["ses_a"] == .working }
    }

    @MainActor
    func testPeriodicForceReloadAfterSixtySeconds() async throws {
        let harness = SamplerHarness()
        harness.clock.set(t0)
        harness.start()
        harness.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount >= 3 }
        XCTAssertTrue(harness.reader.requestLog.dropFirst().allSatisfy { $0.first?.forceReload == false })
        harness.clock.set(t0.addingTimeInterval(61))
        try await waitUntil { harness.reader.requestLog.contains { $0.first?.forceReload == true } }
    }

    @MainActor
    func testUnreadableStoreGivesWorking() async throws {
        let harness = SamplerHarness()
        harness.reader.respond = { _ in nil }
        harness.start()
        harness.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { harness.store.snapshot.values["ses_a"] == .working }
    }

    @MainActor
    func testPriceManifestFetchedOnlyInDollarLens() async throws {
        let token = SamplerHarness(presentation: .token)
        token.start()
        token.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { token.reader.callCount >= 3 }
        XCTAssertEqual(token.priceRefreshCount, 0, "no network in the token lens")
        let dollar = SamplerHarness(presentation: .dollar)
        dollar.start()
        dollar.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { dollar.priceRefreshCount >= 1 }
    }

    @MainActor
    func testFinishedMailboxStopsLoop() async throws {
        let harness = SamplerHarness()
        harness.start()
        harness.store.setDemand(UUID(), demand(["ses_a"]))
        try await waitUntil { harness.reader.callCount >= 1 }
        harness.store.finishUpdates()
        try await Task.sleep(nanoseconds: 40_000_000)
        let stopped = harness.reader.callCount
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(harness.reader.callCount, stopped, "no consumer left: the loop stops")
    }

    @MainActor
    func testIdenticalSnapshotDoesNotNotifyObservers() {
        let store = OpenCodeRateStore()
        store.setDemand(UUID(), demand(["ses_a"]))
        let values: [String: OpenCodeRateValue] = ["ses_a": .rate(10, .tokensPerHour)]
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 1, values: values))
        let notified = LockedFlag()
        withObservationTracking { _ = store.snapshot } onChange: { notified.set() }
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 2, values: values))
        XCTAssertFalse(notified.value, "same values: no redraw")
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 3,
                                           values: ["ses_a": .rate(20, .tokensPerHour)]))
        XCTAssertTrue(notified.value, "changed values redraw")
        store.publish(OpenCodeRateSnapshot(databasePath: "/x", presentation: .token, demandRevision: 1, version: 2, values: [:]))
        XCTAssertEqual(store.snapshot.values["ses_a"], .rate(20, .tokensPerHour), "an older version is still rejected")
    }

    func testCycleWithinBudgetOnLargeStore() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENT_SESSIONS_PERF"] == "1",
                          "set AGENT_SESSIONS_PERF=1 to run the performance gate")
        let bench = try LargeStoreBench()
        let ids = (0..<8).map { "ses_\($0 * 25)" }
        var tails: [String: String] = [:]
        var durations: [TimeInterval] = []
        let opensBefore = OpenCodeSqliteReader.databaseOpenCountForTesting
        for cycle in 0..<30 {
            if cycle.isMultiple(of: 3) { try bench.append(to: ids[cycle % ids.count]) }  // changed tail
            let started = Date()
            let results = try XCTUnwrap(OpenCodeSqliteReader.recentUsage(
                databaseURL: bench.url,
                requests: ids.map { OpenCodeRecentUsageRequest(sessionID: $0, previousTail: tails[$0], forceReload: false) },
                now: bench.now))
            durations.append(Date().timeIntervalSince(started))
            for (id, result) in results {
                switch result {
                case .loaded(let tail, _), .unchanged(let tail): tails[id] = tail
                case .unreadable: XCTFail("unreadable \(id)")
                }
            }
        }
        XCTAssertEqual(OpenCodeSqliteReader.databaseOpenCountForTesting - opensBefore, 30, "exactly one open per cycle")
        let p95 = durations.sorted()[Int(Double(durations.count) * 0.95) - 1]
        print("OpenCode rate cycle p95: \(String(format: "%.2f", p95 * 1000)) ms over \(durations.count) cycles, 8 sessions")
        XCTAssertLessThanOrEqual(p95, 0.025)
    }

    // MARK: - Sampler harness

    private func demand(_ ids: [String], working: Bool = true) -> OpenCodeRateDemand {
        OpenCodeRateDemand(sessions: Dictionary(uniqueKeysWithValues: ids.map { ($0, working) }))
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met within \(timeout) s") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: - Fixture

    private struct TestEvent {
        let start: Date
        let end: Date
        func event(fresh: Int, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
                   model: String = "gpt-5", context: Int? = nil, id: String? = nil) -> TelemetryUsageEvent {
            TelemetryUsageEvent(recordID: id ?? UUID().uuidString, observedAt: start, anchorLine: 0,
                                usageFamily: "opencode.step-finish.tokens", ownership: .session,
                                model: model, reasoningEffort: nil, speed: "standard-normalized",
                                freshInputTokens: fresh, cacheReadTokens: cacheRead,
                                cacheWrite5mTokens: cacheWrite, cacheWrite1hTokens: 0,
                                outputTokens: output, reasoningOutputTokens: 0,
                                contextInputTokens: context ?? (fresh + cacheRead + cacheWrite),
                                completedAt: end)
        }
    }

    private func event(start: TimeInterval, end: TimeInterval, fresh: Int, output: Int = 0, cacheRead: Int = 0,
                       cacheWrite: Int = 0, model: String = "gpt-5", context: Int? = nil,
                       id: String? = nil) -> TelemetryUsageEvent {
        TestEvent(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end))
            .event(fresh: fresh, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                   model: model, context: context, id: id)
    }

    private func estimate() -> TelemetryCostEstimate {
        TelemetryCostCalculator.price(events: [], fallbackSlices: [], snapshot: prices).estimate
    }
}

/// A store and sampler wired to a fake reader, a settable clock and a settable path.
@MainActor
private final class SamplerHarness {
    /// Every started harness, so tearDown can stop its sampler loop.
    static var started: [SamplerHarness] = []

    let store = OpenCodeRateStore()
    let reader = FakeRecentReader()
    let clock = TestClock()
    private let path = LockedValue("/tmp/first/opencode.db")
    private let presentation: RunwayPresentation
    private let refreshes = LockedCounter()
    private(set) var published: [OpenCodeRateSnapshot] = []
    private var runTask: Task<Void, Never>?

    init(presentation: RunwayPresentation = .token) { self.presentation = presentation }

    var priceRefreshCount: Int { refreshes.value }
    func setPath(_ value: String) { path.set(value) }

    func start() {
        let presentation = self.presentation
        let refreshes = self.refreshes
        let sampler = OpenCodeRateSampler(
            store: store, reader: reader,
            clock: { [clock] in clock.now },
            databaseURL: { [path] in URL(fileURLWithPath: path.value) },
            presentation: { presentation },
            prices: { RunwayPriceTable.makeForTesting().snapshot() },
            refreshPrices: { refreshes.increment() },
            cadence: 0.002)
        store.onPublishForTesting = { [weak self] snapshot in self?.published.append(snapshot) }
        let updates = store.updates
        runTask = Task { await sampler.run(updates: updates) }
        Self.started.append(self)
    }

    /// Ends the mailbox, which stops the sampler loop.
    func stop() {
        store.finishUpdates()
        runTask?.cancel()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class FakeRecentReader: OpenCodeRecentUsageReading, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[OpenCodeRecentUsageRequest]] = []
    private var inFlight = 0
    private var maxInFlightValue = 0
    private var gate: DispatchSemaphore?
    private var respondValue: ([OpenCodeRecentUsageRequest]) -> [String: OpenCodeRecentUsageResult]? = { requests in
        Dictionary(uniqueKeysWithValues: requests.map { ($0.sessionID, .loaded(tail: "t1", window: .noCompletedUsage)) })
    }

    var respond: ([OpenCodeRecentUsageRequest]) -> [String: OpenCodeRecentUsageResult]? {
        get { lock.withLock { respondValue } }
        set { lock.withLock { respondValue = newValue } }
    }
    var callCount: Int { lock.withLock { log.count } }
    var requestLog: [[OpenCodeRecentUsageRequest]] { lock.withLock { log } }
    var lastRequestIDs: [String] { lock.withLock { log.last?.map(\.sessionID) ?? [] } }
    var maxInFlight: Int { lock.withLock { maxInFlightValue } }

    /// The next read blocks until `release()`.
    func block() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
    func release() {
        let waiting = lock.withLock { () -> DispatchSemaphore? in defer { gate = nil }; return gate }
        waiting?.signal()
    }

    func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest],
                     now: Date) -> [String: OpenCodeRecentUsageResult]? {
        let waiting = lock.withLock { () -> DispatchSemaphore? in
            log.append(requests)
            inFlight += 1
            maxInFlightValue = max(maxInFlightValue, inFlight)
            return gate
        }
        waiting?.wait()
        let responder = lock.withLock { () -> ([OpenCodeRecentUsageRequest]) -> [String: OpenCodeRecentUsageResult]? in
            inFlight -= 1
            return respondValue
        }
        return responder(requests)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}

/// 50 000 `session_message` rows over 200 sessions in the vendor schema, WAL mode.
/// Each session's newest 30 rows fall inside the 2-hour window.
private final class LargeStoreBench {
    let directory: URL
    let url: URL
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var writer: OpaquePointer?
    private var nextSeq: [String: Int] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCodeRateBench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("opencode.db")
        guard sqlite3_open(url.path, &writer) == SQLITE_OK else { throw NSError(domain: "bench", code: 1) }
        try exec("PRAGMA journal_mode=WAL;")
        try exec(OpenCodeVendorSchemaFixture.ddl)
        try exec("BEGIN;")
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        for session in 0..<200 {
            let id = "ses_\(session)"
            try exec("INSERT INTO session_v2 (id, project_id, slug, directory, title, version, time_created, time_updated) VALUES ('\(id)', 'p', 's', '/tmp', 't', '2.1.4', \(nowMillis - 86_400_000), \(nowMillis));")
            for row in 0..<250 {
                let age = row >= 220 ? Int64(250 - row) * 180_000 : Int64(250 - row) * 600_000 + 7_200_000
                try insert(session: id, seq: row, start: nowMillis - age)
            }
            nextSeq[id] = 250
        }
        try exec("COMMIT;")
    }

    deinit {
        sqlite3_close(writer)
        try? FileManager.default.removeItem(at: directory)
    }

    func append(to session: String) throws {
        let seq = nextSeq[session, default: 250]
        nextSeq[session] = seq + 1
        try insert(session: session, seq: seq, start: Int64(now.timeIntervalSince1970 * 1000) - 30_000)
    }

    private func insert(session: String, seq: Int, start: Int64) throws {
        let data = #"{"time":{"created":\#(start),"completed":\#(start + 20_000)},"agent":"build","model":{"id":"gpt-5","providerID":"p"},"content":[{"type":"text","text":"\#(String(repeating: "x", count: 400))"}],"finish":"stop","tokens":{"input":1200,"output":300,"reasoning":40,"cache":{"read":9000,"write":0}}}"#
        try exec("INSERT INTO session_message VALUES ('\(session)_\(seq)', '\(session)', 'assistant', \(seq), \(start), \(start + 20_000), '\(data)');")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(writer))])
        }
    }
}
