import XCTest
import Dispatch
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
        // 20.5/100, not 20/100: the reported integer is a floor, so the served
        // ratio takes the quantization midpoint on every path.
        XCTAssertEqual(store.percentPointsPerDollar(provider: "codex", now: t0) ?? 0,
                       20.5 / 100, accuracy: 0.0001)
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
        store.recordUsedPercentForTesting(provider: "codex", usedPercentPoints: 2,
                                          resetsAt: t0.addingTimeInterval(604_800))

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
        store.recordUsedPercentForTesting(provider: "codex", usedPercentPoints: 2,
                                          resetsAt: t0.addingTimeInterval(604_800))
        // A bucket strictly after `scannedAt`, carrying no new spend: the
        // denominator stays $20 so this isolates the numerator.
        let ledger = store.ledger(provider: "codex")
        ledger.record(observations: [], priceTable: RunwayPriceTable.makeForTesting(),
                      now: t0.addingTimeInterval(10))
        let served = store.percentPointsPerDollar(provider: "codex", now: t0.addingTimeInterval(30)) ?? 0
        XCTAssertEqual(served, 2.5 / 20.0, accuracy: 0.0001, "reported 2 means [2,3), so use 2.5")
    }

    /// A stored ratio older than the ledger's retention can no longer be freshened
    /// by it, so it must trigger a rescan on age alone. Observed live: a ratio
    /// scanned the previous day was still being served while real spend against
    /// the same integer percent had grown 14%, and the growth trigger could not
    /// fire because the reported percent had not moved.
    func testStaleScanTriggersRescanEvenWithoutGrowth() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wkstale-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let resetsAt = t0.addingTimeInterval(604_800)
        let key = "quotaMeter.weeklyBootstrap.codex.unscoped.\(Int(resetsAt.timeIntervalSince1970))"
        suite.set(try JSONEncoder().encode(WeeklyQuotaBootstrapResult(
            usedPercentPoints: 3, dollars: 10.84, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: resetsAt,
            scannedAt: t0.addingTimeInterval(-24 * 3600))), forKey: key)

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 3, now: t0, defaults: suite)
        XCTAssertTrue(store.scanWasDispatchedForTesting(provider: "codex"),
                      "a day-old scan must refresh on age, not only on growth")
    }

    /// The age trigger must not cause a rescan on every poll of a fresh scan.
    func testFreshScanIsNotRescanned() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wkfresh-\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.description) }
        let resetsAt = t0.addingTimeInterval(604_800)
        let key = "quotaMeter.weeklyBootstrap.codex.unscoped.\(Int(resetsAt.timeIntervalSince1970))"
        suite.set(try JSONEncoder().encode(WeeklyQuotaBootstrapResult(
            usedPercentPoints: 3, dollars: 10.84, unpricedVolumeShare: 0,
            windowStart: t0, resetsAt: resetsAt,
            scannedAt: t0.addingTimeInterval(-600))), forKey: key)

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        // The ledger must be able to vouch for the span since that scan, or the
        // cache is unverifiable and rescanning it is correct rather than churn.
        store.ledger(provider: "codex").record(
            observations: [], priceTable: RunwayPriceTable.makeForTesting(), now: t0)
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 3, now: t0, defaults: suite)
        XCTAssertFalse(store.scanWasDispatchedForTesting(provider: "codex"),
                       "a ten-minute-old scan the ledger covers is still good; rescanning is churn")
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
        // 20.5/100, not 20/100: the reported integer is a floor, so the served
        // ratio takes the quantization midpoint on every path.
        XCTAssertEqual(store.percentPointsPerDollar(provider: "codex", now: t0) ?? 0,
                       20.5 / 100, accuracy: 0.0001)
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

/// The bootstrap cache is the app's memory of what a percentage point costs.
/// Every test here pins a way that memory was observed to go wrong on a live
/// account: a good measurement left unread, a failed scan retiring its own retry,
/// or two different weeks' terms combined into one ratio.
final class WeeklyQuotaBootstrapCacheTests: XCTestCase {

