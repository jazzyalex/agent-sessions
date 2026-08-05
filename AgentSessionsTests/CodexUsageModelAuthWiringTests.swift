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
        XCTAssertNil(state.rateLimitedUntil)
    }

    func testOnlyAuthoritativeRejectionTriggersSilentCleanRecheck() {
        XCTAssertTrue(CodexUsageModel.shouldSilentlyRecheckAuth(.unauthorized))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.transient))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.skippedCooldown))
        XCTAssertFalse(CodexUsageModel.shouldSilentlyRecheckAuth(.ok(CodexUsageSnapshot())))
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
