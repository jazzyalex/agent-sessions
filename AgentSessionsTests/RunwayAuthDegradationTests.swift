import XCTest
@testable import AgentSessions

/// P2/P3 pure-helper coverage for the cause-aware degradation work
/// (spec 2026-07-08-runway-auth-degradation-and-cli-fallback.md).
final class RunwayAuthDegradationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    // MARK: - Task 1: debounced .expired escalation

    func testNoFirst401NeverEscalates() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(first401At: nil, now: t0, threshold: 300))
    }

    func testUnderThresholdStaysCalm() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(299), threshold: 300))
    }

    func testAtThresholdEscalates() {
        XCTAssertTrue(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(300), threshold: 300))
    }

    func testExpiredPublicationPreEscalationHidesBannerShowsReason() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: false)
        XCTAssertNil(p.authState)                 // nil = "no auth update" — banner untouched
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }

    func testExpiredPublicationPostEscalationRaisesBanner() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: true)
        XCTAssertEqual(p.authState, .expired)
        XCTAssertNil(p.reason)
    }

    func testFailurePublicationAlarmingVerdictPassesThrough() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .signedOut)
        XCTAssertEqual(p.authState, .signedOut)
        XCTAssertNil(p.reason)
    }

    func testFailurePublicationUnknownCarriesCalmReason() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .unknown)
        XCTAssertEqual(p.authState, .unknown)
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }

    // MARK: - Task 7: no-CLI remediation ladder

    /// A CLI user keeps the copy-command chip.
    func testRemediationCLIPresentUsesLoginCommand() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .signedOut, cliPresent: true).remediation,
                       .showCommand("claude auth login"))
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .expired, cliPresent: true).remediation,
                       .showCommand("claude auth login"))
    }

    /// A no-CLI (Desktop-only) user gets the two-rung ladder for every alarming
    /// auth state, including `.cliNotInstalled` (which is CLI-less by definition).
    func testRemediationNoCLIUsesLadder() {
        for state in [UsageAuthState.signedOut, .expired, .cliNotInstalled] {
            let r = UsageAuthStatus.make(provider: .claude, state: state, cliPresent: false).remediation
            guard case .noCLILadder = r else {
                XCTFail("expected .noCLILadder for \(state), got \(r)"); continue
            }
        }
    }

    /// Ladder copy names both rungs (claude.ai Web API + CLI), drops the cancelled
    /// in-app sign-in promise, and never mentions Claude Desktop (rejected rung-1).
    func testNoCLILadderCopyHasBothRungsNoCancelledFeature() {
        let s = UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled, cliPresent: false)
        XCTAssertTrue(s.detail.contains("claude.ai"))                     // rung 1
        XCTAssertTrue(s.detail.contains("CLI"))                            // rung 2
        XCTAssertFalse(s.detail.lowercased().contains("coming soon"))
        XCTAssertFalse(s.detail.contains("Desktop"))
    }

    /// Codex is unaffected: it uses the `cliPresent: true` default and keeps its
    /// login command (no Web API rung exists for Codex).
    func testCodexRemediationUnchanged() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .codex, state: .signedOut).remediation,
                       .showCommand("codex login"))
    }

    // MARK: - Idle-token presentation (2026-07-12)
    //
    // A verified 401 while the CLI still reports signed-in and the SAME token
    // keeps failing is a routine inactivity lapse (nothing refreshes the access
    // token between sessions) — publish the calm `.idle` verdict, never the
    // alarming "auth expired / Fix…" banner. Only a DIFFERENT (externally
    // refreshed) token that still 401s, or a CLI that stops reporting
    // signed-in, falls back to the alarming expired path.

    func testExpired401PublicationSignedInSameTokenIsIdle() {
        let p = ClaudeUsageSourceManager.expired401Publication(
            cli: .signedIn, freshTokenStill401s: false, escalated: false)
        XCTAssertEqual(p.authState, .idle)
        XCTAssertNil(p.reason)
        // Idle outlasts the escalation threshold: a token can stay lapsed for
        // days while the CLI is signed in — that is still not an alarm.
        let p2 = ClaudeUsageSourceManager.expired401Publication(
            cli: .signedIn, freshTokenStill401s: false, escalated: true)
        XCTAssertEqual(p2.authState, .idle)
    }

    func testExpired401PublicationFreshTokenStill401sTakesExpiredPath() {
        let escalated = ClaudeUsageSourceManager.expired401Publication(
            cli: .signedIn, freshTokenStill401s: true, escalated: true)
        XCTAssertEqual(escalated.authState, .expired)
        XCTAssertNil(escalated.reason)
        let pre = ClaudeUsageSourceManager.expired401Publication(
            cli: .signedIn, freshTokenStill401s: true, escalated: false)
        XCTAssertNil(pre.authState)
        XCTAssertEqual(pre.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }

    func testExpired401PublicationNonSignedInCLIFallsBackToExpiredPath() {
        for cli in [CLIAuthStatus.signedOut, .unknown, .cliMissing] {
            let p = ClaudeUsageSourceManager.expired401Publication(
                cli: cli, freshTokenStill401s: false, escalated: true)
            XCTAssertEqual(p.authState, .expired, "cli \(cli) must keep the alarming path")
        }
    }

    func testIdleStateIsCalmWithNoRemediation() {
        XCTAssertFalse(UsageAuthState.idle.isAlarming)
        let s = UsageAuthStatus.make(provider: .claude, state: .idle)
        XCTAssertEqual(s.remediation, .none)
        XCTAssertTrue(s.headline.contains("No active"))
        XCTAssertEqual(s.chipLabel, "")
    }

    /// Claude's idle detail is the recovery ladder (2026-07-18): with the latch
    /// fix, the idle cell renders only when NO source is serving data — so its
    /// tooltip must say how to recover, not just "wait for the next session".
    /// Rungs: any CLI run refreshes the token; a pasted claude.ai cookie feeds
    /// the web path; the CLI probe is the last resort (works CLI-less-hostile
    /// cases but can consume tokens). Codex keeps the generic calm copy.
    func testClaudeIdleDetailCarriesRecoveryLadder() {
        let s = UsageAuthStatus.make(provider: .claude, state: .idle)
        XCTAssertTrue(s.detail.contains("claude"), "rung 1: run any claude CLI command")
        XCTAssertTrue(s.detail.lowercased().contains("cookie"), "rung 2: paste a claude.ai session cookie")
        XCTAssertTrue(s.detail.lowercased().contains("probe button"), "rung 3: QM toolbar probe button as last resort")
        XCTAssertTrue(s.detail.lowercased().contains("token"), "probe rung must carry its token-cost caveat")
        let codex = UsageAuthStatus.make(provider: .codex, state: .idle)
        XCTAssertTrue(codex.detail.contains("next Codex session"), "Codex idle copy stays generic")
    }

    /// A suppressed-fallback dead end re-emits the calm idle verdict instead of
    /// escalating the same lapsed token back to the alarming banner — and only
    /// remaps `.expired`-over-`.idle`; every other combination passes through.
    func testEffectiveEmitStatePreservesIdleOnlyForExpired() {
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.expired, lastPublished: .idle), .idle)
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.expired, lastPublished: .ok), .expired)
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.expired, lastPublished: nil), .expired)
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.signedOut, lastPublished: .idle), .signedOut)
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.cliNotInstalled, lastPublished: .idle), .cliNotInstalled)
        XCTAssertEqual(ClaudeUsageSourceManager.effectiveEmitState(.idle, lastPublished: .idle), .idle)
    }

    func testTokenFingerprintStableAndDistinct() {
        XCTAssertEqual(ClaudeUsageSourceManager.tokenFingerprint("sk-a"),
                       ClaudeUsageSourceManager.tokenFingerprint("sk-a"))
        XCTAssertNotEqual(ClaudeUsageSourceManager.tokenFingerprint("sk-a"),
                          ClaudeUsageSourceManager.tokenFingerprint("sk-b"))
    }

    /// The idle presentation wins over the reconnecting spinner (retrying alone
    /// never recovers a lapsed token), but an alarming verdict still wins over idle.
    func testQuotaDataIdlePresentationOrdering() {
        var q = QuotaData(provider: .claude, fiveHourRemainingPercent: 0, fiveHourResetText: "",
                          weekRemainingPercent: 0, weekResetText: "")
        q.authStatus = .make(provider: .claude, state: .idle)
        q.dataIsStale = true
        guard case .idle = q.presentationState else {
            return XCTFail("expected .idle, got \(q.presentationState)")
        }
        q.authStatus = .make(provider: .claude, state: .expired)
        guard case .needsAction = q.presentationState else {
            return XCTFail("alarming must win over idle, got \(q.presentationState)")
        }
    }

    /// Fresh live data must beat the idle latch (2026-07-18 incident): once the
    /// OAuth token lapses, the `.idle` verdict latches and — because web-fallback
    /// successes are caption-only emits — nothing on the web path ever clears it.
    /// The header must not keep saying "no active session" while fresh usage data
    /// is flowing from the web fallback; only alarming states may mask live data.
    func testQuotaDataFreshDataBeatsIdleLatch() {
        var q = QuotaData(provider: .claude, fiveHourRemainingPercent: 40, fiveHourResetText: "resets 5pm",
                          weekRemainingPercent: 80, weekResetText: "resets Fri")
        q.authStatus = .make(provider: .claude, state: .idle)
        q.lastUpdate = Date()          // fresh web-fallback fetch
        q.dataIsStale = false
        q.transientReason = nil
        guard case .live = q.presentationState else {
            return XCTFail("fresh usage data must render live, not idle — got \(q.presentationState)")
        }
        // Once the data stales out again, idle resumes.
        q.dataIsStale = true
        guard case .idle = q.presentationState else {
            return XCTFail("stale data with idle auth must fall back to idle, got \(q.presentationState)")
        }
    }

    // MARK: - Web API cause-aware cookie read (2026-07-12)

    /// TCC denial (needs Full Disk Access) must classify as a permission
    /// problem; a missing file or network-ish error must not.
    func testCookiePermissionDenialClassification() {
        XCTAssertTrue(ClaudeWebCookieResolver.isPermissionDenial(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(ClaudeWebCookieResolver.isPermissionDenial(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(ClaudeWebCookieResolver.isPermissionDenial(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(ClaudeWebCookieResolver.isPermissionDenial(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
        XCTAssertFalse(ClaudeWebCookieResolver.isPermissionDenial(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    // MARK: - Task 14: auto-mode interactive fallback is opt-in

    func testTmuxFallbackPermitted() {
        // tmuxOnly is inherently opted in — the user chose the probe as their mode.
        XCTAssertTrue(ClaudeUsageSourceManager.tmuxFallbackPermitted(mode: .tmuxOnly, optIn: false))
        XCTAssertTrue(ClaudeUsageSourceManager.tmuxFallbackPermitted(mode: .tmuxOnly, optIn: true))
        // auto / oauthOnly / webOnly require the explicit opt-in (default OFF).
        for mode in [ClaudeUsageMode.auto, .oauthOnly, .webOnly] {
            XCTAssertFalse(ClaudeUsageSourceManager.tmuxFallbackPermitted(mode: mode, optIn: false))
            XCTAssertTrue(ClaudeUsageSourceManager.tmuxFallbackPermitted(mode: mode, optIn: true))
        }
    }
}
