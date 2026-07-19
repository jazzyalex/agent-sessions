import XCTest
@testable import AgentSessions

/// Entry-point contract (plan Task 2): the busy guard is FIRST and rejects
/// synchronously without completion; disabled and alarming-auth guards are
/// ACCEPTED runs that complete synchronously exactly once. Uses the shared
/// singletons' synchronous guard paths only — no probe is spawned.
@MainActor
final class ProbeEntryPointTests: XCTestCase {
    func testClaudeBusyRejectsEvenWhileDisabled() {
        let model = ClaudeUsageModel.shared
        let wasUpdating = model.isUpdating
        defer { model.isUpdating = wasUpdating }
        model.isUpdating = true          // model is disabled by default under tests:
        var completions = 0              // busy must STILL win (busy-first ordering).
        XCTAssertFalse(model.hardProbeNowDiagnostics { _ in completions += 1 })
        XCTAssertEqual(completions, 0, "a rejected request must never complete")
    }

    func testCodexBusyRejectsEvenWhileDisabled() {
        let model = CodexUsageModel.shared
        let wasUpdating = model.isUpdating
        defer { model.isUpdating = wasUpdating }
        model.isUpdating = true
        var boolCompletions = 0
        XCTAssertFalse(model.hardProbeNow { _ in boolCompletions += 1 })
        XCTAssertEqual(boolCompletions, 0)
        var diagCompletions = 0
        XCTAssertFalse(model.hardProbeNowDiagnostics { _ in diagCompletions += 1 })
        XCTAssertEqual(diagCompletions, 0)
    }

    func testDisabledIsAcceptedAndCompletesSynchronously() {
        // Establish every precondition explicitly — shared singletons, and
        // XCTest ordering is not a contract (another test may have used the
        // enable seam or busy flag).
        let claude = ClaudeUsageModel.shared
        let codex = CodexUsageModel.shared
        let claudeWasUpdating = claude.isUpdating
        let codexWasUpdating = codex.isUpdating
        defer { claude.isUpdating = claudeWasUpdating; codex.isUpdating = codexWasUpdating }
        claude.isUpdating = false
        codex.isUpdating = false
        claude.setEnabledForTesting(false)
        codex.setEnabledForTesting(false)
        var claudeDiag: ClaudeProbeDiagnostics?
        XCTAssertTrue(ClaudeUsageModel.shared.hardProbeNowDiagnostics { claudeDiag = $0 })
        XCTAssertEqual(claudeDiag?.exitCode, 125, "disabled completes synchronously with the guard diagnostics")
        var codexBool: Bool?
        XCTAssertTrue(CodexUsageModel.shared.hardProbeNow { codexBool = $0 })
        XCTAssertEqual(codexBool, false)
        var codexDiag: CodexProbeDiagnostics?
        XCTAssertTrue(CodexUsageModel.shared.hardProbeNowDiagnostics { codexDiag = $0 })
        XCTAssertEqual(codexDiag?.exitCode, 125, "Codex disabled guard must complete synchronously (moved out of the Task)")
        XCTAssertFalse(CodexUsageModel.shared.isUpdating, "disabled guard must not leave isUpdating latched")
    }

    func testClaudeAlarmingAuthIsAcceptedAndCompletesSuppressed() {
        let model = ClaudeUsageModel.shared
        let savedAuth = model.authStatus
        let wasUpdating = model.isUpdating
        defer {
            model.authStatus = savedAuth
            model.isUpdating = wasUpdating
            model.setEnabledForTesting(false)
        }
        model.isUpdating = false
        model.setEnabledForTesting(true)
        model.authStatus = .make(provider: .claude, state: .expired)
        var received: ClaudeProbeDiagnostics?
        var completions = 0
        let accepted = model.hardProbeNowDiagnostics { diag in received = diag; completions += 1 }
        XCTAssertTrue(accepted, "an auth-suppressed run is accepted, not rejected")
        XCTAssertEqual(completions, 1, "guard short-circuit completes exactly once, synchronously")
        XCTAssertEqual(received?.exitCode, 126)
        XCTAssertEqual(received.map { ProbeCoordinator.outcome(claude: $0) }, .suppressed)
    }
}
