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
