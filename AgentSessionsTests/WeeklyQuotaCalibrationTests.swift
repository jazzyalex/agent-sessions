import XCTest
@testable import AgentSessions

/// Covers the calibration acceptance rules and the activity ledger. These are the
/// guards that make `Wk` an honest estimate rather than a plausible-looking number.
final class WeeklyQuotaCalibrationTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func scope(priceRevision: Int = 1,
                       account: String? = "acct-1",
                       source: String = "oauth",
                       shape: String = "5h+weekly") -> WeeklyQuotaCalibrationScope {
        WeeklyQuotaCalibrationScope(
            provider: "codex",
            accountHash: WeeklyQuotaCalibrationScope.hashAccount(account),
            sourceFamily: source,
            limitShape: shape,
            priceRevision: priceRevision
        )
    }

    /// Bank `dollarsWorth` of priced output tokens across the interval, one bucket
    /// per minute so poll continuity holds.
    private func fillLedger(_ ledger: WeeklyQuotaActivityLedger,
                            from: Date,
                            minutes: Int,
                            outputTokensPerMinute: Double,
                            model: String? = "gpt-5.6") {
        let prices = RunwayPriceTable.makeForTesting()
        var cumulative = 0.0
        for i in 0...minutes {
            let at = from.addingTimeInterval(Double(i) * 60)
            ledger.record(observations: [
                WeeklyQuotaTokenObservation(logPath: "/s1", capturedAt: at, input: 0,
                                            cachedInput: 0, output: cumulative,
                                            cacheCreation: 0, modelSlug: model)
            ], priceTable: prices, now: at)
            cumulative += outputTokensPerMinute
        }
    }

    // MARK: - Ledger

    /// The reason the ledger exists: a session that burns and then ENDS must stay
    /// in the denominator, or the calibration is inflated and every surviving row
    /// is overstated.
    func testLedgerKeepsActivityFromSessionsThatEnded() {
        let ledger = WeeklyQuotaActivityLedger()
        let prices = RunwayPriceTable.makeForTesting()
        // Two cycles of a session that then disappears entirely.
        ledger.record(observations: [
            WeeklyQuotaTokenObservation(logPath: "/gone", capturedAt: t0, input: 0, cachedInput: 0,
                                        output: 0, cacheCreation: 0, modelSlug: "gpt-5.6")
        ], priceTable: prices, now: t0)
        ledger.record(observations: [
            WeeklyQuotaTokenObservation(logPath: "/gone", capturedAt: t0.addingTimeInterval(60),
                                        input: 0, cachedInput: 0, output: 1_000_000,
                                        cacheCreation: 0, modelSlug: "gpt-5.6")
        ], priceTable: prices, now: t0.addingTimeInterval(60))
        // Session is gone from here on; later cycles see nothing.
        ledger.record(observations: [], priceTable: prices, now: t0.addingTimeInterval(120))

        let activity = ledger.activity(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(120))
        // 1M output tokens of gpt-5.6 at $20/MTok.
        XCTAssertEqual(activity?.dollars ?? 0, 20.0, accuracy: 0.001)
    }

    func testLedgerFirstSightingBanksNothing() {
        let ledger = WeeklyQuotaActivityLedger()
        ledger.record(observations: [
            WeeklyQuotaTokenObservation(logPath: "/s", capturedAt: t0, input: 0, cachedInput: 0,
                                        output: 5_000_000, cacheCreation: 0, modelSlug: "gpt-5.6")
        ], priceTable: RunwayPriceTable.makeForTesting(), now: t0)
        XCTAssertEqual(ledger.activity(from: t0.addingTimeInterval(-1), to: t0)?.dollars ?? -1, 0)
    }

    func testLedgerFlagsUnpricedActivity() {
        let ledger = WeeklyQuotaActivityLedger()
        let prices = RunwayPriceTable.makeForTesting()
        for (i, total) in [0.0, 1_000_000.0].enumerated() {
            let at = t0.addingTimeInterval(Double(i) * 60)
            ledger.record(observations: [
                WeeklyQuotaTokenObservation(logPath: "/s", capturedAt: at, input: 0, cachedInput: 0,
                                            output: total, cacheCreation: 0,
                                            modelSlug: "no-such-model-xyz")
            ], priceTable: prices, now: at)
        }
        let activity = ledger.activity(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(60))
        XCTAssertTrue(activity?.hadUnpriced ?? false)
        XCTAssertEqual(activity?.dollars ?? -1, 0)
    }

    func testLedgerIncrementalPathDedupesRepeatedEvents() {
        let ledger = WeeklyQuotaActivityLedger()
        let prices = RunwayPriceTable.makeForTesting()
        let event = WeeklyQuotaTokenEvent(logPath: "/c", capturedAt: t0, input: 0, cachedInput: 0,
                                          output: 1_000_000, cacheCreation: 0,
                                          modelSlug: "claude-sonnet-5")
        // The parser re-reads an overlapping tail every cycle; the same event must
        // only ever be banked once.
        ledger.recordIncremental(events: [event], priceTable: prices, now: t0)
        ledger.recordIncremental(events: [event], priceTable: prices, now: t0.addingTimeInterval(60))
        let once = ledger.activity(from: t0.addingTimeInterval(-1), to: t0)?.dollars ?? 0
        let twice = ledger.activity(from: t0.addingTimeInterval(-1), to: t0.addingTimeInterval(60))?.dollars ?? 0
        XCTAssertGreaterThan(once, 0)
        XCTAssertEqual(once, twice, accuracy: 0.0001)
    }

    // MARK: - Tracker acceptance

    /// Acceptance test 3: one valid matched interval produces a calibration.
    func testAcceptsOneValidInterval() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)

        XCTAssertNil(tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                                    observedAt: t0, scope: scope(), ledger: ledger, now: t0))
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        // 1M output tokens over the interval = $20; a 1pp drop → 0.05 pp/$.
        let accepted = tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                      observedAt: end, scope: scope(), ledger: ledger, now: end)
        XCTAssertNotNil(accepted)
        XCTAssertEqual(tracker.percentPointsPerDollar(now: end) ?? 0, 0.05, accuracy: 0.005)
    }

    /// Acceptance test 1's real enabler: a >30-minute interval must still be
    /// accepted. Under the old burn-rate cap this was rejected, which is why
    /// Codex could never calibrate on an ordinary day.
    func testAcceptsIntervalLongerThanThirtyMinutes() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 90, outputTokensPerMinute: 20_000)
        let end = t0.addingTimeInterval(90 * 60)
        XCTAssertNotNil(tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                       observedAt: end, scope: scope(), ledger: ledger, now: end))
    }

    /// Acceptance test 7: a quota drop with no local activity is somebody else's
    /// usage and must never become a calibration.
    func testRejectsDropWithNoLocalActivity() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 0)
        let end = t0.addingTimeInterval(10 * 60)
        XCTAssertNil(tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                    observedAt: end, scope: scope(), ledger: ledger, now: end))
        XCTAssertNil(tracker.percentPointsPerDollar(now: end))
    }

    /// Acceptance test 8: unpriced material activity rejects the whole interval
    /// rather than being quietly excluded from the denominator.
    func testRejectsIntervalContainingUnpricedActivity() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000,
                   model: "no-such-model-xyz")
        let end = t0.addingTimeInterval(10 * 60)
        XCTAssertNil(tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                    observedAt: end, scope: scope(), ledger: ledger, now: end))
    }

    /// Acceptance test 10: a sleep-sized gap re-anchors and learns nothing.
    func testRejectsIntervalWithSleepSizedPollGap() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let prices = RunwayPriceTable.makeForTesting()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        // Two observations 40 minutes apart: real activity, but we were not watching
        // in between, so the denominator cannot be trusted.
        ledger.record(observations: [
            WeeklyQuotaTokenObservation(logPath: "/s", capturedAt: t0, input: 0, cachedInput: 0,
                                        output: 0, cacheCreation: 0, modelSlug: "gpt-5.6")
        ], priceTable: prices, now: t0.addingTimeInterval(30))
        let end = t0.addingTimeInterval(40 * 60)
        ledger.record(observations: [
            WeeklyQuotaTokenObservation(logPath: "/s", capturedAt: end, input: 0, cachedInput: 0,
                                        output: 1_000_000, cacheCreation: 0, modelSlug: "gpt-5.6")
        ], priceTable: prices, now: end)
        XCTAssertNil(tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                    observedAt: end, scope: scope(), ledger: ledger, now: end))
    }

    /// A sub-quantum drop is rounding noise on an integer-percent provider.
    func testRejectsDropBelowProviderQuantum() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        XCTAssertNil(tracker.update(remainingPercent: 79.5, hasExactPercent: false, resetAt: reset,
                                    observedAt: end, scope: scope(), ledger: ledger, now: end))
        // The same drop IS acceptable when the provider reports fractional percent.
        var exact = WeeklyQuotaCalibrationTracker()
        exact.update(remainingPercent: 80, hasExactPercent: true, resetAt: reset,
                     observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        XCTAssertNotNil(exact.update(remainingPercent: 79.5, hasExactPercent: true, resetAt: reset,
                                     observedAt: end, scope: scope(), ledger: ledger, now: end))
    }

    /// Acceptance test 9: a price revision (or account/source/shape change)
    /// invalidates — the learned pp-per-dollar no longer means the same thing.
    func testScopeChangeInvalidates() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        XCTAssertNotNil(tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                                       observedAt: end, scope: scope(), ledger: ledger, now: end))
        XCTAssertNotNil(tracker.percentPointsPerDollar(now: end))

        tracker.update(remainingPercent: 78, hasExactPercent: false, resetAt: reset,
                       observedAt: end.addingTimeInterval(60), scope: scope(priceRevision: 2),
                       ledger: ledger, now: end.addingTimeInterval(60))
        XCTAssertNil(tracker.percentPointsPerDollar(now: end.addingTimeInterval(60)),
                     "a re-priced table must invalidate the learned conversion")
    }

    /// A weekly reset re-anchors the counter but must NOT erase a valid conversion.
    func testWeeklyResetKeepsLearnedConversion() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                       observedAt: end, scope: scope(), ledger: ledger, now: end)
        let learned = tracker.percentPointsPerDollar(now: end)

        let newReset = reset.addingTimeInterval(7 * 24 * 3600)
        tracker.update(remainingPercent: 100, hasExactPercent: false, resetAt: newReset,
                       observedAt: end.addingTimeInterval(60), scope: scope(),
                       ledger: ledger, now: end.addingTimeInterval(60))
        XCTAssertEqual(tracker.percentPointsPerDollar(now: end.addingTimeInterval(60)), learned)
    }

    // MARK: - Persistence

    /// Acceptance tests 11 and 12: a scoped calibration survives a restart; an
    /// unscoped one (Claude) never does.
    func testOnlyScopedCalibrationSurvivesRestart() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                       observedAt: end, scope: scope(), ledger: ledger, now: end)

        let data = tracker.persistedData()
        XCTAssertNotNil(data)
        var restored = WeeklyQuotaCalibrationTracker()
        restored.restore(from: data!, scope: scope(), now: end)
        XCTAssertEqual(restored.percentPointsPerDollar(now: end),
                       tracker.percentPointsPerDollar(now: end))

        // A different account must not adopt it.
        var otherAccount = WeeklyQuotaCalibrationTracker()
        otherAccount.restore(from: data!, scope: scope(account: "acct-2"), now: end)
        XCTAssertNil(otherAccount.percentPointsPerDollar(now: end))
    }

    func testUnscopedCalibrationIsNeverPersisted() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        let unscoped = WeeklyQuotaCalibrationScope(provider: "claude", accountHash: nil,
                                                   sourceFamily: "oauth", limitShape: "weekly",
                                                   priceRevision: 1)
        tracker.update(remainingPercent: 80, hasExactPercent: true, resetAt: reset,
                       observedAt: t0, scope: unscoped, ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        tracker.update(remainingPercent: 79, hasExactPercent: true, resetAt: reset,
                       observedAt: end, scope: unscoped, ledger: ledger, now: end)
        XCTAssertNotNil(tracker.percentPointsPerDollar(now: end), "it still works in memory")
        XCTAssertNil(tracker.persistedData(), "but it must never reach disk")
    }

    /// The waiting clock must be bounded, and the budget runs from APP LAUNCH.
    /// Uses a private store: `.shared` carries a launch timestamp from whenever
    /// the first test touched it, which made an earlier version of this test pass
    /// alone and fail in the suite.
    func testWaitingBudgetGivesUpAfterOneMinute() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        XCTAssertFalse(store.calibrationAbandoned(provider: "codex", now: t0.addingTimeInterval(5)))
        XCTAssertTrue(store.calibrationAbandoned(
            provider: "codex",
            now: t0.addingTimeInterval(WeeklyQuotaCalibrationStore.waitingBudget + 5)))
    }

    /// A bootstrap answers the question, so the budget must stop applying.
    func testBootstrapStopsTheWaitingBudget() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.setBootstrapForTesting(provider: "codex", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 20, dollars: 100, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: t0.addingTimeInterval(604_800), scannedAt: t0))
        XCTAssertFalse(store.calibrationAbandoned(
            provider: "codex",
            now: t0.addingTimeInterval(WeeklyQuotaCalibrationStore.waitingBudget + 600)))
        XCTAssertEqual(store.percentPointsPerDollar(provider: "codex", now: t0) ?? 0,
                       0.2, accuracy: 0.0001)
    }

    /// A frozen bootstrap drifts high: the numerator is integer-quantized and sits
    /// still for hours while real spending accrues. Measured on a live account
    /// this was a 43% overestimate, so the denominator must track the ledger.
    func testBootstrapDenominatorTracksOngoingSpend() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        let scannedAt = t0
        store.setBootstrapForTesting(provider: "codex", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 2, dollars: 20, unpricedVolumeShare: 0,
            windowStart: t0.addingTimeInterval(-3600), resetsAt: t0.addingTimeInterval(604_800),
            scannedAt: scannedAt))
        // Same window, same integer percent, but $10 more has been spent since.
        let ledger = store.ledger(provider: "codex")
        let prices = RunwayPriceTable.makeForTesting()
        for (i, cumulative) in [0.0, 500_000.0].enumerated() {
            let at = scannedAt.addingTimeInterval(Double(i) * 60)
            ledger.record(observations: [
                WeeklyQuotaTokenObservation(logPath: "/s", capturedAt: at, input: 0, cachedInput: 0,
                                            output: cumulative, cacheCreation: 0, modelSlug: "gpt-5.6")
            ], priceTable: prices, now: at)
        }
        store.recordUsedPercentForTesting(provider: "codex", usedPercentPoints: 2)

        let now = scannedAt.addingTimeInterval(120)
        let served = store.percentPointsPerDollar(provider: "codex", now: now) ?? 0
        // 500k output tokens of gpt-5.6 at $20/MTok = $10, so the denominator is
        // $30 rather than the scanned $20. Numerator is the quantization midpoint.
        XCTAssertEqual(served, 2.5 / 30.0, accuracy: 0.001)
        XCTAssertLessThan(served, 2.5 / 20.0, "a frozen denominator overestimates the burn")
    }

    /// A ratio from a completed 72pp week is stable to a few percent; one from a
    /// 2pp sliver swings by more than 2x inside a single integer quantum. Trust
    /// the larger numerator, whichever window it came from.
    func testPrefersTheBetterConditionedMeasurement() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        let lastWeek = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 72, dollars: 1073, unpricedVolumeShare: 0,
            windowStart: t0.addingTimeInterval(-604_800), resetsAt: t0, scannedAt: t0)
        let thisWeek = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 2, dollars: 28, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: t0.addingTimeInterval(604_800), scannedAt: t0)
        store.setBestBootstrapForTesting(provider: "claude", result: lastWeek)
        store.setBootstrapForTesting(provider: "claude", result: thisWeek)

        // The 2pp sliver must not displace the 72pp week.
        let served = store.percentPointsPerDollar(provider: "claude", now: t0) ?? 0
        XCTAssertEqual(served, 72.0 / 1073.0, accuracy: 0.002)
    }

    /// A weekly reset leaves the new window with nothing to divide by; the plan's
    /// conversion has not changed, so the prior measurement must carry over.
    func testCalibrationSurvivesAWeeklyReset() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.setBestBootstrapForTesting(provider: "claude", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 72, dollars: 1073, unpricedVolumeShare: 0,
            windowStart: t0.addingTimeInterval(-604_800), resetsAt: t0, scannedAt: t0))
        // Fresh window: no current bootstrap at all.
        XCTAssertNotNil(store.percentPointsPerDollar(provider: "claude", now: t0))
        XCTAssertFalse(store.calibrationAbandoned(
            provider: "claude",
            now: t0.addingTimeInterval(WeeklyQuotaCalibrationStore.waitingBudget + 60)))
    }

    /// The reported integer is a floor, so the midpoint is the unbiased estimate.
    func testUsesQuantizationMidpointForTheNumerator() {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.setBootstrapForTesting(provider: "codex", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 2, dollars: 20, unpricedVolumeShare: 0,
            windowStart: t0.addingTimeInterval(-3600), resetsAt: t0.addingTimeInterval(604_800),
            scannedAt: t0))
        store.recordUsedPercentForTesting(provider: "codex", usedPercentPoints: 2)
        // A bucket strictly after `scannedAt`, carrying no new spend: the
        // denominator stays $20 so this isolates the numerator.
        let ledger = store.ledger(provider: "codex")
        ledger.record(observations: [], priceTable: RunwayPriceTable.makeForTesting(),
                      now: t0.addingTimeInterval(10))
        let served = store.percentPointsPerDollar(provider: "codex", now: t0.addingTimeInterval(30)) ?? 0
        XCTAssertEqual(served, 2.5 / 20.0, accuracy: 0.0001, "reported 2 means [2,3), so use 2.5")
    }

    /// Promotion must happen on RESTORE as well as after a scan: a launch that
    /// restores from cache never scans, and without promotion the carry-over slot
    /// stays empty until one happens to run.
    func testRestoredBootstrapPopulatesTheCarryOverSlot() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wkpromo-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let resetsAt = t0.addingTimeInterval(604_800)
        let anchorKey = "quotaMeter.weeklyBootstrap.codex.unscoped.\(Int(resetsAt.timeIntervalSince1970))"
        suite.set(try JSONEncoder().encode(WeeklyQuotaBootstrapResult(
            usedPercentPoints: 40, dollars: 500, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: resetsAt, scannedAt: t0)), forKey: anchorKey)

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 40, now: t0, defaults: suite)
        XCTAssertNotNil(suite.data(forKey: "quotaMeter.weeklyBootstrapBest.codex.unscoped"),
                        "a restored bootstrap must populate the cross-reset carry-over")
    }

    /// The carry-over must survive a RESTART, not just stay in memory: the stored
    /// entry is anchor-keyed, so a reset orphans it and a relaunched app would
    /// otherwise face a fresh window with ~0% consumed and nothing to divide by.
    func testBestCalibrationSurvivesRestartAcrossAWeeklyReset() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wkbest-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let oldWindowReset = t0
        let newWindowReset = t0.addingTimeInterval(604_800)

        // Session 1: a full week measured, then the window rolls over.
        let first = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        first.setBestBootstrapForTesting(provider: "claude", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 72, dollars: 1073, unpricedVolumeShare: 0,
            windowStart: oldWindowReset.addingTimeInterval(-604_800), resetsAt: oldWindowReset,
            scannedAt: oldWindowReset))
        suite.set(try JSONEncoder().encode(WeeklyQuotaBootstrapResult(
            usedPercentPoints: 72, dollars: 1073, unpricedVolumeShare: 0,
            windowStart: oldWindowReset.addingTimeInterval(-604_800), resetsAt: oldWindowReset,
            scannedAt: oldWindowReset)), forKey: "quotaMeter.weeklyBootstrapBest.claude.unscoped")

        // Session 2: fresh process, brand-new window, nothing consumed yet.
        let second = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: newWindowReset)
        second.ensureBootstrap(provider: "claude",
                               root: URL(fileURLWithPath: "/nonexistent"),
                               resetsAt: newWindowReset,
                               windowMinutes: 10080,
                               usedPercentPoints: 0,
                               now: newWindowReset,
                               defaults: suite)
        XCTAssertEqual(second.percentPointsPerDollar(provider: "claude", now: newWindowReset) ?? 0,
                       72.0 / 1073.0, accuracy: 0.002,
                       "the plan's conversion must outlive the window it was measured in")
        XCTAssertFalse(second.calibrationAbandoned(
            provider: "claude",
            now: newWindowReset.addingTimeInterval(WeeklyQuotaCalibrationStore.waitingBudget + 60)))
    }

    /// Two private stores must not see each other's state — the property that
    /// makes `makeForTesting()` safe to use without any reset dance.
    func testPrivateStoresAreIsolated() {
        let a = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        let b = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        a.setBootstrapForTesting(provider: "codex", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 20, dollars: 100, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: t0.addingTimeInterval(604_800), scannedAt: t0))
        XCTAssertNotNil(a.percentPointsPerDollar(provider: "codex", now: t0))
        XCTAssertNil(b.percentPointsPerDollar(provider: "codex", now: t0))
    }

    /// Persistence must round-trip through an injected defaults suite, never the
    /// app's real domain.
    func testBootstrapPersistsAndRestoresWithoutRescanning() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wkcal-test-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let resetsAt = t0.addingTimeInterval(604_800)
        let stored = WeeklyQuotaBootstrapResult(
            usedPercentPoints: 20, dollars: 100, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: resetsAt, scannedAt: t0)
        let key = "quotaMeter.weeklyBootstrap.codex.unscoped.\(Int(resetsAt.timeIntervalSince1970))"
        suite.set(try JSONEncoder().encode(stored), forKey: key)

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        // A sub-second difference in the reset instant must still match: the
        // provider reports it with a varying fractional part, and an exact Double
        // compare made every launch rescan hundreds of megabytes.
        store.ensureBootstrap(provider: "codex",
                              root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt.addingTimeInterval(0.24),
                              windowMinutes: 10080,
                              usedPercentPoints: 20,
                              now: t0,
                              defaults: suite)
        XCTAssertEqual(store.percentPointsPerDollar(provider: "codex", now: t0) ?? 0,
                       0.2, accuracy: 0.0001)
    }

    func testCalibrationExpiresAfterSevenDays() {
        var tracker = WeeklyQuotaCalibrationTracker()
        let ledger = WeeklyQuotaActivityLedger()
        let reset = t0.addingTimeInterval(4 * 24 * 3600)
        tracker.update(remainingPercent: 80, hasExactPercent: false, resetAt: reset,
                       observedAt: t0, scope: scope(), ledger: ledger, now: t0)
        fillLedger(ledger, from: t0, minutes: 10, outputTokensPerMinute: 100_000)
        let end = t0.addingTimeInterval(10 * 60)
        tracker.update(remainingPercent: 79, hasExactPercent: false, resetAt: reset,
                       observedAt: end, scope: scope(), ledger: ledger, now: end)
        XCTAssertNotNil(tracker.percentPointsPerDollar(now: end))
        XCTAssertNil(tracker.percentPointsPerDollar(now: end.addingTimeInterval(8 * 24 * 3600)))
    }
}

