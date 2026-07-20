import XCTest
@testable import AgentSessions

final class ClaudeUsageSourceManagerTests: XCTestCase {

    /// Shared temp-file store so no test manager falls back to the real
    /// ~/Library/Application Support path via `init(store:)`'s default argument.
    /// `start()` can persist a live fetch (save() at lines 401/876/1059), so a
    /// default-store manager would write real user data during the suite.
    private var tempStoreURL: URL!

    override func setUp() {
        super.setUp()
        tempStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_claude_usage_mgr_\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let url = tempStoreURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempStoreURL = nil
        super.tearDown()
    }

    /// Build a manager backed by the per-test temp store (never the real path).
    private func makeManager() -> ClaudeUsageSourceManager {
        ClaudeUsageSourceManager(store: ClaudeUsageSnapshotStore(fileURL: tempStoreURL))
    }

    // MARK: - Mode switching

    func testInit_tmuxOnlyMode_doesNotAttemptOAuth() async {
        var deliveredSnapshots: [ClaudeLimitSnapshot] = []
        let mgr = makeManager()

        await mgr.start(
            mode: .tmuxOnly,
            handler: { snap in deliveredSnapshots.append(snap) },
            availabilityHandler: { _ in }
        )

        // tmuxOnly mode activates tmux adapter, not OAuth
        let diagnostics = await mgr.currentSourceDescription()
        XCTAssertEqual(diagnostics, "tmux")

        await mgr.stop()
    }

    func testDiagnosticsSnapshot_returnsNonEmpty() async {
        let mgr = makeManager()
        await mgr.start(
            mode: .auto,
            handler: { _ in },
            availabilityHandler: { _ in }
        )
        let diag = await mgr.diagnosticsSnapshot()
        XCTAssertFalse(diag.isEmpty)
        XCTAssertTrue(diag.contains("mode:"))
        await mgr.stop()
    }

    func testStop_canBeCalledMultipleTimes() async {
        let mgr = makeManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.stop()
        await mgr.stop() // Should not crash
    }

    func testSetVisibility_doesNotCrash() async {
        let mgr = makeManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.setVisibility(menuVisible: true, stripVisible: false, appIsActive: false)
        await mgr.setVisibility(menuVisible: false, stripVisible: true, appIsActive: true)
        await mgr.setVisibility(menuVisible: false, stripVisible: false, appIsActive: false)
        await mgr.stop()
    }

    // MARK: - Auto mode health description

    func testHealthDescription_noData_returnsPending() async {
        let mgr = makeManager()
        // Don't start — just check initial state directly
        let health = await mgr.currentHealthDescription()
        XCTAssertEqual(health, "pending")
    }

    func testCurrentSourceDescription_oauthOnlyMode() async {
        let mgr = makeManager()
        await mgr.start(mode: .oauthOnly, handler: { _ in }, availabilityHandler: { _ in })
        let source = await mgr.currentSourceDescription()
        // oauthOnly without successful fetch
        XCTAssertTrue(source.contains("OAuth"))
        await mgr.stop()
    }

    // MARK: - Rate limit error

    /// The rateLimited error case must carry the retryAfter value through unchanged.
    /// This is the contract that ClaudeUsageSourceManager relies on to schedule
    /// the correct backoff delay without touching oauthFailureCount.
    func testRateLimitedError_preservesRetryAfterValue() {
        let err = ClaudeOAuthUsageClientError.rateLimited(retryAfter: 1255)
        if case .rateLimited(let t) = err {
            XCTAssertEqual(t, 1255, accuracy: 0.001)
        } else {
            XCTFail("Expected .rateLimited case")
        }
    }

    /// Distinct from generic httpError — source manager pattern-matches on the
    /// specific case, so it must not be conflated with other HTTP errors.
    func testRateLimitedError_isDistinctFromHttpError() {
        let rateLimited = ClaudeOAuthUsageClientError.rateLimited(retryAfter: 60)
        let httpError   = ClaudeOAuthUsageClientError.httpError(429)
        // They must be distinct cases (different behavior in source manager)
        if case .rateLimited = rateLimited {} else { XCTFail("Expected .rateLimited") }
        if case .httpError   = httpError   {} else { XCTFail("Expected .httpError") }
    }

    // MARK: - Web API mode

