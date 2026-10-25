import XCTest
@testable import AgentSessions

/// Task 9b: `CodexUsageModel` publishes an auth verdict fed by `CodexAuthClassifier`.
/// The full wiring (service poll → off-main probe/resolveRead → classify) isn't
/// unit-testable without a real subprocess/network, so these tests pin the pure,
/// deterministic surface: the `state -> authStatus` mapping in `applyAuthState(_:)`
/// (the loud-banner signal is now read directly as `authStatus?.state.isAlarming` —
/// the old dead `showAuthBanner` mirror was removed, F7), plus the `.ok`
/// short-circuit through `handleAuthFetchResult` (which resolves `.ok` from the
/// fetch result alone, never touching the subprocess).
@MainActor
final class CodexUsageModelAuthWiringTests: XCTestCase {

    func testExplicitRecheckClearsProcessLocalOAuthRetryState() async {
        let fetcher = CodexOAuthUsageFetcher(credentials: CodexOAuthCredentials())
        let now = Date()
        await fetcher.seedRetryStateForTesting(
            lastFetchAt: now,
            failed: true,
            rateLimitedUntil: now.addingTimeInterval(1_800)
        )

        await fetcher.resetForUserRecheck()

        let state = await fetcher.retryStateForTesting()
        XCTAssertNil(state.lastFetchAt)
        XCTAssertFalse(state.failed)
        XCTAssertEqual(state.rateLimitedUntil, now.addingTimeInterval(1_800),
                       "rechecking local auth must preserve a server-directed wait")
    }