/// The `Wk` display contract. These are the rules that keep the row honest: an
/// estimate with no calibration must not look like a measured zero, and an
/// integer format must not round a real burn down to "0%/h".
final class WeeklyQuotaDisplayTests: XCTestCase {

    private func weekly(_ v: Double, _ c: RunwayAttributionConfidence = .mixed) -> String {
        RunwayRateTextTestHook.text(v, unit: .weeklyPercentPerHour, confidence: c)
    }

    /// Acceptance test 2: waiting is never "0%/h". (The cell renders a clock; this
    /// string is the accessibility fallback.)
    func testWaitingIsNotAMeasuredZero() {
        XCTAssertEqual(weekly(0, .waiting), "measuring")
        XCTAssertNotEqual(weekly(0, .waiting), "0%/h")
    }

    /// Acceptance test 16: below the floor it reads "quiet", never a rounded-down
    /// "0%/h" — a real burn must never be displayed as a measured zero.
    func testSubThresholdRatesReadFlatNotZero() {
        for value in [0.0, 0.01, 0.049] {
            XCTAssertEqual(weekly(value), "quiet", "\(value) must not render as a number")
        }
        XCTAssertEqual(weekly(0.05), "0.1%/h")
        XCTAssertNotEqual(weekly(0.05), "0.0%/h")
    }

