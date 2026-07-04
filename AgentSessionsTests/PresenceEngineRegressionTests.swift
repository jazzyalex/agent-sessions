import XCTest
@testable import AgentSessions

/// Regression coverage for three confirmed defects introduced by the W6
/// PresenceEngine extraction (verified against v4.0):
///
///   - B1: a Preferences "Enable live session detection + Cockpit" toggle (and
///     registry-root override edit) must reach the engine. The engine side of
///     that is `updateEnvironment`'s enabled-transition start/stop + registry
///     root push; the facade side (a `FilteredDefaultsObserver` re-pushing the
///     environment) is wired in `CodexActiveSessionsModel`.
///   - B2: a launch with the feature disabled must never start polling
///     (`PresenceEnvironment.enabled` defaults `true`, so the real disabled
///     environment must be pushed before `start()`).
///   - B3: the foreground probe ramp must arm on the cockpit-window-visible
///     edge (v4.0 `setCockpitWindowVisible` armed
///     `!hadVisibleCockpitWindow && hasVisibleCockpitWindow && appIsActive`),
///     which the extraction dropped.
///
/// These exercise the engine directly through its `#if DEBUG` test hooks
/// (`debugApplyEnvironmentScheduling` / `debugStartPollingIfNeeded` /
/// `debugPollTaskIsRunning` / `debugIsForegroundProbeRampArmed`), which bypass
/// the `AppRuntime.isRunningTests` early-returns that keep the real poll
/// machinery quiet under XCTest. Shares the `FakeProbeRunner` fixture shape
/// with `PresenceEngineTests`.
@MainActor
final class PresenceEngineRegressionTests: XCTestCase {

    // MARK: - Fake ProbeRunner (mirrors PresenceEngineTests)

    actor FakeProbeRunner: ProbeRunner {
        struct Call: Sendable {
            let kind: PresenceEngine.ManagedProbeKind
            let executable: String
            let arguments: [String]
        }

        struct Responder: Sendable {
            let respond: @Sendable (String, [String]) -> Data?
        }

        private(set) var calls: [Call] = []
        private let responders: [Responder]

        init(responders: [Responder] = []) {
            self.responders = responders
        }

        func run(kind: PresenceEngine.ManagedProbeKind,
                 executable: URL,
                 arguments: [String],
                 timeout: TimeInterval) async -> Data? {
            calls.append(Call(kind: kind, executable: executable.lastPathComponent, arguments: arguments))
            for responder in responders {
                if let data = responder.respond(executable.lastPathComponent, arguments) {
                    return data
                }
            }
            return Data()
        }

        func cancel(kind: PresenceEngine.ManagedProbeKind) async {}
        func cancelAll() async {}
    }

    /// Returns a fixed lsof machine-format blob for the codex query so a single
    /// refresh cycle discovers exactly one codex presence via the process-probe
    /// path (fixture format copied from `PresenceEngineTests.makeCodexPresenceRunner`).
    private func makeCodexPresenceRunner(pid: Int = 4242, tty: String = "/dev/ttys044") -> FakeProbeRunner {
        let sessionLogPath = NSHomeDirectory() + "/.codex/sessions/2026/02/09/rollout-2026-02-09T12-34-56-00000000-0000-0000-0000-000000000000.jsonl"
        let lsofBlob = """
        p\(pid)
        fcwd
        tDIR
        n\(NSHomeDirectory())/Repository/Demo
        f0
        tCHR
        n\(tty)
        f26w
        tREG
        n\(sessionLogPath)
        """
        let responder = FakeProbeRunner.Responder { executable, arguments in
            guard executable == "lsof" else { return nil }
            guard arguments.contains("codex") else { return Data() }
            return lsofBlob.data(using: .utf8)
        }
        return FakeProbeRunner(responders: [responder])
    }

    // MARK: - B1: enabled-toggle reaches the engine

