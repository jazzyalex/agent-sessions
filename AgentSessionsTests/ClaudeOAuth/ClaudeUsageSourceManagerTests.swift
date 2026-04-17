import XCTest
@testable import AgentSessions

final class ClaudeUsageSourceManagerTests: XCTestCase {

    // MARK: - Mode switching

    func testInit_tmuxOnlyMode_doesNotAttemptOAuth() async {
        var deliveredSnapshots: [ClaudeLimitSnapshot] = []
        let mgr = ClaudeUsageSourceManager()

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
        let mgr = ClaudeUsageSourceManager()
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
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.stop()
        await mgr.stop() // Should not crash
    }

    func testSetVisibility_doesNotCrash() async {
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .auto, handler: { _ in }, availabilityHandler: { _ in })
        await mgr.setVisibility(menuVisible: true, stripVisible: false, appIsActive: false)
        await mgr.setVisibility(menuVisible: false, stripVisible: true, appIsActive: true)
        await mgr.setVisibility(menuVisible: false, stripVisible: false, appIsActive: false)
        await mgr.stop()
    }

    // MARK: - Auto mode health description

    func testHealthDescription_noData_returnsPending() async {
        let mgr = ClaudeUsageSourceManager()
        // Don't start — just check initial state directly
        let health = await mgr.currentHealthDescription()
        XCTAssertEqual(health, "pending")
    }

    func testCurrentSourceDescription_oauthOnlyMode() async {
        let mgr = ClaudeUsageSourceManager()
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
        let mgr = ClaudeUsageSourceManager()
        await mgr.start(mode: .webOnly, handler: { _ in }, availabilityHandler: { _ in })
        let source = await mgr.currentSourceDescription()
        XCTAssertTrue(source.contains("Web API"), "webOnly mode should report Web API source, got: \(source)")
        await mgr.stop()
    }

    func testAutoMode_credentialGating_diagnosticsReflectWatchState() async {
        let mgr = ClaudeUsageSourceManager()
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

        XCTAssertEqual(plan, .timed(delay: 5 * 60))
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
        let mgr = ClaudeUsageSourceManager()
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
        XCTAssertNotEqual(restored?.health, .failed)
        XCTAssertEqual(restored?.fiveHourUsedRatio ?? 0, 0.4, accuracy: 0.001)
    }
}