    /// One decimal below 10, integer at and above. Weekly rates cluster at 0-3%/h,
    /// so integer-only formatting made every session read "quiet" or "1%/h" and the
    /// column stopped ranking anything.
    func testNumericFormatKeepsResolutionAtWeeklyScale() {
        XCTAssertEqual(weekly(0.8), "0.8%/h")
        XCTAssertEqual(weekly(1.4), "1.4%/h")
        XCTAssertEqual(weekly(3.2), "3.2%/h")
        XCTAssertEqual(weekly(9.9), "9.9%/h")
        // No decimals once the number is big enough not to need them.
        XCTAssertEqual(weekly(10), "10%/h")
        XCTAssertEqual(weekly(12.4), "12%/h")
        XCTAssertEqual(weekly(100), "100%/h")
        // No tilde anywhere, and the /h suffix always survives so the row can't be
        // misread as the "Wk: 89%" remaining figure above it.
        XCTAssertFalse(weekly(1.4).contains("~"))
        XCTAssertTrue(weekly(1.4).hasSuffix("%/h"))
    }

    /// Acceptance test 17: a contaminated calibration reads "n/a", not digit soup.
    func testUnestimableAndAbsurdRatesReadNA() {
        XCTAssertEqual(weekly(0, .unsupported), "n/a")
        XCTAssertEqual(weekly(5000), "n/a")
    }