    /// Turning the feature OFF must stop the poll loop AND clear presence rows
    /// (v4.0 `stopPolling(clear: true)`), driven when the pushed environment
    /// flips `enabled` true -> false.
    func testEnabledToggleOff_stopsPollingAndClearsPresences() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)

        var enabledEnv = PresenceEnvironment()
        enabledEnv.enabled = true
        await engine.debugSetEnvironment(enabledEnv)
        var iterator = engine.stream.makeAsyncIterator()
        let populated = await engine.debugRefreshOnce()
        XCTAssertEqual(populated.presences.count, 1)
        let joinEmission = await iterator.next()
        XCTAssertEqual(joinEmission?.snapshot.presences.count, 1, "drain the priming join emission first")

        await engine.debugStartPollingIfNeeded()
        let runningBefore = await engine.debugPollTaskIsRunning()
        XCTAssertTrue(runningBefore, "poll loop should be live while enabled")

        var disabledEnv = enabledEnv
        disabledEnv.enabled = false
        await engine.debugApplyEnvironmentScheduling(previous: enabledEnv, next: disabledEnv)

        let runningAfter = await engine.debugPollTaskIsRunning()
        XCTAssertFalse(runningAfter, "toggling the feature off must stop the poll loop")

        let clearedEmission = await iterator.next()
        XCTAssertTrue(clearedEmission?.isMembershipChange == true)
        XCTAssertTrue(clearedEmission?.snapshot.presences.isEmpty == true,
                      "toggle-off must clear presence rows (v4.0 stopPolling(clear: true))")
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.presences.isEmpty)
    }

    /// Turning the feature back ON must let polling restart. While disabled,
    /// `startPollingIfNeeded`'s `environment.enabled` gate must refuse to start
    /// a poll loop; once the environment flips back to enabled, the same gate
    /// must allow it. (`debugStartPollingIfNeeded` mirrors the real
    /// `startPollingIfNeeded` gate — the production scheduling path calls it,
    /// but that call is quiet under XCTest, so the gate itself is what's pinned.)
    func testEnabledToggleOn_restartsPolling() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)

        var disabledEnv = PresenceEnvironment()
        disabledEnv.enabled = false
        await engine.debugSetEnvironment(disabledEnv)
        await engine.debugStartPollingIfNeeded()
        let runningWhileDisabled = await engine.debugPollTaskIsRunning()
        XCTAssertFalse(runningWhileDisabled, "startPollingIfNeeded must refuse to start while disabled")

        var enabledEnv = disabledEnv
        enabledEnv.enabled = true
        await engine.debugSetEnvironment(enabledEnv)
        await engine.debugStartPollingIfNeeded()

        let runningAfterEnable = await engine.debugPollTaskIsRunning()
        XCTAssertTrue(runningAfterEnable, "re-enabling the feature must let the poll loop start")
    }

    /// Editing the registry-root override must push a fresh environment and the
    /// following refresh must still run against it (v4.0 refreshed on the key's
    /// didSet).
    func testRegistryRootOverrideChange_refreshStillRuns() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)

        var env = PresenceEnvironment()
        env.registryRootOverride = ""
        await engine.debugSetEnvironment(env)

        var changed = env
        changed.registryRootOverride = "/tmp/some/registry/override"
        await engine.debugApplyEnvironmentScheduling(previous: env, next: changed)

        let snapshot = await engine.debugRefreshOnce()
        XCTAssertEqual(snapshot.presences.count, 1,
                       "refresh after a registry-root change must still run and discover presences")
    }

    // MARK: - B2: launch with feature disabled never polls

    func testLaunchWithEnabledFalse_neverStartsPolling() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)

        var disabledEnv = PresenceEnvironment()
        disabledEnv.enabled = false
        await engine.debugSetEnvironment(disabledEnv)

        await engine.debugStartPollingIfNeeded()
        let running = await engine.debugPollTaskIsRunning()
        XCTAssertFalse(running, "startPollingIfNeeded must respect environment.enabled == false")

        _ = await engine.debugRefreshOnce()
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty, "a disabled engine must issue no discovery probes")
    }

    // MARK: - B3: foreground probe ramp arming parity

    /// Cockpit window hidden -> visible while active + a consumer visible must
    /// arm the ramp (v4.0 `setCockpitWindowVisible` edge, dropped by extraction).
    func testRamp_armsOnCockpitWindowBecomingVisibleWhileActive() async {
        let engine = PresenceEngine()

        var previous = PresenceEnvironment()
        previous.appIsActive = true
        previous.hasVisibleCockpitConsumer = true
        previous.hasVisibleConsumer = true
        previous.hasVisibleCockpitWindow = false
        await engine.debugSetEnvironment(previous)
        let armedBefore = await engine.debugIsForegroundProbeRampArmed()
        XCTAssertFalse(armedBefore, "precondition: ramp starts un-armed")

        var next = previous
        next.hasVisibleCockpitWindow = true
        await engine.debugApplyEnvironmentScheduling(previous: previous, next: next)

        let armedAfter = await engine.debugIsForegroundProbeRampArmed()
        XCTAssertTrue(armedAfter,
                      "cockpit window becoming visible while active must arm the foreground probe ramp (v4.0 parity)")
    }

    /// The same transition while INACTIVE must NOT arm (v4.0 gated on appIsActive).
    func testRamp_doesNotArmOnCockpitWindowVisibleWhileInactive() async {
        let engine = PresenceEngine()

        var previous = PresenceEnvironment()
        previous.appIsActive = false
        previous.hasVisibleCockpitConsumer = true
        previous.hasVisibleConsumer = true
        previous.hasVisibleCockpitWindow = false
        await engine.debugSetEnvironment(previous)

        var next = previous
        next.hasVisibleCockpitWindow = true
        await engine.debugApplyEnvironmentScheduling(previous: previous, next: next)

        let armed = await engine.debugIsForegroundProbeRampArmed()
        XCTAssertFalse(armed,
                       "an inactive app must not arm the ramp on a cockpit-window-visible transition")
    }
}