    func testOnlyAuthoritativeRejectionTriggersSilentCleanRecheck() {
        XCTAssertTrue(CodexUsageModel.shouldSilentlyRecheckAuth(.unauthorized))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.transient))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.skippedCooldown))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.ok(CodexUsageSnapshot())))
    }

    func testOAuthWeeklyCalibrationRequiresFetchedAccountToMatchCurrentAccount() {
        var snapshot = CodexUsageSnapshot()
        snapshot.weekLimitsSource = .oauth
        snapshot.limitsAccountHash = WeeklyQuotaCalibrationScope.hashAccount("account-a")

        XCTAssertEqual(
            CodexUsageModel.weeklyCalibrationAccountHash(
                snapshot: snapshot, currentAccountID: "account-a"),
            snapshot.limitsAccountHash
        )
        XCTAssertNil(CodexUsageModel.weeklyCalibrationAccountHash(
            snapshot: snapshot, currentAccountID: "account-b"))
        XCTAssertNil(CodexUsageModel.weeklyCalibrationAccountHash(
            snapshot: snapshot, currentAccountID: nil))

        snapshot.limitsSource = .oauth
        XCTAssertTrue(CodexUsageModel.oauthSnapshotMatchesCurrentAccount(
            snapshot, currentAccountID: "account-a"))
        XCTAssertFalse(CodexUsageModel.oauthSnapshotMatchesCurrentAccount(
            snapshot, currentAccountID: "account-b"))
    }

    func testApplyAuthStateSignedOutRaisesBanner() {
        let model = CodexUsageModel()
        model.applyAuthState(.signedOut)
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .signedOut)
        XCTAssertEqual(model.authStatus?.remediation, .showCommand("codex login"))
    }

    func testApplyAuthStateExpiredRaisesBanner() {
        let model = CodexUsageModel()
        model.applyAuthState(.expired)
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .expired)
    }

    func testApplyAuthStateCliNotInstalledRaisesBanner() {
        let model = CodexUsageModel()
        model.applyAuthState(.cliNotInstalled)
        XCTAssertEqual(model.authStatus?.state.isAlarming, true)
        XCTAssertEqual(model.authStatus?.state, .cliNotInstalled)
    }

    func testApplyAuthStateOkIsSilent() {
        let model = CodexUsageModel()
        // Seed an alarming state first, then confirm `.ok` clears the banner.
        model.applyAuthState(.signedOut)
        model.applyAuthState(.ok)
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .ok)
    }

    func testApplyAuthStateUnknownIsSilent() {
        let model = CodexUsageModel()
        model.applyAuthState(.unknown)
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .unknown)
    }

    /// A successful fetch is authoritative: `classify` returns `.ok` from the
    /// `lastFetch == .ok` path without needing the CLI probe, so the full
    /// `handleAuthFetchResult` path is deterministic for `.ok` (no subprocess,
    /// no network). This exercises the real compute+publish method end-to-end.
    func testHandleAuthFetchResultOkPublishesSilentOk() async {
        let model = CodexUsageModel()
        model.applyAuthState(.signedOut)   // start alarming to prove it clears
        await model.handleAuthFetchResult(.ok(CodexUsageSnapshot()))
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .ok)
    }

    /// Regression: a completed fetch that returned NO usable data, with nothing
    /// ever applied, reads as `.idle` ("no active session") rather than spinning
    /// "reconnecting…" at a state that will never resolve on its own.
    ///
    /// Seeds `AS_TEST_CODEX_AUTH_PATH` with a real token file. The non-`.ok` path
    /// runs the full stateful classifier, which reads credentials from disk — so
    /// without this the verdict depends on whether the HOST happens to have
    /// ~/.codex/auth.json. On a machine without creds the classifier returns
    /// `.cliNotInstalled` or `.unknown` and this test fails for reasons unrelated
    /// to what it is testing. Present creds short-circuit classify to `.ok`,
    /// which is the precondition the promotion is defined against.
    func testCompletedFetchWithNoDataPublishesIdle() async throws {
        let path = NSTemporaryDirectory() + "codex-auth-\(UUID().uuidString).json"
        try #"{"tokens":{"access_token":"t","account_id":"a"}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        setenv("AS_TEST_CODEX_AUTH_PATH", path, 1)
        defer { unsetenv("AS_TEST_CODEX_AUTH_PATH"); try? FileManager.default.removeItem(atPath: path) }

        let model = CodexUsageModel()
        await model.handleAuthFetchResult(.transient)
        XCTAssertEqual(model.authStatus?.state.isAlarming, false)
        XCTAssertEqual(model.authStatus?.state, .idle)
    }

    // MARK: - Success-path authoritative override (pure helpers)

    /// Only a DEFINITIVE `.signedOut` from the throttled probe overrides the
    /// success path; every other status (signed-in / unknown / cli-missing on a
    /// healthy fetch) must stay `.ok` and never false-alarm.
    func testSuccessPathStateMapping() {
        XCTAssertEqual(CodexUsageModel.successPathState(cli: .signedOut), .signedOut)
        XCTAssertEqual(CodexUsageModel.successPathState(cli: .signedIn), .ok)
        XCTAssertEqual(CodexUsageModel.successPathState(cli: .unknown), .ok)
        XCTAssertEqual(CodexUsageModel.successPathState(cli: .cliMissing), .ok)
    }

    /// Throttle predicate: never-probed (nil) → probe; older-than-interval →
    /// probe; within the interval → reuse cache.
    func testShouldReprobeThrottle() {
        let now = Date()
        XCTAssertTrue(CodexUsageModel.shouldReprobe(lastAt: nil, now: now, interval: 120))
        XCTAssertTrue(CodexUsageModel.shouldReprobe(lastAt: now.addingTimeInterval(-120), now: now, interval: 120))
        XCTAssertTrue(CodexUsageModel.shouldReprobe(lastAt: now.addingTimeInterval(-121), now: now, interval: 120))
        XCTAssertFalse(CodexUsageModel.shouldReprobe(lastAt: now.addingTimeInterval(-119), now: now, interval: 120))
        XCTAssertFalse(CodexUsageModel.shouldReprobe(lastAt: now, now: now, interval: 120))
    }
}