    func testIdleAndCloudUnchanged() {
        XCTAssertEqual(weekly(0, .idle), "idle")
        XCTAssertEqual(weekly(42, .cloud), "Cloud")
    }

    /// Acceptance test 14: the other three units are untouched.
    func testOtherUnitsUnchanged() {
        XCTAssertEqual(RunwayRateTextTestHook.text(137, unit: .quotaMinutesPerHour), "137m/h")
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .quotaMinutesPerHour, confidence: .waiting), "0m/h")
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .tokensPerHour, confidence: .waiting), "0 tk/h")
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .dollarsPerHour, confidence: .waiting), "$0/h")
    }
}

/// The weekly row must not flicker between a number and "quiet" just because a
/// provider went a few seconds without writing a usage record.
final class WeeklyRateHoldTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private func snapshot(rate: Double,
                          confidence: RunwayAttributionConfidence) -> CodexRunwaySnapshot {
        CodexRunwaySnapshot(
            baseline: RunwayProviderBaseline(
                source: .claude, remainingPercent: 80, resetAt: t0.addingTimeInterval(604_800),
                currentRunoutAt: t0.addingTimeInterval(86_400), observedAt: t0,
                windowMinutes: 10080, rateUnit: .weeklyPercentPerHour),
            rows: [RunwayPauseImpactRow(id: "s1", displayName: "S1", isGoal: false,
                                        deadline: .unavailable, gainedSeconds: 0,
                                        displayRate: rate, confidence: confidence)],
            burstSummary: nil)
    }

    func testBridgesAShortGapInUsageRecords() {
        let hold = RunwayWeeklyRateHold()
        _ = RunwaySnapshotAssembly.withWeeklyRateHold(snapshot(rate: 5, confidence: .direct),
                                                      hold: hold, now: t0)
        // Provider goes quiet mid-turn: the row would otherwise read "quiet".
        let bridged = RunwaySnapshotAssembly.withWeeklyRateHold(
            snapshot(rate: 0, confidence: .direct), hold: hold, now: t0.addingTimeInterval(40))
        XCTAssertEqual(bridged?.rows.first?.displayRate ?? 0, 5, accuracy: 0.0001)
    }

    func testStopsHoldingOnceTheSessionGenuinelyStops() {
        let hold = RunwayWeeklyRateHold()
        _ = RunwaySnapshotAssembly.withWeeklyRateHold(snapshot(rate: 5, confidence: .direct),
                                                      hold: hold, now: t0)
        let expired = RunwaySnapshotAssembly.withWeeklyRateHold(
            snapshot(rate: 0, confidence: .direct),
            hold: hold,
            now: t0.addingTimeInterval(RunwayWeeklyRateHold.window + 10))
        XCTAssertEqual(expired?.rows.first?.displayRate ?? -1, 0)
    }

    /// A finished or unestimable session is stating something definite; the hold
    /// must never paper over it with a stale number.
    func testDoesNotOverrideIdleOrUnavailableRows() {
        let hold = RunwayWeeklyRateHold()
        _ = RunwaySnapshotAssembly.withWeeklyRateHold(snapshot(rate: 5, confidence: .direct),
                                                      hold: hold, now: t0)
        for confidence in [RunwayAttributionConfidence.idle, .unsupported, .waiting] {
            let result = RunwaySnapshotAssembly.withWeeklyRateHold(
                snapshot(rate: 0, confidence: confidence), hold: hold, now: t0.addingTimeInterval(10))
            XCTAssertEqual(result?.rows.first?.displayRate ?? -1, 0, "\(confidence) must stay as-is")
            XCTAssertEqual(result?.rows.first?.confidence, confidence)
        }
    }

    /// Other units share the assembly path and must be untouched.
    func testLeavesNonWeeklySnapshotsAlone() {
        let hold = RunwayWeeklyRateHold()
        let tokens = CodexRunwaySnapshot(
            baseline: RunwayProviderBaseline(
                source: .codex, remainingPercent: 80, resetAt: t0.addingTimeInterval(604_800),
                currentRunoutAt: t0.addingTimeInterval(86_400), observedAt: t0,
                windowMinutes: 300, rateUnit: .tokensPerHour),
            rows: [RunwayPauseImpactRow(id: "s1", displayName: "S1", isGoal: false,
                                        deadline: .unavailable, gainedSeconds: 0,
                                        displayRate: 0, confidence: .direct)],
            burstSummary: nil)
        let result = RunwaySnapshotAssembly.withWeeklyRateHold(tokens, hold: hold, now: t0)
        XCTAssertEqual(result?.rows.first?.displayRate ?? -1, 0)
    }
}

