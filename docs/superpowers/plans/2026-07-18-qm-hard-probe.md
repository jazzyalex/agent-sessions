# QM Hard-Probe (Toolbar Trigger + Per-Provider Feedback) Implementation Plan — v3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

v3 applies the second Codex review: busy-first guard ordering in every entry point, Codex disabled-guard hoisted out of its Task (synchronous completion), a DEBUG `setEnabledForTesting` seam so the entry-point tests actually reach their paths, coordinator buffering of synchronous reports so a `false` return never follows a delivered completion (one-shot per run), `requestBoth` gated on injected model-busy checks so Probe Both cannot partially start, menu eligibility including model `isUpdating`, Preferences running-flag ordering that survives synchronous completions, and per-site clock identifiers in Task 5.

**Goal:** Replace the QM's undiscoverable double-click hard probe with a toolbar button + per-click provider menu, backed by a per-provider ProbeCoordinator that gives reliable "probing… / probe failed" in-row feedback.

**Architecture:** A `@MainActor` `ProbeCoordinator` (new file, `AgentSessions/Shared/`) is the single acceptance gate for hard probes from every surface (QM toolbar, menu-bar dropdown, Preferences probes, main-window strip). It wraps the model entry points — fixed in Task 2 so busy is a synchronous rejection and every accepted run completes exactly once with full diagnostics — and publishes per-provider `ProbeRowState` (probing / failed-until, generation-stamped). The three QM provider-row render sites read that state with precedence `needsAction > probe state > idle/reconnecting/live`.

**Tech Stack:** Swift / SwiftUI, XCTest, xcodebuild.

Spec: `docs/superpowers/specs/2026-07-18-qm-hard-probe-design.md`

## Global Constraints