    func testWebOnlyMode_doesNotAttemptOAuth() async {
        let mgr = makeManager()
        await mgr.start(mode: .webOnly, handler: { _ in }, availabilityHandler: { _ in })
        let source = await mgr.currentSourceDescription()
        XCTAssertTrue(source.contains("Web API"), "webOnly mode should report Web API source, got: \(source)")
        await mgr.stop()
    }

    func testAutoMode_credentialGating_diagnosticsReflectWatchState() async {
        let mgr = makeManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        // Give a brief moment for OAuth attempt to fail and enter credential-gated mode
        try? await Task.sleep(nanoseconds: 200_000_000)
        let diag = await mgr.diagnosticsSnapshot()
        XCTAssertTrue(diag.contains("credentialWatchActive"))
        XCTAssertTrue(diag.contains("oauthFailureCount"))
        await mgr.stop()
    }

    func testOAuthRetryPlan_hiddenAfterColdStartUsesCredentialWatch() {
        let started = Date(timeIntervalSince1970: 1_000)
        let plan = ClaudeUsageSourceManager.oauthRetryPlan(
            usingTmuxFallback: false,
            startedAt: started,
            now: started.addingTimeInterval(120),
            failureCount: 1,
            visible: false
        )

        XCTAssertEqual(plan, .credentialWatch)
    }

    func testOAuthRetryPlan_visibleAfterColdStartKeepsTimedRetryAlive() {
        let started = Date(timeIntervalSince1970: 1_000)
        let plan = ClaudeUsageSourceManager.oauthRetryPlan(
            usingTmuxFallback: false,
            startedAt: started,
            now: started.addingTimeInterval(120),
            failureCount: 1,
            visible: true
        )

        XCTAssertEqual(plan, .timed(delay: 3 * 60))
    }

    func testOAuthRetryPlan_coldStartStillUsesFastRetry() {
        let started = Date(timeIntervalSince1970: 1_000)
        let plan = ClaudeUsageSourceManager.oauthRetryPlan(
            usingTmuxFallback: false,
            startedAt: started,
            now: started.addingTimeInterval(30),
            failureCount: 2,
            visible: true
        )

        XCTAssertEqual(plan, .coldStart(delay: 30))
    }

    func testVisibleTransitionRetriesOAuthForAutoModeEvenAfterTmuxFallback() {
        XCTAssertTrue(
            ClaudeUsageSourceManager.shouldRetryOAuthOnVisibleTransition(
                wasVisible: false,
                visible: true,
                mode: .auto
            )
        )
    }

    func testVisibleTransitionDoesNotRetryOAuthForTmuxOnlyMode() {
        XCTAssertFalse(
            ClaudeUsageSourceManager.shouldRetryOAuthOnVisibleTransition(
                wasVisible: false,
                visible: true,
                mode: .tmuxOnly
            )
        )
    }

    func testAlreadyVisibleTransitionDoesNotRetryOAuth() {
        XCTAssertFalse(
            ClaudeUsageSourceManager.shouldRetryOAuthOnVisibleTransition(
                wasVisible: true,
                visible: true,
                mode: .auto
            )
        )
    }