/// "quiet" replaced "flat" in every unit: a live session spending nothing right
/// now, distinct from "—" (finished) and the measuring clock (no calibration).
final class RunwayQuietLabelTests: XCTestCase {
    func testAllUnitsUseQuietForALiveSessionSpendingNothing() {
        XCTAssertEqual(RunwayRateTextTestHook.text(0.2, unit: .quotaMinutesPerHour), "quiet")
        XCTAssertEqual(RunwayRateTextTestHook.text(0.5, unit: .tokensPerHour), "quiet")
        XCTAssertEqual(RunwayRateTextTestHook.text(0.001, unit: .dollarsPerHour), "quiet")
        XCTAssertEqual(RunwayRateTextTestHook.text(0.01, unit: .weeklyPercentPerHour), "quiet")
    }

    /// The word must not leak into the states that mean something else.
    func testQuietDoesNotDisplaceTheOtherStates() {
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .weeklyPercentPerHour, confidence: .idle), "idle")
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .weeklyPercentPerHour, confidence: .unsupported), "n/a")
        XCTAssertEqual(RunwayRateTextTestHook.text(0, unit: .weeklyPercentPerHour, confidence: .waiting), "measuring")
        XCTAssertEqual(RunwayRateTextTestHook.text(9, unit: .quotaMinutesPerHour), "9m/h")
    }
}

