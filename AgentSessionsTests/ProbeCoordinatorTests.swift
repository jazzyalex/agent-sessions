import XCTest
@testable import AgentSessions

/// ProbeCoordinator (2026-07-18 spec): single acceptance gate for hard probes.
/// Synchronous accept/reject, per-provider independent state, expiry as data,
/// generation guard, one-shot completions, and correct handling of
/// SYNCHRONOUS completions — including buffering so `request` never returns
/// false after having delivered a completion.
@MainActor
final class ProbeCoordinatorTests: XCTestCase {
    private func claudeDiag(success: Bool, exitCode: Int32, unavailable: String? = nil) -> ClaudeProbeDiagnostics {
        ClaudeProbeDiagnostics(success: success, exitCode: exitCode, scriptPath: "t", workdir: "t",
                               claudeBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "",
                               unavailableMessage: unavailable, snapshot: nil)
    }
    private func codexDiag(success: Bool, exitCode: Int32) -> CodexProbeDiagnostics {
        CodexProbeDiagnostics(success: success, exitCode: exitCode, scriptPath: "t", workdir: "t",
                              codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "")
    }
    /// Coordinator with async (stored-callback) runners and idle models.
    private func makeAsyncSUT() -> (ProbeCoordinator,
                                    claude: () -> ((ClaudeProbeDiagnostics) -> Void)?,
                                    codex: () -> ((CodexProbeDiagnostics) -> Void)?) {
        var claudeCB: ((ClaudeProbeDiagnostics) -> Void)?
        var codexCB: ((CodexProbeDiagnostics) -> Void)?
        let c = ProbeCoordinator(claudeRunner: { cb in claudeCB = cb; return true },
                                 codexRunner: { cb in codexCB = cb; return true },
                                 claudeModelBusy: { false },
                                 codexModelBusy: { false })
        return (c, { claudeCB }, { codexCB })
    }

    func testRequestStartsProbingAndRejectsWhileBusy() {
        let (c, _, _) = makeAsyncSUT()
        XCTAssertTrue(c.request(.claude))
        guard case .probing = c.state(for: .claude) else { return XCTFail("expected .probing") }
        XCTAssertFalse(c.request(.claude), "second request while busy must be rejected synchronously")
    }

    func testRunnerDeclineRollsBackToNoneWithoutCompletion() {
        var completions = 0
        let c = ProbeCoordinator(claudeRunner: { _ in false }, codexRunner: { _ in false },
                                 claudeModelBusy: { false }, codexModelBusy: { false })
        XCTAssertFalse(c.request(.claude) { _ in completions += 1 })
        XCTAssertEqual(c.state(for: .claude), .none, "a declined runner must roll .probing back")
        XCTAssertEqual(completions, 0, "request == false must mean completion never fired")
    }

    func testProvidersAreIndependent() {
        let (c, _, _) = makeAsyncSUT()
        XCTAssertTrue(c.request(.claude))
        XCTAssertTrue(c.request(.codex), "a busy Claude must not block Codex")
    }

    // MARK: Synchronous completions

    func testSynchronousSuppressedCompletionClearsStateAndDelivers() {
        let c = ProbeCoordinator(
            claudeRunner: { cb in cb(self.claudeDiag(success: false, exitCode: 126)); return true },
            codexRunner: { _ in false },
            claudeModelBusy: { false }, codexModelBusy: { false })
        var report: ProbeCoordinator.ProbeReport?
        XCTAssertTrue(c.request(.claude) { report = $0 })
        XCTAssertEqual(c.state(for: .claude), .none, "sync suppressed completion must not leave .probing wedged")
        XCTAssertEqual(report?.outcome, .suppressed, "buffered sync report must be delivered on acceptance")
    }

    func testSynchronousFailedCompletionSetsFailedState() {
        let c = ProbeCoordinator(
            claudeRunner: { cb in cb(self.claudeDiag(success: false, exitCode: 1)); return true },
            codexRunner: { _ in false },
            claudeModelBusy: { false }, codexModelBusy: { false })
        XCTAssertTrue(c.request(.claude))
        guard case .failed = c.state(for: .claude) else { return XCTFail("expected .failed") }
    }

    func testMalformedCompleteThenDeclineIsCleanRejection() {
        // Completes synchronously AND returns false: the report is discarded
        // with the rollback — false ⇒ no completion, state back to .none.
        var completions = 0
        let c = ProbeCoordinator(
            claudeRunner: { cb in cb(self.claudeDiag(success: false, exitCode: 1)); return false },
            codexRunner: { _ in false },
            claudeModelBusy: { false }, codexModelBusy: { false })
        XCTAssertFalse(c.request(.claude) { _ in completions += 1 })
        XCTAssertEqual(c.state(for: .claude), .none)
        XCTAssertEqual(completions, 0, "a declined run must not have delivered its buffered report")
    }

    // MARK: Async lifecycle

    func testFailureSetsDeadlineAndExpiresAsData() {
        let (c, claude, _) = makeAsyncSUT()
        XCTAssertTrue(c.request(.claude))
        claude()?(claudeDiag(success: false, exitCode: 1))
        guard case .failed(let until, _) = c.state(for: .claude) else { return XCTFail("expected .failed") }
        XCTAssertEqual(until.timeIntervalSinceNow, ProbeCoordinator.failureDisplayDuration, accuracy: 2.0)
        XCTAssertEqual(c.displayState(for: .claude, now: until.addingTimeInterval(1)), .none,
                       "expiry is data — an expired deadline displays as .none")
        guard case .failed = c.displayState(for: .claude, now: until.addingTimeInterval(-1)) else {
            return XCTFail("not-yet-expired must still display .failed")
        }
    }