/// Exercises the real fetchers and service against local HTTP fixtures. No live
/// credentials, processes, quota endpoints, or sleeps are used.
@MainActor
final class CodexQuotaRecoveryTests: XCTestCase {
    private var directory: URL!
    private var previousHome: String?
    private var previousAuthPath: String?
    private var scenario: QuotaRecoveryScenario!
    private var fetcher: CodexOAuthUsageFetcher!
    private var rpc: CodexCLIRPCProbe!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"fixture","account_id":"quota-recovery-test"}}"#.utf8).write(to: auth)
        previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        previousAuthPath = ProcessInfo.processInfo.environment["AS_TEST_CODEX_AUTH_PATH"]
        setenv("CODEX_HOME", directory.path, 1)
        setenv("AS_TEST_CODEX_AUTH_PATH", auth.path, 1)
        scenario = QuotaRecoveryScenario()
        QuotaRecoveryURLProtocol.scenario = scenario
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuotaRecoveryURLProtocol.self]
        let fixture = scenario!
        fetcher = CodexOAuthUsageFetcher(credentials: CodexOAuthCredentials(),
                                         session: URLSession(configuration: config),
                                         clock: { fixture.now })
        rpc = CodexCLIRPCProbe(clock: { fixture.now }, probe: { try fixture.nextRPC() })
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
        if let previousAuthPath { setenv("AS_TEST_CODEX_AUTH_PATH", previousAuthPath, 1) } else { unsetenv("AS_TEST_CODEX_AUTH_PATH") }
        QuotaRecoveryURLProtocol.scenario = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func service() -> CodexStatusService {
        CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in },
                           oauthFetcher: fetcher, rpcProbe: rpc)
    }

    func testNetworkFailureRecoversAtOneMinuteWithoutRestarting() async throws {
        scenario.responses = [.network, .weekly(used: 2)]
        let service = service()
        let originalTime = scenario.now.addingTimeInterval(-300)
        await service.setSnapshotForTesting(CodexUsageSnapshot(
            weekRemainingPercent: 100, weekResetText: "2026-10-30T19:00:00Z",
            hasWeekRateLimit: true, weekLimitsSource: .statusProbe,
            limitsSource: .statusProbe, eventTimestamp: originalTime))

        let failed = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(failed.quotaFetchIssue, .network)
        XCTAssertEqual(failed.eventTimestamp, originalTime, "a failed check cannot freshen cached quota")
        scenario.advance(59)
        _ = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(scenario.requestCount, 1)
        XCTAssertEqual(scenario.rpcCount, 1)

        scenario.advance(1)
        let recovered = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(scenario.requestCount, 2)
        XCTAssertEqual(recovered.weekRemainingPercent, 98)
        XCTAssertEqual(recovered.weekLimitsSource, .oauth)
        XCTAssertFalse(recovered.hasFiveHourRateLimit)
        XCTAssertNil(recovered.quotaFetchIssue)

        let suite = "quota-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WeeklyQuotaCalibrationStore.makeForTesting(
            scanRunner: { _, _, _, _, _, _, _, _, _ in nil })
        let reset = Date(timeIntervalSince1970: 1793387023)
        let revision = RunwayPriceTable.shared.rateRevision(forProvider: "codex")
        let accountHash = WeeklyQuotaCalibrationScope.hashAccount("quota-recovery-test")
        let scope = WeeklyQuotaCalibrationScope(provider: "codex", accountHash: accountHash,
                                                sourceFamily: "oauth", limitShape: "weekly",
                                                priceRevision: revision)
        store.setBootstrapForTesting(provider: "codex", result: WeeklyQuotaBootstrapResult(
            usedPercentPoints: 10, dollars: 100, unpricedVolumeShare: 0,
            windowStart: reset.addingTimeInterval(-604_800), resetsAt: reset, scannedAt: Date(),
            priceRevision: revision, limitShape: "weekly", sourceFamily: "oauth",
            activityAccountingRevision: WeeklyQuotaBootstrapResult.codexActivityAccountingRevision,
            accountHash: accountHash, accountAttributionSafe: false))
        store.observeQuota(provider: "codex", remainingPercent: 90, hasExactPercent: false,
                           resetAt: reset, observedAt: Date(), scope: scope, now: Date(), defaults: defaults)
        XCTAssertEqual(store.runwayCalibration(provider: "codex", now: Date()).state, .localEstimate)
        let model = CodexUsageModel(calibrationStore: store, calibrationDefaults: defaults)
        model.applySnapshotForTesting(failed)
        XCTAssertEqual(QuotaData.codex(from: model).presentationState, .reconnecting)
        XCTAssertEqual(model.quotaFetchIssue, .network)
        // The failed fallback must not replace the OAuth scope and invalidate
        // this conversion. Recovery can therefore show Wk burn immediately.
        XCTAssertEqual(store.runwayCalibration(provider: "codex", now: Date()).state, .localEstimate)
        model.applySnapshotForTesting(recovered)
        XCTAssertEqual(QuotaData.codex(from: model).presentationState, .live)
        XCTAssertNil(model.quotaFetchIssue)
        XCTAssertEqual(store.runwayCalibration(provider: "codex", now: Date()).state, .localEstimate)
    }

    func testRPCTimeoutRecoversAtOneMinute() async throws {
        scenario.rpcSucceedsAfter = 1
        let failed = await rpc.fetchRateLimits()
        XCTAssertNil(failed)
        scenario.advance(59)
        let coolingDown = await rpc.fetchRateLimits()
        XCTAssertNil(coolingDown)
        XCTAssertEqual(scenario.rpcCount, 1)
        scenario.advance(1)
        let recovered = await rpc.fetchRateLimits()
        XCTAssertEqual(recovered?.weekRemainingPercent, 98)
        XCTAssertEqual(scenario.rpcCount, 2)
    }

    func testManualRetryBypassesBothFailureCooldownsImmediately() async throws {
        scenario.responses = [.network, .network]
        scenario.rpcSucceedsAfter = 1
        let service = service()
        let failed = await service.refreshLiveLimitsForTesting()
        XCTAssertNotNil(failed.quotaFetchIssue)

        let recovered = await service.refreshLiveLimitsForTesting(retry: true)
        XCTAssertEqual(scenario.requestCount, 2)
        XCTAssertEqual(scenario.rpcCount, 2)
        XCTAssertEqual(recovered.weekRemainingPercent, 98)
        XCTAssertEqual(recovered.weekLimitsSource, .cliRPC)
        XCTAssertNil(recovered.quotaFetchIssue)
    }

    func testServerRateLimitCannotBeBypassedByRetryOrRPC() async throws {
        scenario.responses = [.rateLimited, .weekly(used: 2)]
        let service = service()
        let limited = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(limited.quotaFetchIssue, .rateLimited)
        scenario.advance(599)
        await fetcher.resetForUserRecheck()
        _ = await service.recheckAuthNow()
        let waiting = await service.refreshLiveLimitsForTesting(retry: true)
        XCTAssertEqual(waiting.quotaFetchIssue, .rateLimited)
        XCTAssertEqual(scenario.requestCount, 1)
        XCTAssertEqual(scenario.rpcCount, 0)
        scenario.advance(1)
        let recovered = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(recovered.weekRemainingPercent, 98)
        XCTAssertNil(recovered.quotaFetchIssue)
    }

    func testHealthyOAuthCooldownDoesNotFallBackOrRaiseWarning() async throws {
        scenario.responses = [.weekly(used: 2)]
        let service = service()
        _ = await service.refreshLiveLimitsForTesting()
        let stillHealthy = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(stillHealthy.weekRemainingPercent, 98)
        XCTAssertNil(stillHealthy.quotaFetchIssue)
        XCTAssertEqual(scenario.requestCount, 1)
        XCTAssertEqual(scenario.rpcCount, 0)
    }

    func testLateStatusProbeCannotOverwriteRecoveredLiveWeeklyUsage() async {
        scenario.responses = [.weekly(used: 2)]
        let service = service()
        _ = await service.refreshLiveLimitsForTesting()
        let probe = CodexUsageSnapshot(weekRemainingPercent: 100,
                                       hasWeekRateLimit: true, weekLimitsSource: .statusProbe,
                                       limitsSource: .statusProbe)
        let snapshot = await service.mergeRateLimitSnapshotForTesting(probe)
        XCTAssertEqual(snapshot.weekRemainingPercent, 98)
        XCTAssertEqual(snapshot.weekLimitsSource, .oauth)
        XCTAssertNil(snapshot.quotaFetchIssue)
    }

    func testHealthyRPCCooldownDoesNotRaiseAnOAuthFailureWarning() async {
        scenario.responses = [.network]
        scenario.rpcSucceedsAfter = 0
        let service = service()
        let first = await service.refreshLiveLimitsForTesting()
        XCTAssertEqual(first.weekLimitsSource, .cliRPC)
        let cached = await service.refreshLiveLimitsForTesting()
        XCTAssertNil(cached.quotaFetchIssue)
        XCTAssertEqual(cached.weekRemainingPercent, 98)
        XCTAssertEqual(cached.eventTimestamp, first.eventTimestamp)
        XCTAssertEqual(scenario.requestCount, 1)
        XCTAssertEqual(scenario.rpcCount, 1)
    }

    func testFallbackCannotClearFetchWarningOrConditionWeeklyCalibration() async {
        scenario.responses = [.network]
        let service = service()
        _ = await service.refreshLiveLimitsForTesting()
        let fallback = CodexUsageSnapshot(weekRemainingPercent: 100,
                                          hasWeekRateLimit: true,
                                          weekLimitsSource: .statusProbe,
                                          limitsSource: .statusProbe)
        let merged = await service.mergeRateLimitSnapshotForTesting(fallback)
        XCTAssertEqual(merged.quotaFetchIssue, .network)
        XCTAssertFalse(CodexUsageModel.canCalibrateWeeklyQuota(source: .statusProbe))
        XCTAssertFalse(CodexUsageModel.canCalibrateWeeklyQuota(source: .jsonlFallback))
        XCTAssertFalse(CodexUsageModel.canCalibrateWeeklyQuota(source: nil))
        XCTAssertTrue(CodexUsageModel.canCalibrateWeeklyQuota(source: .oauth))
        XCTAssertTrue(CodexUsageModel.canCalibrateWeeklyQuota(source: .cliRPC))
    }

    func testRetainedWeeklyCalibrationCannotCrossAccounts() throws {
        let now = Date()
        let reset = now.addingTimeInterval(604_800)
        let baseline = RunwayProviderBaseline(
            source: .codex, remainingPercent: 98, resetAt: reset,
            currentRunoutAt: reset, observedAt: now, rateUnit: .weeklyPercentPerHour)
        let calibration = WeeklyRunwayCalibration(
            ratio: 0.2, state: .localEstimate,
            provenance: WeeklyQuotaCalibrationProvenance(
                origin: .live, acquiredAt: now, scannedAt: nil, sourceFamily: "oauth",
                accountHash: "account-a", priceRevision: 1, originResetAt: reset,
                originWindowStart: now))
        for account in ["account-a", "account-b", nil] {
            let request = CodexRunwaySnapshotRequest(
                baseline: baseline,
                identities: [RunwaySessionIdentity(id: "session", displayName: "Session", isGoal: false, logPaths: [])],
                now: now, maxRows: 4, expectedAccountHash: account, weeklyCalibration: calibration)
            if account == "account-a" {
                XCTAssertEqual(request.weeklyPercentPointsPerDollar, 0.2)
            } else {
                let rows = try XCTUnwrap(RunwaySnapshotAssembly.placeholderForUnitTransition(current: nil, request: request))
                XCTAssertEqual(rows.rows.first?.confidence, .unsupported)
                XCTAssertEqual(rows.weeklyCalibrationState, .accountUnverified)
                XCTAssertNil(request.weeklyPercentPointsPerDollar)
            }
        }
    }

    func testHTTPAndFormatFailuresGiveActionableWarningsAndRecover() async {
        for response in [QuotaRecoveryScenario.Response.httpError, .malformed] {
            scenario.responses = [response, .weekly(used: 2)]
            await fetcher.resetForUserRetry()
            _ = await fetcher.fetchUsageResult()
            let issue = await fetcher.lastFailure
            XCTAssertEqual(issue, response == .httpError ? .http(503) : .invalidResponse)
            XCTAssertFalse(String(localized: issue!.recovery).isEmpty)
            scenario.advance(60)
            let result = await fetcher.fetchUsageResult()
            guard case .ok(let snapshot) = result else { return XCTFail("the next minute must retry") }
            XCTAssertEqual(snapshot.weekRemainingPercent, 98)
        }
    }
}