    func testVisibleTransitionDoesNotRetryOAuthDuringRateLimitBackoff() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(
            ClaudeUsageSourceManager.shouldRetryOAuthOnVisibleTransition(
                wasVisible: false,
                visible: true,
                mode: .auto,
                rateLimitRetryDeadline: now.addingTimeInterval(60),
                now: now
            )
        )
    }

    func testVisibleTransitionRetriesOAuthAfterRateLimitBackoffExpires() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            ClaudeUsageSourceManager.shouldRetryOAuthOnVisibleTransition(
                wasVisible: false,
                visible: true,
                mode: .auto,
                rateLimitRetryDeadline: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testAutoMode_webApiFallback_stateTrackedInDiagnostics() async {
        let mgr = makeManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        let diag = await mgr.diagnosticsSnapshot()
        XCTAssertTrue(diag.contains("usingWebFallback"))
        XCTAssertTrue(diag.contains("webApiEnabled"))
        XCTAssertTrue(diag.contains("webFailureCount"))
        await mgr.stop()
    }

    // MARK: - Cold-start restore

    /// On start, a recently-saved snapshot must be published immediately so the
    /// UI has data before the first live fetch completes.
    func testColdStart_restoresCachedSnapshotWithNonFailedHealth() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_claude_usage_\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempURL) }

        let store = ClaudeUsageSnapshotStore(fileURL: tempURL)
        let seed = ClaudeLimitSnapshot(
            fetchedAt: Date().addingTimeInterval(-30),
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: 0.4,
            fiveHourResetText: "",
            weeklyUsedRatio: 0.2,
            weeklyResetText: "",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )
        await store.save(seed)

        var delivered: [ClaudeLimitSnapshot] = []
        let mgr = ClaudeUsageSourceManager(store: store)
        await mgr.start(
            mode: .auto,
            handler: { snap in delivered.append(snap) },
            availabilityHandler: { _ in }
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        await mgr.stop()

        let restored = delivered.first
        XCTAssertNotNil(restored, "Cached snapshot should be published on cold start")
        XCTAssertEqual(restored?.source, .cachedOAuth)
        XCTAssertNotEqual(restored?.health, .failed)
        XCTAssertEqual(restored?.fetchedAt.timeIntervalSince1970 ?? 0, seed.fetchedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(restored?.fiveHourUsedRatio ?? 0, 0.4, accuracy: 0.001)
    }

    func testColdStart_preservesPersistedTmuxSource() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_claude_usage_\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tempURL) }

        let store = ClaudeUsageSnapshotStore(fileURL: tempURL)
        let seed = ClaudeLimitSnapshot(
            fetchedAt: Date().addingTimeInterval(-30),
            source: .tmuxUsage,
            health: .live,
            fiveHourUsedRatio: 0.22,
            fiveHourResetText: "resets in 3h",
            weeklyUsedRatio: 0.03,
            weeklyResetText: "resets in 2d",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )
        await store.save(seed)

        var delivered: [ClaudeLimitSnapshot] = []
        let mgr = ClaudeUsageSourceManager(store: store)
        await mgr.start(
            mode: .auto,
            handler: { snap in delivered.append(snap) },
            availabilityHandler: { _ in }
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        await mgr.stop()

        let restored = delivered.first
        XCTAssertEqual(restored?.source, .tmuxUsage)
        XCTAssertEqual(restored?.health, .live)
        XCTAssertEqual(restored?.fiveHourUsedRatio ?? 0, 0.22, accuracy: 0.001)
    }

    func testMergeMissingFiveHourWindowPreservesRecentTmuxSessionLimit() {
        let now = ISO8601DateFormatter().date(from: "2026-06-23T01:31:00Z")!
        let incoming = ClaudeLimitSnapshot(
            fetchedAt: now,
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: 0.0,
            fiveHourResetText: "",
            weeklyUsedRatio: 0.03,
            weeklyResetText: "2027-01-19T09:00:00Z",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: "oauth-weekly-only"
        )
        let previous = ClaudeLimitSnapshot(
            fetchedAt: now.addingTimeInterval(-60),
            source: .tmuxUsage,
            health: .live,
            fiveHourUsedRatio: 0.24,
            fiveHourResetText: "11:20pm (America/Los_Angeles)",
            weeklyUsedRatio: 0.05,
            weeklyResetText: "Jun 28 at 5am (America/Los_Angeles)",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )

        let merged = ClaudeUsageSourceManager.mergeMissingFiveHourWindow(
            incoming: incoming,
            previous: previous,
            now: now
        )

        XCTAssertEqual(merged?.fiveHourUsedRatio ?? 0, 0.24, accuracy: 0.001)
        XCTAssertEqual(merged?.fiveHourResetText, "11:20pm (America/Los_Angeles)")
        XCTAssertEqual(merged?.weeklyUsedRatio ?? 0, incoming.weeklyUsedRatio ?? -1, accuracy: 0.001)
        XCTAssertEqual(merged?.weeklyResetText, incoming.weeklyResetText)
    }

    func testMergeMissingFiveHourWindowRejectsExpiredTmuxSessionLimit() {
        let now = ISO8601DateFormatter().date(from: "2026-06-23T01:31:00Z")!
        let incoming = ClaudeLimitSnapshot(
            fetchedAt: now,
            source: .oauthEndpoint,
            health: .live,
            fiveHourUsedRatio: 0.0,
            fiveHourResetText: "",
            weeklyUsedRatio: 0.03,
            weeklyResetText: "2027-01-19T09:00:00Z",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: "oauth-weekly-only"
        )
        let previous = ClaudeLimitSnapshot(
            fetchedAt: now.addingTimeInterval(-(31 * 60)),
            source: .tmuxUsage,
            health: .live,
            fiveHourUsedRatio: 0.24,
            fiveHourResetText: "11:20pm (America/Los_Angeles)",
            weeklyUsedRatio: 0.05,
            weeklyResetText: "Jun 28 at 5am (America/Los_Angeles)",
            weekOpusUsedRatio: nil,
            weekOpusResetText: nil,
            rawPayloadHash: nil
        )

        let merged = ClaudeUsageSourceManager.mergeMissingFiveHourWindow(
            incoming: incoming,
            previous: previous,
            now: now
        )

        XCTAssertNil(merged)
    }

    // MARK: - Success-path authoritative override (pure helpers)

    /// A healthy fetch NEVER alarms (verdict is always `.ok`): a signed-out CLI
    /// becomes a gentle caption — never a runway-hiding `.signedOut` — and every
    /// other status carries no caption.
    func testSuccessAdvisory() {
        XCTAssertEqual(ClaudeUsageSourceManager.successAdvisory(cli: .signedOut),
                       ClaudeUsageSourceManager.cliSignedOutAdvisory)
        XCTAssertNil(ClaudeUsageSourceManager.successAdvisory(cli: .signedIn))
        XCTAssertNil(ClaudeUsageSourceManager.successAdvisory(cli: .unknown))
        XCTAssertNil(ClaudeUsageSourceManager.successAdvisory(cli: .cliMissing))
    }

    /// Throttle predicate: never-probed (nil) → probe; older-than-interval →
    /// probe; within the interval → reuse cache.
    func testShouldReprobeThrottle() {
        let now = Date()
        XCTAssertTrue(ClaudeUsageSourceManager.shouldReprobe(lastAt: nil, now: now, interval: 120))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldReprobe(lastAt: now.addingTimeInterval(-120), now: now, interval: 120))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldReprobe(lastAt: now.addingTimeInterval(-121), now: now, interval: 120))
        XCTAssertFalse(ClaudeUsageSourceManager.shouldReprobe(lastAt: now.addingTimeInterval(-119), now: now, interval: 120))
        XCTAssertFalse(ClaudeUsageSourceManager.shouldReprobe(lastAt: now, now: now, interval: 120))
    }

    /// Regression for the wedge that only an app relaunch could clear: delegated
    /// CLI token refresh used to be a one-shot boolean latch, set on the first
    /// 401 and reset ONLY by a subsequent OAuth success. With an expired token +
    /// FDA-blocked web fallback, OAuth never succeeded, so the latch stayed true
    /// and the refresh that would have recovered the token (from a valid CLI) was
    /// never retried — for 9 hours, until relaunch built a fresh manager.
    ///
    /// The throttle must re-permit a refresh once the interval elapses, which a
    /// boolean latch structurally cannot express — that is the whole fix.
    func testDelegatedRefreshRethrottles_doesNotLatchOffUntilRelaunch() {
        let now = Date()
        let interval = ClaudeUsageSourceManager.delegatedRefreshRetryInterval

        // Never attempted this cycle → permitted (first 401).
        XCTAssertTrue(ClaudeUsageSourceManager.shouldAttemptDelegatedRefresh(lastAt: nil, now: now, interval: interval))
        // Just attempted → suppressed (don't hammer `claude auth status`).
        XCTAssertFalse(ClaudeUsageSourceManager.shouldAttemptDelegatedRefresh(lastAt: now, now: now, interval: interval))
        XCTAssertFalse(ClaudeUsageSourceManager.shouldAttemptDelegatedRefresh(lastAt: now.addingTimeInterval(-interval + 1), now: now, interval: interval))
        // The bug's core: after the interval, a still-401 token re-attempts the
        // refresh instead of latching off forever.
        XCTAssertTrue(ClaudeUsageSourceManager.shouldAttemptDelegatedRefresh(lastAt: now.addingTimeInterval(-interval), now: now, interval: interval))
        XCTAssertTrue(ClaudeUsageSourceManager.shouldAttemptDelegatedRefresh(lastAt: now.addingTimeInterval(-interval - 1), now: now, interval: interval))

        // A sane, non-hammering cadence: minutes, not seconds, not never.
        XCTAssertGreaterThanOrEqual(interval, 60)
        XCTAssertLessThanOrEqual(interval, 30 * 60)
    }

    // MARK: - Cold-start window (defers tmux/browser fallback)

    /// The cold-start window predicate gates whether a transient OAuth failure
    /// retries the (working) OAuth path or immediately spawns the tmux CLI probe
    /// that can pop a browser login. Inside the window → defer the fallback.
    func testColdStartWindow_boundaries() {
        let started = Date(timeIntervalSince1970: 1_000)
        // Just launched → inside the window.
        XCTAssertTrue(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: started, now: started))
        XCTAssertTrue(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: started, now: started.addingTimeInterval(10)))
        // 89s in (< 90s window) → still inside.
        XCTAssertTrue(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: started, now: started.addingTimeInterval(89)))
        // At/after the 90s window → outside; the fallback is allowed.
        XCTAssertFalse(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: started, now: started.addingTimeInterval(90)))
        XCTAssertFalse(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: started, now: started.addingTimeInterval(120)))
    }

    /// A nil `startedAt` (never started) is not a cold start — must not defer.
    func testColdStartWindow_nilStartIsNotColdStart() {
        XCTAssertFalse(ClaudeUsageSourceManager.isWithinColdStartWindow(
            startedAt: nil, now: Date()))
    }

    // MARK: - Reentrancy generation guard (I2)

    /// A verdict computation commits only while it is still the latest: captured
    /// generation must equal the current one. A newer computation (higher current)
    /// means the captured one is stale and its write must be dropped.
    func testVerdictIsCurrentGuard() {
        XCTAssertTrue(ClaudeUsageSourceManager.verdictIsCurrent(captured: 1, current: 1))
        XCTAssertTrue(ClaudeUsageSourceManager.verdictIsCurrent(captured: 7, current: 7))
        XCTAssertFalse(ClaudeUsageSourceManager.verdictIsCurrent(captured: 1, current: 2))
        XCTAssertFalse(ClaudeUsageSourceManager.verdictIsCurrent(captured: 5, current: 6))
    }

    // MARK: - Failure-path token routing (env-token `.expired`)

    /// Any token source — keychain, creds-file, OR the env token — counts as token
    /// evidence for the `was401 && hasToken` → `.expired` fast-path. Without env-token
    /// inclusion an expired env-token 401 would fall through to `.ok` (silent stall).
    func testHasAnyTokenIncludesEnvToken() {
        XCTAssertTrue(ClaudeUsageSourceManager.hasAnyToken(keychainFound: true, credsFilePresentToken: false, envTokenPresent: false))
        XCTAssertTrue(ClaudeUsageSourceManager.hasAnyToken(keychainFound: false, credsFilePresentToken: true, envTokenPresent: false))
        XCTAssertTrue(ClaudeUsageSourceManager.hasAnyToken(keychainFound: false, credsFilePresentToken: false, envTokenPresent: true))
        XCTAssertFalse(ClaudeUsageSourceManager.hasAnyToken(keychainFound: false, credsFilePresentToken: false, envTokenPresent: false))
    }

    // MARK: - 401 fresh-token immediate retry (2026-07-19 stale-cached-token race)

    func testShouldRetry401_freshTokenDiffers_retries() {
        XCTAssertTrue(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
            failedHash: "aaaa1111", freshHash: "bbbb2222", alreadyRetriedHash: nil))
    }

    func testShouldRetry401_sameToken_doesNotRetry() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
            failedHash: "aaaa1111", freshHash: "aaaa1111", alreadyRetriedHash: nil))
    }

    func testShouldRetry401_freshTokenAlreadyRetried_doesNotLoop() {
        // The same "fresh" token must only earn ONE immediate retry per episode,
        // otherwise a token that is new-but-still-invalid retries forever.
        XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
            failedHash: "aaaa1111", freshHash: "bbbb2222", alreadyRetriedHash: "bbbb2222"))
    }

    func testShouldRetry401_missingHashes_doesNotRetry() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
            failedHash: nil, freshHash: "bbbb2222", alreadyRetriedHash: nil))
        XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
            failedHash: "aaaa1111", freshHash: nil, alreadyRetriedHash: nil))
    }
}