    func testStaleDoubleFireIsSwallowedByOneShotGuard() {
        let (c, claude, _) = makeAsyncSUT()
        var completions = 0
        XCTAssertTrue(c.request(.claude) { _ in completions += 1 })
        let firstCB = claude()
        firstCB?(claudeDiag(success: false, exitCode: 1))              // gen1 -> .failed, delivers
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(c.request(.claude))                              // gen2 -> .probing
        guard case .probing(let gen2) = c.state(for: .claude) else { return XCTFail() }
        firstCB?(claudeDiag(success: true, exitCode: 0))               // stale gen1 double-fire
        XCTAssertEqual(completions, 1, "one-shot: stale double-fire must not re-deliver")
        guard case .probing(let still) = c.state(for: .claude), still == gen2 else {
            return XCTFail("stale completion must not clear the newer probe")
        }
        claude()?(claudeDiag(success: true, exitCode: 0))              // gen2 completes ok
        XCTAssertEqual(c.state(for: .claude), .none)
    }

    func testSynchronousDoubleFireDeliversFirstReportOnce() {
        // Malformed runner: two synchronous callbacks, then accepts. The
        // buffer is first-report-wins and deliver is one-shot, so exactly one
        // completion fires, carrying the FIRST report (.failed).
        var completions = 0
        var outcome: ProbeCoordinator.Outcome?
        let c = ProbeCoordinator(
            claudeRunner: { cb in
                cb(self.claudeDiag(success: false, exitCode: 1))
                cb(self.claudeDiag(success: true, exitCode: 0))
                return true
            },
            codexRunner: { _ in false },
            claudeModelBusy: { false }, codexModelBusy: { false })
        XCTAssertTrue(c.request(.claude) { completions += 1; outcome = $0.outcome })
        XCTAssertEqual(completions, 1, "one-shot must hold across synchronous double-fires")
        XCTAssertEqual(outcome, .failed, "first report wins")
        guard case .failed = c.state(for: .claude) else { return XCTFail("state reflects the first report") }
    }

    // MARK: Outcome mapping

    func testOutcomeMapping() {
        XCTAssertEqual(ProbeCoordinator.outcome(claude: claudeDiag(success: true, exitCode: 0)), .ok)
        XCTAssertEqual(ProbeCoordinator.outcome(claude: claudeDiag(success: true, exitCode: 0, unavailable: "x")), .suppressed)
        XCTAssertEqual(ProbeCoordinator.outcome(claude: claudeDiag(success: false, exitCode: 126)), .suppressed)
        XCTAssertEqual(ProbeCoordinator.outcome(claude: claudeDiag(success: false, exitCode: 125)), .suppressed)
        XCTAssertEqual(ProbeCoordinator.outcome(claude: claudeDiag(success: false, exitCode: 1)), .failed)
        XCTAssertEqual(ProbeCoordinator.outcome(codex: codexDiag(success: true, exitCode: 0)), .ok)
        XCTAssertEqual(ProbeCoordinator.outcome(codex: codexDiag(success: false, exitCode: 126)), .suppressed)
        XCTAssertEqual(ProbeCoordinator.outcome(codex: codexDiag(success: false, exitCode: 125)), .suppressed)
        XCTAssertEqual(ProbeCoordinator.outcome(codex: codexDiag(success: false, exitCode: 2)), .failed)
    }

    // MARK: Probe Both

    func testRequestBothRejectsWhenEitherCoordinatorBusy() {
        let (c, _, _) = makeAsyncSUT()
        XCTAssertTrue(c.request(.codex))
        XCTAssertFalse(c.requestBoth(), "either provider coordinator-busy must reject Both without starting anything")
        XCTAssertEqual(c.state(for: .claude), .none, "Claude must not have been started by the rejected Both")
    }

    func testRequestBothRejectsWhenEitherModelBusy() {
        // Coordinator idle but the model is mid-refresh (isUpdating covers
        // ordinary refreshes too): Both must reject without invoking EITHER
        // runner — no partial start.
        var claudeRunnerCalls = 0
        var codexRunnerCalls = 0
        let c = ProbeCoordinator(
            claudeRunner: { _ in claudeRunnerCalls += 1; return true },
            codexRunner: { _ in codexRunnerCalls += 1; return true },
            claudeModelBusy: { false },
            codexModelBusy: { true })
        XCTAssertFalse(c.requestBoth())
        XCTAssertEqual(claudeRunnerCalls, 0, "no runner may be invoked by a rejected Both")
        XCTAssertEqual(codexRunnerCalls, 0)
        XCTAssertEqual(c.state(for: .claude), .none)
        XCTAssertEqual(c.state(for: .codex), .none)
    }

    func testRequestBothStartsBothIndependently() {
        let (c, claude, codex) = makeAsyncSUT()
        XCTAssertTrue(c.requestBoth())
        claude()?(claudeDiag(success: false, exitCode: 1))   // Claude fails fast
        guard case .failed = c.state(for: .claude) else { return XCTFail() }
        guard case .probing = c.state(for: .codex) else { return XCTFail("Codex lifecycle is independent") }
        codex()?(codexDiag(success: true, exitCode: 0))
        XCTAssertEqual(c.state(for: .codex), .none)
    }
}