private final class QuotaRecoveryScenario: @unchecked Sendable {
    enum Response: Equatable { case network, rateLimited, httpError, malformed, weekly(used: Int) }
    private let lock = NSLock()
    private var time = Date()
    private var queue: [Response] = []
    private var requests = 0
    private var rpcRequests = 0
    var rpcSucceedsAfter: Int = .max
    var now: Date { lock.withLock { time } }
    var requestCount: Int { lock.withLock { requests } }
    var rpcCount: Int { lock.withLock { rpcRequests } }
    var responses: [Response] {
        get { lock.withLock { queue } }
        set { lock.withLock { queue = newValue } }
    }
    func advance(_ interval: TimeInterval) { lock.withLock { time.addTimeInterval(interval) } }
    func next() -> Response {
        lock.withLock {
            requests += 1
            return queue.isEmpty ? .network : queue.removeFirst()
        }
    }
    func nextRPC() throws -> CodexUsageSnapshot? {
        let succeeds = lock.withLock { rpcRequests += 1; return rpcRequests > rpcSucceedsAfter }
        guard succeeds else { throw URLError(.timedOut) }
        return CodexUsageSnapshot(weekRemainingPercent: 98,
                                  weekResetText: "2026-10-30T19:00:00Z",
                                  hasWeekRateLimit: true, weekLimitsSource: .cliRPC,
                                  limitsSource: .cliRPC, eventTimestamp: now)
    }
}

private final class QuotaRecoveryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var scenario: QuotaRecoveryScenario?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.scenario!.next()
        if response == .network {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = response == .rateLimited ? 429 : response == .httpError ? 503 : 200
        let headers = response == .rateLimited ? ["Retry-After": "600"] : [:]
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let body: String
        if case .weekly(let used) = response {
            body = "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":604800,\"reset_at\":1793387023},\"secondary_window\":null}}"
        } else { body = "{}" }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