/// A brand-new session's first turn is cache-heavy and can be measured over as
/// little as 2 seconds, producing a rate an order of magnitude too high. At the
/// weekly unit that surfaces as an absurd headline number that "fixes itself"
/// moments later.
final class ProvisionalRateClampTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    private func identity(_ id: String, path: String) -> RunwaySessionIdentity {
        .init(id: id, displayName: id, isGoal: false, logPaths: [path])
    }

    private func write(_ lines: [String], to url: URL) throws {
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func usage(at: Date, input: Int, cacheRead: Int, output: Int, id: String) -> String {
        """
        {"timestamp":"\(ISO8601DateFormatter().string(from: at))","message":{"id":"\(id)","model":"claude-opus-5","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":0,"output_tokens":\(output)}}}
        """
    }

    /// With nothing measured anywhere, an unverified spike must be withheld
    /// rather than published as a headline rate.
    func testProvisionalOnlySessionIsWithheldWhenNothingIsMeasured() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("new.jsonl")
        let now = Date()
        // One cache-heavy turn, two seconds long.
        try write([usage(at: now.addingTimeInterval(-4), input: 1, cacheRead: 0, output: 0, id: "m0"),
                   usage(at: now.addingTimeInterval(-2), input: 2, cacheRead: 100_000, output: 500, id: "m1")],
                  to: path)
        ClaudeRunwayTokenActivityParser.resetSampleCacheForTesting()
        let clamped = ClaudeRunwayTokenActivityParser.activitiesClampingProvisional(
            identities: [identity("new", path: path.path)], now: now)
        XCTAssertTrue(clamped.isEmpty, "an unverified first-turn spike must not be published")
    }

    /// The unclamped path is what produced the absurd number, so pin the contrast.
    func testUnclampedPathStillReportsTheSpike() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prov2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("new.jsonl")
        let now = Date()
        try write([usage(at: now.addingTimeInterval(-4), input: 1, cacheRead: 0, output: 0, id: "n0"),
                   usage(at: now.addingTimeInterval(-2), input: 2, cacheRead: 100_000, output: 500, id: "n1")],
                  to: path)
        ClaudeRunwayTokenActivityParser.resetSampleCacheForTesting()
        let raw = ClaudeRunwayTokenActivityParser.activity(
            identity: identity("new", path: path.path), now: now)
        // Thousands of tokens/second — the rate the weekly row used to publish.
        XCTAssertGreaterThan(raw?.tokensPerSecond ?? 0, 1_000)
    }
}