    private final class ScanEntryCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }

        func hasReached(_ expected: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value >= expected
        }
    }

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private var root: URL!
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wkcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "wkcache-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        suite.removePersistentDomain(forName: suiteName)
    }

    private func key(_ provider: String, _ scope: String, _ resetsAt: Date) -> String {
        "quotaMeter.weeklyBootstrap.\(provider).\(scope).\(Int(resetsAt.timeIntervalSince1970))"
    }

    private func store(_ result: WeeklyQuotaBootstrapResult, at key: String) throws {
        suite.set(try JSONEncoder().encode(result), forKey: key)
    }

    private func result(used: Double, dollars: Double, resetsAt: Date,
                        scannedAt: Date) -> WeeklyQuotaBootstrapResult {
        WeeklyQuotaBootstrapResult(
            usedPercentPoints: used, dollars: dollars, unpricedVolumeShare: 0,
            windowStart: resetsAt.addingTimeInterval(-604_800), resetsAt: resetsAt,
            scannedAt: scannedAt)
    }

    /// Writes a Codex transcript whose turns all carry `resetsAt` as their weekly
    /// anchor, so a scan of this root produces a real, priced measurement.
    private func writeTranscript(outputTokens: Int, resetsAt: Date, at: Date) throws {
        let iso = ISO8601DateFormatter().string(from: at)
        let lines = [
            "{\"timestamp\":\"\(iso)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6\"}}",
            "{\"timestamp\":\"\(iso)\",\"type\":\"token_count\",\"payload\":{\"info\":{\"last_token_usage\":"
            + "{\"input_tokens\":0,\"cached_input_tokens\":0,\"cache_write_input_tokens\":0,"
            + "\"output_tokens\":\(outputTokens),\"total_tokens\":\(outputTokens)}},"
            + "\"rate_limits\":{\"primary\":{\"used_percent\":6.0,\"window_minutes\":10080,"
            + "\"resets_at\":\(resetsAt.timeIntervalSince1970)},\"secondary\":null}}}"
        ]
        try lines.joined(separator: "\n").write(
            to: root.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    }

    private func waitForScan(_ store: WeeklyQuotaCalibrationStore, provider: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if store.scanSucceededForTesting(provider: provider)
                || store.scanIsCoolingDownForTesting(provider: provider) { return }
            usleep(20_000)
        }
    }

    private func waitForScanToFinish(_ store: WeeklyQuotaCalibrationStore, provider: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && store.scanIsInFlightForTesting(provider: provider) {
            usleep(20_000)
        }
    }

    private func waitForScanEntry(_ counter: ScanEntryCounter, count: Int = 1) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if counter.hasReached(count) { return true }
            usleep(20_000)
        }
        return counter.hasReached(count)
    }

    // MARK: - Carry-over slot

    /// The regression that made every Claude session read ~21% low.
    ///
    /// Restore only ever consulted two keys — the carry-over slot and the CURRENT
    /// anchor's cache — so a completed window's measurement sat on disk unread.
    /// On the first launch after the slot was introduced it was seeded from the
    /// fresh window's sliver, and the `<=` promotion guard then locked it there.
    /// Live values: a completed week at 77pp/$1239.83 was ignored in favour of
    /// 7pp/$142.71.
    func testMigratesACompletedWindowIntoTheCarryOverSlot() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        try store(result(used: 77, dollars: 1239.83, resetsAt: previous,
                         scannedAt: previous.addingTimeInterval(-3600)),
                  at: key("claude", "unscoped", previous))
        try store(result(used: 7, dollars: 142.71, resetsAt: current, scannedAt: current),
                  at: key("claude", "unscoped", current))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.ensureBootstrap(provider: "claude", root: root, resetsAt: current,
                              windowMinutes: 10080, usedPercentPoints: 7,
                              now: current, defaults: suite)

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 77.0 / 1239.83, accuracy: 0.0005,
                       "the completed week is the better-conditioned measurement")
        XCTAssertGreaterThan(served, 7.0 / 142.71,
                             "serving the 7pp sliver understates every session's %/h")
    }

    /// Migration must not let an older, worse-conditioned window displace a good
    /// carry-over that is already in the slot.
    func testMigrationKeepsTheLargerNumerator() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        try store(result(used: 4, dollars: 60, resetsAt: previous, scannedAt: previous),
                  at: key("claude", "unscoped", previous))
        let bestKey = "quotaMeter.weeklyBootstrapBest.claude.unscoped"
        try store(result(used: 70, dollars: 1000, resetsAt: previous, scannedAt: previous),
                  at: bestKey)

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.ensureBootstrap(provider: "claude", root: root, resetsAt: current,
                              windowMinutes: 10080, usedPercentPoints: 0,
                              now: current, defaults: suite)

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 70.0 / 1000.0, accuracy: 0.0005)
    }

    // MARK: - Freshening across a reset

    /// Freshening extends a stored denominator with ledger spend and pairs it with
    /// the CURRENT reported percent. When the stored measurement was carried over
    /// from a previous week, those two terms describe different windows: a carried
    /// 77pp/$1239.83 beside a fresh week reporting 1pp would serve 1.5/1239.83 —
    /// roughly fifty times too low. The carried ratio must be served intact.
    func testFresheningIsRejectedAcrossAWindowBoundary() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.setBestBootstrapForTesting(
            provider: "claude",
            result: result(used: 77, dollars: 1239.83, resetsAt: previous,
                           scannedAt: current.addingTimeInterval(-1800)))
        // Fresh window, 1pp consumed, and a ledger that could otherwise freshen.
        store.recordUsedPercentForTesting(provider: "claude", usedPercentPoints: 1,
                                          resetsAt: current)
        store.ledger(provider: "claude").record(
            observations: [], priceTable: RunwayPriceTable.makeForTesting(),
            now: current.addingTimeInterval(-60))

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 77.0 / 1239.83, accuracy: 0.0005,
                       "a carried measurement must not borrow the new window's numerator")
    }

    // MARK: - Failed scans stay retryable

    /// A scan that fails must not retire its own retry. Marking the anchor on
    /// dispatch rather than on success meant one unreadable root permanently
    /// pinned the stale ratio the rescan existed to replace.
    func testAFailedScanRemainsRetryable() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        try store(result(used: 3, dollars: 10.84, resetsAt: resetsAt,
                         scannedAt: t0.addingTimeInterval(-24 * 3600)),
                  at: key("codex", "unscoped", resetsAt))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 3, now: t0, defaults: suite)
        waitForScan(store, provider: "codex")

        XCTAssertTrue(store.scanWasDispatchedForTesting(provider: "codex"))
        XCTAssertFalse(store.scanSucceededForTesting(provider: "codex"),
                       "an unreadable root cannot have produced a measurement")
        XCTAssertTrue(store.scanIsCoolingDownForTesting(provider: "codex", now: t0),
                      "failure must back off rather than retire the anchor")

        // Once the backoff elapses the same bucket must be scannable again. Assert
        // a SECOND dispatch, not merely that one ever happened: a provider-level
        // flag is already true from the first attempt, so it cannot fail.
        XCTAssertEqual(store.scanDispatchCountForTesting(provider: "codex"), 1)
        store.clearScanCooldownForTesting(provider: "codex")
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 3, now: t0, defaults: suite)
        waitForScan(store, provider: "codex")
        XCTAssertEqual(store.scanDispatchCountForTesting(provider: "codex"), 2,
                       "a burnt retry leaves the stale ratio in place for the whole window")
    }

    /// A scan walking hundreds of megabytes can outlive the account it was started
    /// for. The state dictionaries are keyed by provider, so nothing else stops the
    /// old account's result from landing in the new account's calibration.
    func testAScanCompletingAfterAnAccountSwitchIsDiscarded() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        let now = t0.addingTimeInterval(7200)
        let entries = ScanEntryCounter()
        let release = DispatchSemaphore(value: 0)
        let completed = result(used: 6, dollars: 20, resetsAt: resetsAt, scannedAt: now)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(
            launchedAt: t0,
            scanRunner: { _, _, _, _, _, _, _ in
                entries.increment()
                release.wait()
                return completed
            })
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 6,
                              accountHash: "acct-a", now: now, defaults: suite)
        XCTAssertTrue(waitForScanEntry(entries))
        // The injected scanner cannot complete until after account B is active.
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 1, accountHash: "acct-b",
                              now: now, defaults: suite)
        release.signal()
        waitForScanToFinish(store, provider: "codex")

        XCTAssertNil(store.bootstrap(provider: "codex"),
                     "account A's scan result must not land in account B's state")
        XCTAssertNil(store.percentPointsPerDollar(provider: "codex", now: now))
    }

    /// Failure bookkeeping is scoped too. Account A must not fail after a switch
    /// and leave account B waiting through A's ten-minute cooldown.
    func testAFailedScanAfterAnAccountSwitchDoesNotCoolDownTheNewAccount() {
        let resetsAt = t0.addingTimeInterval(604_800)
        let entries = ScanEntryCounter()
        let release = DispatchSemaphore(value: 0)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(
            launchedAt: t0,
            scanRunner: { _, _, _, _, _, _, _ in
                entries.increment()
                release.wait()
                return nil
            })

        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 3,
                              accountHash: "acct-a", now: t0, defaults: suite)
        XCTAssertTrue(waitForScanEntry(entries))
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 3,
                              accountHash: "acct-b", now: t0, defaults: suite)
        release.signal()
        waitForScanToFinish(store, provider: "codex")

        XCTAssertFalse(store.scanIsCoolingDownForTesting(provider: "codex", now: t0))
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 3,
                              accountHash: "acct-b", now: t0, defaults: suite)
        XCTAssertEqual(store.scanDispatchCountForTesting(provider: "codex"), 1,
                       "account B must be able to dispatch immediately")
        XCTAssertTrue(waitForScanEntry(entries, count: 2))
        release.signal()
        waitForScanToFinish(store, provider: "codex")
    }

    // MARK: - Restart and regime changes

    /// The ledger is memory-only, so after a restart it cannot vouch for the span
    /// between the cached scan and launch. `activity` answers happily from a single
    /// post-launch bucket, so freshening used to silently drop the pre-restart
    /// spend and serve an undercounted denominator — 43% high on live data.
    func testFresheningRejectsASpanTheLedgerDidNotWatch() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        let scannedAt = t0.addingTimeInterval(-3600)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.setBootstrapForTesting(
            provider: "codex",
            result: result(used: 4, dollars: 13.56, resetsAt: resetsAt, scannedAt: scannedAt))
        store.recordUsedPercentForTesting(provider: "codex", usedPercentPoints: 6,
                                          resetsAt: resetsAt)
        // One bucket, banked "after launch" — an hour after the cached scan, so the
        // ledger never observed the interval in between.
        store.ledger(provider: "codex").record(
            observations: [], priceTable: RunwayPriceTable.makeForTesting(), now: t0)

        // Falls back to the stored ratio rather than inventing a small denominator.
        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "codex",
                                                                now: t0.addingTimeInterval(30)))
        XCTAssertEqual(served, 4.5 / 13.56, accuracy: 0.0001)
    }

    /// ...and because that stored ratio is itself unverifiable, a rescan must be
    /// triggered. Neither the growth (+3pp) nor the age (6h) trigger fires here.
    func testAnUnfreshenableCacheTriggersARescan() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        try store(result(used: 4, dollars: 13.56, resetsAt: resetsAt,
                         scannedAt: t0.addingTimeInterval(-3600)),
                  at: key("codex", "unscoped", resetsAt))
        try writeTranscript(outputTokens: 1_000_000, resetsAt: resetsAt,
                            at: t0.addingTimeInterval(3600))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 6,
                              now: t0.addingTimeInterval(7200), defaults: suite)
        waitForScan(store, provider: "codex")

        XCTAssertTrue(store.scanSucceededForTesting(provider: "codex"),
                      "a restart leaves a same-anchor cache no trigger can clear")
        let stored = try XCTUnwrap(store.bootstrap(provider: "codex"))
        XCTAssertEqual(stored.dollars, 20.0, accuracy: 0.001,
                       "the frozen $13.56 denominator must be re-measured")
    }

    /// A quota-regime change moves capacity without touching the price table or the
    /// limit shape, so the compatibility stamp cannot see it. Anthropic's +50%
    /// weekly promotion ending is exactly this. Once the current window stands on
    /// its own, recency beats numerator size.
    func testAWellConditionedCurrentWindowBeatsAnOlderCarryOver() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.setBestBootstrapForTesting(
            provider: "claude",
            result: result(used: 77, dollars: 1239.62, resetsAt: previous, scannedAt: previous))
        store.setBootstrapForTesting(
            provider: "claude",
            result: result(used: 12, dollars: 120, resetsAt: current, scannedAt: current))

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 12.5 / 120, accuracy: 0.0001,
                       "12pp of the CURRENT regime beats 77pp of a possibly-expired one")
    }

    /// Below that bar the carry-over still wins — a 2pp sliver swings badly inside
    /// one integer quantum.
    func testAPoorlyConditionedCurrentWindowDoesNotDisplaceTheCarryOver() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.setBestBootstrapForTesting(
            provider: "claude",
            result: result(used: 77, dollars: 1239.62, resetsAt: previous, scannedAt: previous))
        store.setBootstrapForTesting(
            provider: "claude",
            result: result(used: 2, dollars: 28, resetsAt: current, scannedAt: current))

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 77.5 / 1239.62, accuracy: 0.0001)
    }

    /// A carry-over no fresh measurement has displaced must not be trusted forever.
    func testAnExpiredCarryOverIsNotServed() throws {
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.setBestBootstrapForTesting(
            provider: "claude",
            result: result(used: 77, dollars: 1239.62, resetsAt: t0, scannedAt: t0))
        let muchLater = t0.addingTimeInterval(WeeklyQuotaCalibrationStore.carryOverMaximumAge + 60)
        XCTAssertNil(store.percentPointsPerDollar(provider: "claude", now: muchLater),
                     "a measurement three weeks stale may describe a different quota regime")
    }

    /// A measurement priced under a different table describes a different
    /// conversion; carrying it forward would let a stale price win purely by
    /// having reached a larger percentage.
    func testAnIncompatiblePriceRevisionIsNotMigrated() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        var stale = result(used: 80, dollars: 1000, resetsAt: t0, scannedAt: t0)
        stale.priceRevision = RunwayPriceTable.shared.revision + 99
        try store(stale, at: key("codex", "acct-a", t0))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 1, accountHash: "acct-a",
                              now: t0, defaults: suite)
        XCTAssertNil(store.percentPointsPerDollar(provider: "codex", now: t0),
                     "a differently-priced week is not a usable calibration")
    }

    /// Compatibility is an in-memory rule too. A remotely refreshed price table
    /// must invalidate a bootstrap already selected by this process.
    func testAPriceRevisionChangeDropsAnInMemoryBootstrap() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        let prices = RunwayPriceTable.makeForTesting()
        var cached = result(used: 40, dollars: 500, resetsAt: resetsAt, scannedAt: t0)
        cached.priceRevision = prices.revision
        cached.limitShape = "5h+weekly"
        try store(cached, at: key("codex", "acct-a", resetsAt))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(
            launchedAt: t0,
            priceRevisionProvider: { prices.revision })
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 40,
                              accountHash: "acct-a", limitShape: "5h+weekly",
                              now: t0, defaults: suite)
        XCTAssertNotNil(store.percentPointsPerDollar(provider: "codex", now: t0))

        let replacement = Data("""
        {"version":1,"updated":"9999-12-31","models":{"gpt-5.6":{"inputPerMTok":1,"cachedInputPerMTok":1,"outputPerMTok":1}}}
        """.utf8)
        XCTAssertTrue(prices.loadForTesting(json: replacement))
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 40, accountHash: "acct-a",
                              limitShape: "5h+weekly", now: t0, defaults: suite)
        XCTAssertNil(store.percentPointsPerDollar(provider: "codex", now: t0),
                     "the old table's conversion must not survive in memory")
    }

    /// A plan-shape change on the same account is a complete scope transition,
    /// even though the persisted account key itself does not change.
    func testALimitShapeChangeDropsAnInMemoryBootstrap() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        var cached = result(used: 40, dollars: 500, resetsAt: resetsAt, scannedAt: t0)
        cached.priceRevision = RunwayPriceTable.shared.revision
        cached.limitShape = "weekly"
        try store(cached, at: key("claude", "unscoped", resetsAt))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "claude", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 40,
                              limitShape: "weekly", now: t0, defaults: suite)
        XCTAssertNotNil(store.percentPointsPerDollar(provider: "claude", now: t0))

        store.ensureBootstrap(provider: "claude", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 40, limitShape: "weekly+scoped",
                              now: t0, defaults: suite)
        XCTAssertNil(store.percentPointsPerDollar(provider: "claude", now: t0),
                     "a different plan shape must not reuse the old conversion")
    }

    /// The served ratio must use the quantization midpoint whichever path produces
    /// it. The midpoint lived only on the freshening path, so a carried-over
    /// measurement served the raw floor while a current-window one served the
    /// midpoint — making two providers' numbers incomparable by accident.
    func testTheMidpointIsAppliedToACarriedMeasurementToo() throws {
        let previous = t0
        let current = t0.addingTimeInterval(604_800)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: current)
        store.setBestBootstrapForTesting(
            provider: "claude",
            result: result(used: 77, dollars: 1239.62, resetsAt: previous, scannedAt: previous))
        store.recordUsedPercentForTesting(provider: "claude", usedPercentPoints: 1,
                                          resetsAt: current)

        let served = try XCTUnwrap(store.percentPointsPerDollar(provider: "claude", now: current))
        XCTAssertEqual(served, 77.5 / 1239.62, accuracy: 0.00001,
                       "reported 77 means [77,78), so serve 77.5 — on every path")
    }

    /// The startup dead zone. A window at 0pp has nothing to divide by, so the
    /// scanner rejects it — but 0pp, 1pp and 2pp share one refresh bucket, so a
    /// burnt attempt at 0pp blocked every retry until 3pp.
    func testAZeroPercentWindowDoesNotBlockTheRetryAtOnePercent() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 0,
                              now: t0, defaults: suite)
        waitForScan(store, provider: "codex")
        XCTAssertFalse(store.scanSucceededForTesting(provider: "codex"),
                       "0pp gives the scanner nothing to divide")

        store.clearScanCooldownForTesting(provider: "codex")
        try writeTranscript(outputTokens: 1_000_000, resetsAt: resetsAt,
                            at: t0.addingTimeInterval(3600))
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 1,
                              now: t0.addingTimeInterval(7200), defaults: suite)
        waitForScan(store, provider: "codex")
        XCTAssertTrue(store.scanSucceededForTesting(provider: "codex"),
                      "the same bucket must still be scannable once there is data")
    }

    /// A rescan on age must actually replace the stored ratio, not merely dispatch.
    func testAStaleScanIsReplacedByTheFreshMeasurement() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        try store(result(used: 6, dollars: 10.0, resetsAt: resetsAt,
                         scannedAt: t0.addingTimeInterval(-24 * 3600)),
                  at: key("codex", "unscoped", resetsAt))
        // 1M output tokens of gpt-5.6 at $20/MTok, so a real scan prices this
        // window at $20 rather than the stored $10.
        try writeTranscript(outputTokens: 1_000_000, resetsAt: resetsAt,
                            at: t0.addingTimeInterval(3600))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 6,
                              now: t0.addingTimeInterval(7200), defaults: suite)
        waitForScan(store, provider: "codex")

        XCTAssertTrue(store.scanSucceededForTesting(provider: "codex"))
        let stored = try XCTUnwrap(store.bootstrap(provider: "codex"))
        XCTAssertEqual(stored.dollars, 20.0, accuracy: 0.001,
                       "the day-old $10 denominator must be replaced, not merely re-dispatched")
    }

    // MARK: - Account scope

    /// The persisted keys are account-scoped but the in-memory maps are keyed by
    /// provider, so an in-process account switch would keep serving the previous
    /// account's calibration under the new account's name.
    func testAnAccountSwitchDropsThePreviousAccountsCalibration() throws {
        let resetsAt = t0.addingTimeInterval(604_800)
        try store(result(used: 40, dollars: 100, resetsAt: resetsAt, scannedAt: t0),
                  at: key("codex", "acct-a", resetsAt))

        let store = WeeklyQuotaCalibrationStore.makeForTesting(launchedAt: t0)
        store.ensureBootstrap(provider: "codex", root: root, resetsAt: resetsAt,
                              windowMinutes: 10080, usedPercentPoints: 40,
                              accountHash: "acct-a", now: t0, defaults: suite)
        XCTAssertEqual(store.percentPointsPerDollar(provider: "codex", now: t0) ?? 0,
                       40.5 / 100.0, accuracy: 0.001)

        // Same process, different account, and nothing cached for it.
        store.ensureBootstrap(provider: "codex", root: URL(fileURLWithPath: "/nonexistent"),
                              resetsAt: resetsAt, windowMinutes: 10080,
                              usedPercentPoints: 2, accountHash: "acct-b",
                              now: t0, defaults: suite)
        XCTAssertNil(store.percentPointsPerDollar(provider: "codex", now: t0),
                     "account B must not inherit account A's conversion")
    }
}