- **NO git commits.** Repo policy: the owner commits. Each task ends at green tests; a final commit checklist is presented to the owner at the end.
- QM window height must never change from probe chrome or row-state swaps — all feedback swaps text inside existing fixed-height rows.
- New Swift files are added to the Xcode project with the four-argument script form: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE> <GROUP>`. Check the `project.pbxproj` diff for exactly one new reference per file (known duplicate-ref gotcha).
- Full test suite command: `xcodebuild test -scheme AgentSessions -destination 'platform=macOS' -derivedDataPath .deriveddata-tests -quiet`. Verify with: `xcrun xcresulttool get test-results summary --path $(ls -td .deriveddata-tests/Logs/Test/*.xcresult | head -1)`.
- Never launch the app from `.deriveddata-tests`. Build for running with default DerivedData: `xcodebuild -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build -quiet`.
- **Entry-point contract (Task 2, all three hard-probe entry points, guards in this exact order):**
  1. *Busy* (`isUpdating` already true) → synchronous rejection: return `false`, completion is **never** called. The busy guard is FIRST — busy always wins, regardless of disabled/auth state.
  2. *Disabled tracking* → **accepted**: return `true`, completes **synchronously** (before returning) with the existing guard diagnostics (exit 125 / `completion(false)` for Codex's Bool variant).
  3. *Auth-suppressed* (Claude alarming-auth guard, exit 126) → **accepted**: return `true`, completes synchronously. (Claude's in-Task CLI-status suppression stays an accepted asynchronous completion.)
  4. Otherwise → accepted: return `true`, completes exactly once asynchronously.
- **Outcome mapping** (coordinator, both providers): Claude `success && unavailableMessage != nil` → `.suppressed`; `success` → `.ok`; `!success && (exitCode == 126 || exitCode == 125)` → `.suppressed`; otherwise → `.failed`.
- **Coordinator completion contract:** `request(...) == false` ⇒ the caller's completion is never invoked (synchronous reports from a runner that then declines are discarded with the state rollback). Each accepted run's completion fires exactly once (stale double-fires are swallowed).
- Failure feedback duration: **8 seconds**, per provider, starting at that provider's completion.
- No test may spawn a real probe (tmux/CLI). Model-level tests exercise only synchronous guard paths (busy, disabled, alarming-auth) that return before any service is built.

---

### Task 1: Remove the overlay prototype, the QM double-click sites, and the obsolete tests

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift`
- Modify: `AgentSessionsTests/HUDRebuildGateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a clean baseline — no `HUDProbeFeedback`, no `HUDProbeFeedbackTag`, no `.onTapGesture(count: 2)` in the QM, no `HUDProbeFeedbackSummaryTests`.

- [ ] **Step 1: Delete the prototype types.** In `AgentSessions/Views/AgentCockpitHUDView.swift`, delete the entire `final class HUDProbeFeedback` (from its doc comment `/// Shared feedback state for the QM double-click hard probe…` through its closing brace) and the entire `private struct HUDProbeFeedbackTag` — both sit immediately above `private struct HUDLimitsBar: View`.

- [ ] **Step 2: Delete the prototype wiring.** In the same file remove:
  - the line `@ObservedObject private var probeFeedback = HUDProbeFeedback.shared` in **both** `HUDLimitsBar` and `HUDLimitsRowsPanel`;
  - both `.overlay(alignment: .bottomTrailing) { if let message = probeFeedback.message { HUDProbeFeedbackTag(message: message) } }` modifiers;
  - both `.onTapGesture(count: 2) { HUDProbeFeedback.shared.trigger(...) }` modifiers **entirely** (the QM double-click is retired; do not restore the old handler bodies).

- [ ] **Step 3: Delete the obsolete test class.** In `AgentSessionsTests/HUDRebuildGateTests.swift`, delete the entire `final class HUDProbeFeedbackSummaryTests: XCTestCase { … }` including its doc comment.

- [ ] **Step 4: Run the full suite.** Expected: build succeeds, all tests pass (count drops by 4 vs the last run).

### Task 2: Entry-point contract — busy-first synchronous rejection, always-completing accepted runs

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift` (`CodexUsageModel.hardProbeNow` ~line 371, `hardProbeNowDiagnostics` ~line 414, plus a DEBUG seam near `setEnabled` ~line 258)
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` (`hardProbeNowDiagnostics` ~line 401, plus a DEBUG seam near `setEnabled` ~line 110)
- Test: `AgentSessionsTests/ProbeEntryPointTests.swift` (new; added via `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/ProbeEntryPointTests.swift AgentSessionsTests`)

**Interfaces:**
- Consumes: existing probe internals (`forceProbeNow`), unchanged.
- Produces (Task 3 relies on these exact signatures):
  - Codex: `@discardableResult func hardProbeNow(completion: @escaping (Bool) -> Void) -> Bool`
  - Codex: `@discardableResult func hardProbeNowDiagnostics(completion: @escaping (CodexProbeDiagnostics) -> Void) -> Bool`
  - Claude: `@discardableResult func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) -> Bool`
  - DEBUG-only: `func setEnabledForTesting(_ enabled: Bool)` on both models — sets the private `isEnabled` stored property directly **without** calling `start()`/side effects (the existing `setEnabled` deliberately no-ops under tests).
  - All follow the Global Constraints entry-point contract (busy guard first).

- [ ] **Step 1: Add the DEBUG seams.** In each model, next to the existing `#if DEBUG` helpers (Claude has `cliPresenceOverrideForTesting`), add:

```swift
    #if DEBUG
    /// Test seam: the public setEnabled() deliberately no-ops under tests so
    /// suites never spawn services; entry-point contract tests still need to
    /// exercise the enabled guard ordering. Sets the flag only — no start().
    func setEnabledForTesting(_ enabled: Bool) { isEnabled = enabled }
    #endif
```

- [ ] **Step 2: Write the failing regression tests** in `AgentSessionsTests/ProbeEntryPointTests.swift`. Synchronous guard paths only — no probe is ever spawned; all mutated state restored:

```swift
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
```

(The `ProbeCoordinator.outcome(claude:)` assertion references Task 3; while executing Task 2 alone, comment that single line out and re-enable it in Task 3, Step 5.)

- [ ] **Step 3: Run the new tests; expected FAIL** — compile errors on `-> Bool` and `setEnabledForTesting` (once the seam from Step 1 is in, remaining failures are the missing busy guards / return values).

- [ ] **Step 4: Codex `hardProbeNow`** — busy first, disabled synchronous-accepted:

```swift
    @discardableResult
    func hardProbeNow(completion: @escaping (Bool) -> Void) -> Bool {
        if isUpdating { return false }
        guard isEnabled else {
            completion(false)   // disabled = accepted, completes synchronously (existing UX)
            return true
        }
        refreshResetCredits()
        isUpdating = true
        Task { [weak self] in
            // …existing body unchanged…
        }
        return true
    }
```

(`refreshResetCredits()` moves below the disabled guard, where it effectively already was; it no longer runs for busy calls — it previously ran before the busy check, but a busy model is refreshing anyway.)

- [ ] **Step 5: Codex `hardProbeNowDiagnostics`** — busy first, disabled guard hoisted OUT of the Task so it completes synchronously and never touches `isUpdating`:

```swift
    @discardableResult
    func hardProbeNowDiagnostics(completion: @escaping (CodexProbeDiagnostics) -> Void) -> Bool {
        if isUpdating { return false }
        guard isEnabled else {
            completion(CodexProbeDiagnostics(
                success: false,
                exitCode: 125,
                scriptPath: "(not run)",
                workdir: CodexProbeConfig.probeWorkingDirectory(),
                codexBin: nil,
                tmuxBin: nil,
                timeoutSecs: nil,
                stdout: "",
                stderr: "Codex usage tracking is disabled"
            ))
            return true
        }
        isUpdating = true
        Task { [weak self] in
            guard let self = self else { return }
            // …existing service branches; delete the old in-Task isEnabled guard.
            // BOTH remaining branches (long-lived service, short-lived service)
            // must clear the flag in their MainActor.run before completion(diag):
            //     self.isUpdating = false
            //     completion(diag)
        }
        return true
    }
```

- [ ] **Step 6: Claude `hardProbeNowDiagnostics`** — busy guard moves to the TOP (currently it sits after the disabled and alarming-auth guards at ~line 426):

```swift
    @discardableResult
    func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) -> Bool {
        if isUpdating { return false }
        guard isEnabled else {
            // …existing exit-125 diagnostics completion unchanged…
            completion(diag)
            return true
        }
        if let state = authStatus?.state, state.isAlarming {
            completion(Self.suppressedHardProbeDiagnostics())
            return true
        }
        isUpdating = true
        Task { [weak self] in
            // …existing body unchanged (incl. the async CLI-status suppressed branch)…
        }
        return true
    }
```

- [ ] **Step 7: Run the new test file** (Task-3 line commented): expected PASS. Then the full suite: expected all green (existing callers compile unchanged thanks to `@discardableResult`).

### Task 3: ProbeCoordinator (TDD)

**Files:**
- Create: `AgentSessions/Shared/ProbeCoordinator.swift`
- Test: create `AgentSessionsTests/ProbeCoordinatorTests.swift`
- Modify: `AgentSessionsTests/ProbeEntryPointTests.swift` (re-enable the commented outcome-mapping line)

**Interfaces:**
- Consumes: Task 2's entry-point contracts (initializer-injected closures), model busy flags (injected closures).
- Produces (Tasks 4–6 rely on these):

```swift
@MainActor
final class ProbeCoordinator: ObservableObject {
    static let shared = ProbeCoordinator()

    enum ProbeRowState: Equatable {
        case none
        case probing(generation: UInt64)
        case failed(until: Date, generation: UInt64)
    }
    enum Outcome: Equatable { case ok, failed, suppressed }
    enum ProbeReport {
        case claude(ClaudeProbeDiagnostics)
        case codex(CodexProbeDiagnostics)
        var outcome: Outcome { get }
    }

    static let failureDisplayDuration: TimeInterval = 8

    @Published private(set) var claudeState: ProbeRowState = .none
    @Published private(set) var codexState: ProbeRowState = .none

    init(claudeRunner: … = …, codexRunner: … = …,
         claudeModelBusy: @escaping () -> Bool = { ClaudeUsageModel.shared.isUpdating },
         codexModelBusy: @escaping () -> Bool = { CodexUsageModel.shared.isUpdating })

    static func outcome(claude diag: ClaudeProbeDiagnostics) -> Outcome
    static func outcome(codex diag: CodexProbeDiagnostics) -> Outcome
    func state(for source: UsageTrackingSource) -> ProbeRowState
    func isBusy(_ source: UsageTrackingSource) -> Bool
    func displayState(for source: UsageTrackingSource, now: Date) -> ProbeRowState
    @discardableResult func request(_ source: UsageTrackingSource,
                                    completion: ((ProbeReport) -> Void)? = nil) -> Bool
    @discardableResult func requestBoth() -> Bool
}
```

- [ ] **Step 1: Write the failing tests** in `AgentSessionsTests/ProbeCoordinatorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail.** Expected: compile error — `ProbeCoordinator` not defined. (If the diagnostics structs' memberwise inits differ from the helpers, adjust the helpers to the real fields — `CodexStatusService.swift` ~line 2653 / `ClaudeStatusService.swift` ~line 1628.)

- [ ] **Step 3: Implement** `AgentSessions/Shared/ProbeCoordinator.swift`:

```swift
import SwiftUI

/// Single authoritative acceptance gate for manual hard probes (spec
/// 2026-07-18-qm-hard-probe-design). Every surface (QM toolbar, menu-bar
/// dropdown, Preferences probes, main-window strip) requests probes here so
/// two surfaces can never race the same provider, and "probing…"/"probe
/// failed" row feedback can never wedge: acceptance is synchronous, accepted
/// runs complete exactly once (Task 2 contract), synchronous reports are
/// buffered until acceptance is known (so `false` NEVER follows a delivered
/// completion), and failure expiry is data (a deadline) evaluated against
/// the caller's clock — not a sleeping UI task. Lives at app level (outlives
/// the QM window) so closing/reopening the QM mid-probe shows the truth.
@MainActor
final class ProbeCoordinator: ObservableObject {
    static let shared = ProbeCoordinator()

    enum ProbeRowState: Equatable {
        case none
        case probing(generation: UInt64)
        case failed(until: Date, generation: UInt64)
    }

    /// Guard short-circuits (auth unsafe: 126, tracking disabled: 125, or a
    /// successful run that reports usage unavailable) are `.suppressed`, never
    /// `.failed`: a guard declining to spawn an unsafe probe is not a failed
    /// probe and must not render "probe failed".
    enum Outcome: Equatable { case ok, failed, suppressed }

    /// Typed completion so alert/dialog surfaces (menu-bar dropdown,
    /// Preferences) keep their full-diagnostics presentation while still
    /// routing acceptance through the coordinator.
    enum ProbeReport {
        case claude(ClaudeProbeDiagnostics)
        case codex(CodexProbeDiagnostics)

        var outcome: Outcome {
            switch self {
            case .claude(let d): return ProbeCoordinator.outcome(claude: d)
            case .codex(let d): return ProbeCoordinator.outcome(codex: d)
            }
        }
    }

    static let failureDisplayDuration: TimeInterval = 8

    @Published private(set) var claudeState: ProbeRowState = .none
    @Published private(set) var codexState: ProbeRowState = .none

    private let claudeRunner: (@escaping (ClaudeProbeDiagnostics) -> Void) -> Bool
    private let codexRunner: (@escaping (CodexProbeDiagnostics) -> Void) -> Bool
    /// `isUpdating` covers ordinary refreshes too, so coordinator-idle does
    /// not imply the model will accept; `requestBoth` needs both checks
    /// up front to guarantee it never partially starts.
    private let claudeModelBusy: () -> Bool
    private let codexModelBusy: () -> Bool
    private var generation: UInt64 = 0

    init(claudeRunner: @escaping (@escaping (ClaudeProbeDiagnostics) -> Void) -> Bool = { completion in
             ClaudeUsageModel.shared.hardProbeNowDiagnostics(completion: completion)
         },
         codexRunner: @escaping (@escaping (CodexProbeDiagnostics) -> Void) -> Bool = { completion in
             CodexUsageModel.shared.hardProbeNowDiagnostics(completion: completion)
         },
         claudeModelBusy: @escaping () -> Bool = { ClaudeUsageModel.shared.isUpdating },
         codexModelBusy: @escaping () -> Bool = { CodexUsageModel.shared.isUpdating }) {
        self.claudeRunner = claudeRunner
        self.codexRunner = codexRunner
        self.claudeModelBusy = claudeModelBusy
        self.codexModelBusy = codexModelBusy
    }

    static func outcome(claude diag: ClaudeProbeDiagnostics) -> Outcome {
        if diag.success { return diag.unavailableMessage != nil ? .suppressed : .ok }
        return (diag.exitCode == 126 || diag.exitCode == 125) ? .suppressed : .failed
    }

    static func outcome(codex diag: CodexProbeDiagnostics) -> Outcome {
        if diag.success { return .ok }
        return (diag.exitCode == 126 || diag.exitCode == 125) ? .suppressed : .failed
    }

    func state(for source: UsageTrackingSource) -> ProbeRowState {
        source == .claude ? claudeState : codexState
    }

    func isBusy(_ source: UsageTrackingSource) -> Bool {
        if case .probing = state(for: source) { return true }
        return false
    }

    /// Expiry as data: a `.failed` whose deadline has passed displays as
    /// `.none`. Render against the QM's shared clock tick.
    func displayState(for source: UsageTrackingSource, now: Date) -> ProbeRowState {
        let s = state(for: source)
        if case .failed(let until, _) = s, now >= until { return .none }
        return s
    }

    /// Synchronous acceptance: `true` = probe started (state -> .probing,
    /// `completion` fires exactly once with the provider's diagnostics);
    /// `false` = rejected — state untouched/rolled back and `completion` is
    /// NEVER called, even if a malformed runner completed before declining
    /// (its report is buffered until acceptance is known, then discarded).
    ///
    /// Ordering: `.probing` is installed BEFORE the runner so the row state
    /// exists for the run; synchronous reports are buffered and applied after
    /// the runner accepts, async reports apply directly. Both paths go
    /// through one-shot `deliver`, so a stale double-fire can neither flip
    /// row state (generation guard) nor re-invoke the caller's completion.
    @discardableResult
    func request(_ source: UsageTrackingSource,
                 completion: ((ProbeReport) -> Void)? = nil) -> Bool {
        guard !isBusy(source) else { return false }
        generation += 1
        let gen = generation
        setState(.probing(generation: gen), for: source)

        var acceptanceKnown = false
        var buffered: ProbeReport?
        var delivered = false
        let deliver: (ProbeReport) -> Void = { [weak self] report in
            guard !delivered else { return }
            delivered = true
            if let self,
               case .probing(let current) = self.state(for: source), current == gen {
                switch report.outcome {
                case .ok, .suppressed:
                    self.setState(.none, for: source)
                case .failed:
                    self.setState(.failed(until: Date().addingTimeInterval(Self.failureDisplayDuration),
                                          generation: gen), for: source)
                }
            }
            completion?(report)
        }
        let handle: (ProbeReport) -> Void = { report in
            if acceptanceKnown {
                deliver(report)
            } else if buffered == nil {
                // First-report-wins: a malformed runner double-firing
                // synchronously must deliver its FIRST report, mirroring the
                // one-shot guarantee `deliver` enforces on the async path.
                buffered = report
            }
        }

        let accepted: Bool
        if source == .claude {
            accepted = claudeRunner { handle(.claude($0)) }
        } else {
            accepted = codexRunner { handle(.codex($0)) }
        }
        acceptanceKnown = true
        guard accepted else {
            // Rejected: discard any buffered synchronous report and roll back
            // this generation's `.probing` (only if it still stands).
            if case .probing(let current) = state(for: source), current == gen {
                setState(.none, for: source)
            }
            return false
        }
        if let report = buffered { deliver(report) }
        return true
    }

    /// Atomic eligibility for "Probe Both": rejected outright unless BOTH
    /// providers are coordinator-idle AND both models can accept right now —
    /// no runner is invoked on rejection, so Both can never silently degrade
    /// to probing one provider. All checks and both runner invocations happen
    /// synchronously on the main actor, so nothing can flip in between.
    @discardableResult
    func requestBoth() -> Bool {
        guard !isBusy(.claude), !isBusy(.codex),
              !claudeModelBusy(), !codexModelBusy() else { return false }
        let claudeStarted = request(.claude)
        let codexStarted = request(.codex)
        return claudeStarted && codexStarted
    }

    private func setState(_ s: ProbeRowState, for source: UsageTrackingSource) {
        if source == .claude { claudeState = s } else { codexState = s }
    }
}
```

- [ ] **Step 4: Add both files to the Xcode project:**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Shared/ProbeCoordinator.swift AgentSessions/Shared
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/ProbeCoordinatorTests.swift AgentSessionsTests
```

Check the `project.pbxproj` diff: exactly one reference per file, correct targets.

- [ ] **Step 5: Re-enable** the commented `ProbeCoordinator.outcome(claude:)` assertion in `ProbeEntryPointTests.swift`.

- [ ] **Step 6: Run the full suite.** Expected: all green including the new coordinator + entry-point tests.

### Task 4: QM toolbar probe button with provider menu

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (toolbar cluster `limitsToolbarCluster` ~line 1573, its owning view `AgentCockpitHUDView`'s state ~line 760, and `isToolbarPopoverOpen` ~line 1203)

**Interfaces:**
- Consumes: `ProbeCoordinator.shared.request(_:)`, `.requestBoth()`, `.isBusy(_:)`, both usage models' `isUpdating`.
- Produces: `cockpitProbeButton` in the QM toolbar; popover `HUDProbePopover`.

- [ ] **Step 1: Add the popover view** near the other HUD popovers:

```swift
/// Per-click provider chooser for the manual hard probe. Each item is
/// disabled while that provider is busy (coordinator OR model — an ordinary
/// refresh also makes the model reject) or its probe would be suppressed
/// (alarming auth); "Probe Both" is an atomic eligibility decision — disabled
/// unless BOTH are individually eligible, never silently probing just one.
private struct HUDProbePopover: View {
    let claudeEligible: Bool
    let codexEligible: Bool
    let claudeShown: Bool
    let codexShown: Bool
    let onProbe: (_ claude: Bool, _ codex: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if claudeShown {
                Button("Probe Claude") { onProbe(true, false); dismiss() }
                    .disabled(!claudeEligible)
            }
            if codexShown {
                Button("Probe Codex") { onProbe(false, true); dismiss() }
                    .disabled(!codexEligible)
            }
            if claudeShown && codexShown {
                Divider()
                Button("Probe Both") { onProbe(true, true); dismiss() }
                    .disabled(!(claudeEligible && codexEligible))
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Force-refresh usage via the provider CLI. May consume tokens.")
    }
}
```

- [ ] **Step 2: Add state + models to the toolbar's owning view** (`AgentCockpitHUDView` — the struct declaring `showRunwayPopover` etc. near line 760):

```swift
    @State private var showProbePopover = false
    @ObservedObject private var probeCoordinator = ProbeCoordinator.shared
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
    @EnvironmentObject private var claudeUsageModel: ClaudeUsageModel
```

(Skip any it already declares.) Use the view's **existing** enablement properties — `codexAgentEnabledForLimits`, `claudeAgentEnabledForLimits`, `codexUsageEnabledForLimits`, `claudeUsageEnabledForLimits` (~line 846); do not add duplicate `@AppStorage`s.

- [ ] **Step 3: Add the button + eligibility:**

```swift
    /// Manual hard-probe trigger (spec 2026-07-18). Eligibility mirrors the
    /// probe guards: provider enabled + usage tracking on + coordinator idle
    /// + model idle (isUpdating also covers ordinary refreshes, which make
    /// the model reject) + auth not alarming (suppressed would be a no-op).
    private var cockpitProbeButton: some View {
        Button {
            showProbePopover.toggle()
        } label: {
            Image(systemName: "bolt.badge.clock")
        }
        .buttonStyle(HUDIconButtonStyle(isOn: false, tint: nil))
        .help("Probe usage now via the provider CLI (may consume tokens).")
        .popover(isPresented: $showProbePopover, arrowEdge: .bottom) {
            HUDProbePopover(
                claudeEligible: claudeProbeEligible,
                codexEligible: codexProbeEligible,
                claudeShown: claudeAgentEnabledForLimits && claudeUsageEnabledForLimits,
                codexShown: codexAgentEnabledForLimits && codexUsageEnabledForLimits,
                onProbe: { claude, codex in
                    if claude && codex { ProbeCoordinator.shared.requestBoth() }
                    else if claude { ProbeCoordinator.shared.request(.claude) }
                    else if codex { ProbeCoordinator.shared.request(.codex) }
                }
            )
        }
    }

    private var claudeProbeEligible: Bool {
        claudeAgentEnabledForLimits && claudeUsageEnabledForLimits
            && !probeCoordinator.isBusy(.claude)
            && !claudeUsageModel.isUpdating
            && !(claudeUsageModel.authStatus?.state.isAlarming ?? false)
    }

    private var codexProbeEligible: Bool {
        codexAgentEnabledForLimits && codexUsageEnabledForLimits
            && !probeCoordinator.isBusy(.codex)
            && !codexUsageModel.isUpdating
            && !(codexUsageModel.authStatus?.state.isAlarming ?? false)
    }
```

- [ ] **Step 4: Place the button and protect the toolbar.** In `limitsToolbarCluster`, insert `cockpitProbeButton` after the `if showRunway { runwayGroup }` group:

```swift
            if showRunway {
                runwayGroup
            }
            cockpitProbeButton
```

In `isToolbarPopoverOpen` (~line 1203), add `|| showProbePopover` so the hover-revealed toolbar stays open while the probe popover is up.

- [ ] **Step 5: Build + run the full suite.** Expected: green. Visual placement QA is deferred to the owner's batched feature-complete QA.

### Task 5: In-row probe status rendering at all three sites

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` — all **three** provider-row render sites that switch on `entry.presentationState` (locate with `grep -n "switch entry.presentationState" AgentSessions/Views/AgentCockpitHUDView.swift` — expected ~lines 4692 rows panel, 4998 hover-expanded detail panel, 5724 collapsed bar content).

**Interfaces:**
- Consumes: `ProbeCoordinator.shared.displayState(for:now:)` and each site's clock value — **rows panel owns `clockNow`; the detail panel and bar content receive theirs as `now`** (see [AgentCockpitHUDView.swift:4959](AgentCockpitHUDView.swift) and ~5689).
- Produces: `HUDLimitsProbeCell`, helpers `isProbeVisible`/`isProbeFailed`.

- [ ] **Step 1: Add the cell + helpers** next to `HUDLimitsIdleCell`:

```swift
/// In-row probe feedback (spec 2026-07-18): swaps the provider's numbers for
/// explicit status text inside the same fixed-height row — the QM's height
/// never changes. "probing…" while running; "probe failed" until the
/// coordinator's deadline passes; success is simply the fresh numbers.
private struct HUDLimitsProbeCell: View {
    let source: UsageTrackingSource
    let failed: Bool
    var enlarged: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HUDLimitsProviderIcon(source: source)
            Text(failed ? "probe failed" : "probing…")
                .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .help(failed ? "The CLI probe did not return usage. Use the menu bar's Hard Refresh for diagnostics." : "Probing usage via the provider CLI…")
    }
}

private func isProbeVisible(_ s: ProbeCoordinator.ProbeRowState) -> Bool {
    if case .none = s { return false }
    return true
}

private func isProbeFailed(_ s: ProbeCoordinator.ProbeRowState) -> Bool {
    if case .failed = s { return true }
    return false
}
```

- [ ] **Step 2: Wire precedence at ALL THREE sites.** At each `switch entry.presentationState`, insert a probe case directly after `.needsAction` (precedence: `needsAction > probe > idle/reconnecting/live`). Per-site clock: rows panel uses `clockNow`; the detail panel and bar content use their `now` property:

```swift
            let probeState = probeCoordinator.displayState(for: entry.source, now: clockNow) // rows panel
            // let probeState = probeCoordinator.displayState(for: entry.source, now: now)  // detail panel + bar content
            switch entry.presentationState {
            case .needsAction(let auth):
                // (existing needsAction body unchanged)
            case _ where isProbeVisible(probeState):
                HUDLimitsProbeCell(source: entry.source,
                                   failed: isProbeFailed(probeState),
                                   enlarged: quotaMeterEnlarged)
            // (existing .idle / .reconnecting / .live cases unchanged)
```

Adapt each site's existing per-row chrome (padding, `chip:` choice, row-height frame; pass `enlarged: false` where the site has no `quotaMeterEnlarged`) so the probe cell sits exactly where that site's idle/retry cells sit. Each of the three owning views adds `@ObservedObject private var probeCoordinator = ProbeCoordinator.shared` and reads `probeCoordinator.displayState(...)` (never `ProbeCoordinator.shared...`) so SwiftUI tracks the published state. The 5 s clock tick bounds failure-expiry rendering at ~8–13 s — accepted; do not add a dedicated timer.

- [ ] **Step 3: Build + full suite.** Expected: green.

### Task 6: Route dropdown, Preferences, and strip through the coordinator; ladder copy; final verification

**Files:**
- Modify: `AgentSessions/MenuBar/StatusItemController.swift` (`refreshCodexHard` ~line 470, `refreshClaudeHard` ~line 480)
- Modify: `AgentSessions/Views/Preferences/PreferencesView+UsageProbes.swift` (Claude probe call ~line 21, Codex probe call ~line 157)
- Modify: `AgentSessions/CodexStatus/UsageStripView.swift` (double-click ~line 40)
- Modify: `AgentSessions/Shared/UsageAuthStatus.swift` (Claude `.idle` detail)
- Modify: `AgentSessionsTests/RunwayAuthDegradationTests.swift` (`testClaudeIdleDetailCarriesRecoveryLadder`)

**Interfaces:**
- Consumes: `ProbeCoordinator.shared.request(_:completion:)`, `ProbeReport`.
- Produces: final feature state — every probe surface goes through the one gate.

- [ ] **Step 1: Update the ladder test first** (RED). In `testClaudeIdleDetailCarriesRecoveryLadder`, replace the probe-rung assertions:

```swift
        XCTAssertTrue(s.detail.lowercased().contains("probe button"), "rung 3: QM toolbar probe button as last resort")
        XCTAssertTrue(s.detail.lowercased().contains("token"), "probe rung must carry its token-cost caveat")
```

Run just this test; expected FAIL (copy still says "double-click the meter").

- [ ] **Step 2: Update the copy** in `UsageAuthStatus.make`, `.idle`, Claude branch — replace the detail string with:

```swift
                    detail: "Usage paused — the saved CLI token lapsed. Run any claude command in Terminal to refresh it, or paste a claude.ai session cookie in Settings. Last resort: the probe button in the Quick Meter toolbar (may consume tokens).",
```

Run the test again; expected PASS.

- [ ] **Step 3: Menu-bar dropdown.** In `refreshClaudeHard`, replace the `guard !claudeStatus.isUpdating` preflight + direct call with a coordinator request (an `.alreadyRunning` rejection is the same silent no-op the old guard produced):

```swift
        ProbeCoordinator.shared.request(.claude) { report in
            guard case .claude(let diag) = report else { return }
            if !diag.success { self.presentFailureAlert(title: "Claude Probe Failed", diagnostics: diag) }
            else if diag.unavailableMessage != nil { self.presentFailureAlert(title: "Claude Probe Unavailable", diagnostics: diag) }
        }
```

Mirror in `refreshCodexHard`:

```swift
        ProbeCoordinator.shared.request(.codex) { report in
            guard case .codex(let diag) = report else { return }
            if !diag.success { self.presentFailureAlert(title: "Codex Probe Failed", diagnostics: diag) }
        }
```

Keep both methods' existing enabled-preference guards; delete only their `isUpdating` preflights and direct model calls.

- [ ] **Step 4: Preferences probes.** In `PreferencesView+UsageProbes.swift`, replace each direct `…hardProbeNowDiagnostics { diag in <present dialog> }` call, keeping the dialog body verbatim. The running-flag ordering must survive **synchronous** completions (guard short-circuits complete before `request` returns): set the flag BEFORE the call, clear it in the completion, and clear it again on rejection:

```swift
        isClaudeHardProbeRunning = true
        let accepted = ProbeCoordinator.shared.request(.claude) { report in
            isClaudeHardProbeRunning = false
            guard case .claude(let diag) = report else { return }
            // (existing dialog-presentation body unchanged, using `diag`)
        }
        if !accepted { isClaudeHardProbeRunning = false }
```

(and the `.codex` mirror at the Codex call site, with its flag name). Use each call site's actual local flag names.

- [ ] **Step 5: Main-window strip.** In `UsageStripView.swift`'s double-click handler, replace `CodexUsageModel.shared.hardProbeNow { _ in }` with `ProbeCoordinator.shared.request(.codex)`. Keep the existing enabled-preference guard; the `!codexStatus.isUpdating` preflight may stay (harmless) or go — the coordinator/entry point rejects overlaps either way.

- [ ] **Step 6: Full suite + fresh build.** Run the full suite (expected: all green), then build to default DerivedData and relaunch: `killall AgentSessions; open <default-DerivedData>/Build/Products/Debug/AgentSessions.app`.

- [ ] **Step 7: Present the owner QA checklist** (batched, per repo practice): toolbar button appears in QM chrome and its popover keeps the toolbar revealed; menu shows only enabled providers, disables busy/alarming ones, Probe Both disabled unless both eligible; probing… appears in-row in all three QM presentations (collapsed bar, hover-expanded panel, rows panel); failed probe shows "probe failed" ~8–13 s then reverts; closing/reopening QM mid-probe still shows probing…; menu-bar Hard Refresh still alerts on failure; Preferences probe dialogs unchanged incl. their "wait" state; strip double-click still probes Codex. Then list the uncommitted files for the owner's commit decision.