/// The bar and the label must agree. `fillFraction` floors at 12% so a tiny rate
/// stays visible; that floor must not apply to a zero rate, or a "quiet" row
/// draws a pulsing sliver that says the opposite of its own text.
final class RunwayLoadBarAgreementTests: XCTestCase {
    func testZeroRateProducesNoFillRegardlessOfConfidence() {
        for confidence in [RunwayAttributionConfidence.direct, .mixed, .waiting, .idle, .unsupported] {
            XCTAssertFalse(RunwayLoadBarFill.shouldFill(displayRate: 0, maxDisplayRate: 10,
                                                          confidence: confidence),
                           "\(confidence) at rate 0 must leave an empty track")
        }
    }

    func testATinyButRealRateStillFills() {
        XCTAssertTrue(RunwayLoadBarFill.shouldFill(displayRate: 0.2, maxDisplayRate: 100,
                                                     confidence: .direct))
    }
}

/// The first-turn spike is unit-agnostic: it comes from the parser, so every
/// presentation that reads `activities` inherits it.
extension ProvisionalRateClampTests {
    func testClampAppliesToTokenAndDollarUnitsToo() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prov3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        // One established session with a real two-sample burst.
        let steady = dir.appendingPathComponent("steady.jsonl")
        try [usage(at: now.addingTimeInterval(-40), input: 100, cacheRead: 1_000, output: 200, id: "s0"),
             usage(at: now.addingTimeInterval(-20), input: 100, cacheRead: 1_000, output: 200, id: "s1"),
             usage(at: now.addingTimeInterval(-5),  input: 100, cacheRead: 1_000, output: 200, id: "s2")]
            .joined(separator: "\n").write(to: steady, atomically: true, encoding: .utf8)

        // One brand-new session whose single cache-heavy turn spans 2 seconds.
        let fresh = dir.appendingPathComponent("fresh.jsonl")
        try [usage(at: now.addingTimeInterval(-4), input: 1, cacheRead: 0, output: 0, id: "f0"),
             usage(at: now.addingTimeInterval(-2), input: 2, cacheRead: 400_000, output: 900, id: "f1")]
            .joined(separator: "\n").write(to: fresh, atomically: true, encoding: .utf8)

        ClaudeRunwayTokenActivityParser.resetSampleCacheForTesting()
        let ids = [identity("steady", path: steady.path), identity("fresh", path: fresh.path)]
        let clamped = ClaudeRunwayTokenActivityParser.activitiesClampingProvisional(
            identities: ids, now: now)
        let steadyRate = clamped.first { $0.identity.id == "steady" }?.tokensPerSecond ?? 0
        let freshRate = clamped.first { $0.identity.id == "fresh" }?.tokensPerSecond ?? 0
        XCTAssertGreaterThan(steadyRate, 0)
        XCTAssertLessThanOrEqual(freshRate, steadyRate,
            "an unverified first turn must not out-rank the busiest measured session")

        // Pricing must describe the same (clamped) token volume, or $ disagrees
        // with tk/h for the very row the clamp was meant to tame.
        if let freshActivity = clamped.first(where: { $0.identity.id == "fresh" }) {
            let priced = CodexRunwayCalculator.dollarsPerHour(
                for: freshActivity, priceTable: RunwayPriceTable.makeForTesting())
            XCTAssertNotNil(priced)
            XCTAssertLessThan(priced ?? .infinity, 10_000)
        }
    }
}
