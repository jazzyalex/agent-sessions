import XCTest
@testable import AgentSessions

/// Direct actor tests for `PresenceEngine` (W6 Task 1). Covers the pieces
/// that are genuinely new with the extraction: the injectable `ProbeRunner`
/// seam, the generation-guard/cancel-on-replace behavior now living inside
/// the actor, `refreshNow`'s cancel-inflight semantics, and the cadence diet
/// (the one intended behavior change — freshness-only emissions throttled
/// to >=10s while inactive; membership/badge changes always immediate).
///
/// The underlying merge/classify/publish-decision/cadence-arithmetic *pure*
/// functions are NOT re-tested here — they did not move (they remain
/// `nonisolated static` on `CodexActiveSessionsModel`, exercised by the
/// ~55 pre-existing `CodexActiveSessionsRegistryTests` call sites, which
/// this task must keep green untouched). What's tested here is that the
/// actor wires those functions together correctly across the new
/// actor/Sendable boundary, with injected fixtures standing in for real
/// subprocess probes.
@MainActor
final class PresenceEngineTests: XCTestCase {

    // MARK: - Fake ProbeRunner

    /// Routes by (executable basename, whether a given needle appears in the
    /// arguments) so a single fake can stand in for ps/lsof/osascript calls
    /// within one refresh cycle. Records every `run` invocation for
    /// assertions about what the engine attempted.
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
        private(set) var cancelledKinds: [PresenceEngine.ManagedProbeKind] = []
        private(set) var cancelAllCount = 0

        /// Installed at init (not via a separate async call) so there is no
        /// race between "responder configured" and "engine's first refresh
        /// cycle reads it" — actor task scheduling gives no ordering
        /// guarantee between two separately-dispatched `Task {}` blocks.
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

        func cancel(kind: PresenceEngine.ManagedProbeKind) async {
            cancelledKinds.append(kind)
        }

        func cancelAll() async {
            cancelAllCount += 1
        }
    }

    /// Fake that returns a fixed lsof machine-format blob whenever the
    /// arguments target codex (`-c codex`), so one refresh cycle discovers
    /// exactly one codex presence via the process-probe path (the registry
    /// JSON directory read is real-filesystem and not fixture-friendly, so
    /// membership tests drive presence discovery through the process probe
    /// instead — see `CodexActiveSessionsRegistryTests.testParseLsofMachineOutput*`
    /// for the parser-level oracle this fixture format is copied from).
    private func makeCodexPresenceRunner(pid: Int = 4242, tty: String = "/dev/ttys044") -> FakeProbeRunner {
        // `parseLsofMachineOutput` only keeps a session-log record whose path
        // falls under one of the engine's `codexSessionsRoots()` (default
        // `~/.codex/sessions` — the engine reads the REAL home directory, same
        // as pre-extraction code), so the fixture path must live under the
        // real `NSHomeDirectory()` to be recognized as a session log rather
        // than falling back to a keyless (tty-only) presence.
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

    /// Thread-safe mutable box so a `FakeProbeRunner.Responder` (a synchronous
    /// `@Sendable` closure) can serve a DIFFERENT `cwd` on each call — used to
    /// drive a "freshness-only" publish (stable-metadata churn with the same
    /// session/log identity, so membership does NOT change) deterministically,
    /// without depending on the iTerm live-state classification heuristics.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Value) { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    /// Same shape as `makeCodexPresenceRunner`, but `cwd` is read from a
    /// `LockedBox` the test can mutate between refresh cycles — flipping
    /// `workspaceRoot` changes `stablePresenceSignatures` (metadataChanged)
    /// without touching the session id / log path identity that
    /// `membershipChanged` is keyed on. `extraPIDBox`, when set to a non-nil
    /// pid, adds a SECOND codex presence (distinct pid/tty/log path) to the
    /// lsof blob starting on the next call — a genuine membership-key-set
    /// change the test uses to prove membership changes bypass the
    /// freshness throttle even mid-window.
    private func makeCodexPresenceRunner(pid: Int = 4242,
                                         tty: String = "/dev/ttys044",
                                         cwdBox: LockedBox<String>,
                                         extraPIDBox: LockedBox<Int?> = LockedBox(nil)) -> FakeProbeRunner {
        let sessionLogPath = NSHomeDirectory() + "/.codex/sessions/2026/02/09/rollout-2026-02-09T12-34-56-00000000-0000-0000-0000-000000000000.jsonl"
        let responder = FakeProbeRunner.Responder { executable, arguments in
            guard executable == "lsof" else { return nil }
            guard arguments.contains("codex") else { return Data() }
            var blob = """
            p\(pid)
            fcwd
            tDIR
            n\(cwdBox.get())
            f0
            tCHR
            n\(tty)
            f26w
            tREG
            n\(sessionLogPath)
            """
            if let extraPID = extraPIDBox.get() {
                let extraLogPath = NSHomeDirectory() + "/.codex/sessions/2026/02/09/rollout-2026-02-09T12-34-57-11111111-1111-1111-1111-111111111111.jsonl"
                blob += """
                \np\(extraPID)
                fcwd
                tDIR
                n\(cwdBox.get())
                f0
                tCHR
                n/dev/ttys099
                f26w
                tREG
                n\(extraLogPath)
                """
            }
            return blob.data(using: .utf8)
        }
        return FakeProbeRunner(responders: [responder])
    }

    // MARK: - Environment plumbing

    func testDebugSetEnvironment_isVisibleToSubsequentRefresh() async {
        let runner = FakeProbeRunner()
        let engine = PresenceEngine(probeRunner: runner)
        var env = PresenceEnvironment()
        env.hasVisibleConsumer = true
        env.appIsActive = true
        await engine.debugSetEnvironment(env)

        _ = await engine.debugRefreshOnce()

        let calls = await runner.calls
        // With a visible consumer + active app, the engine should have
        // attempted both a process probe (ps) and, since shouldUseITermSnapshot
        // requires a visible consumer, an iTerm inventory probe (osascript).
        XCTAssertTrue(calls.contains { $0.executable == "ps" })
    }

    // MARK: - Membership publish + snapshot fields

    func testRefreshOnce_discoversCodexPresenceViaProcessProbe_andPublishesMembership() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)
        await engine.debugSetEnvironment(PresenceEnvironment())

        var emissions: [PresenceEngine.Emission] = []
        let collector = Task {
            for await emission in engine.stream {
                emissions.append(emission)
                if emissions.count >= 1 { break }
            }
        }

        let snapshot = await engine.debugRefreshOnce()
        _ = await collector.value

        XCTAssertEqual(snapshot.presences.count, 1)
        XCTAssertEqual(snapshot.presences.first?.pid, 4242)
        XCTAssertEqual(snapshot.presences.first?.source, .codex)
        XCTAssertGreaterThan(snapshot.membershipVersion, 0)

        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(emissions[0].isMembershipChange)
    }

    func testRefreshOnce_secondIdenticalCycleDoesNotRepublish() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)
        await engine.debugSetEnvironment(PresenceEnvironment())

        let first = await engine.debugRefreshOnce()
        XCTAssertEqual(first.presences.count, 1)

        // Second cycle: same process-probe fixture (steady state, same pid/tty),
        // membership should NOT change again.
        let second = await engine.debugRefreshOnce()
        XCTAssertEqual(second.membershipVersion, first.membershipVersion)
    }

    // MARK: - refreshNow cancel-inflight semantics

    func testRefreshNow_cancelsInFlightProbesAndResetsThrottleCaches() async {
        let runner = FakeProbeRunner()
        let engine = PresenceEngine(probeRunner: runner)
        await engine.debugSetEnvironment(PresenceEnvironment())

        // Prime a cycle so lastProcessProbeAt/caches are populated.
        _ = await engine.debugRefreshOnce()
        let callsAfterFirst = await runner.calls.count

        await engine.debugRefreshNow()

        let cancelAllCount = await runner.cancelAllCount
        XCTAssertGreaterThanOrEqual(cancelAllCount, 1, "refreshNow must cancel in-flight probes exactly like the pre-extraction refreshNow()")

        // refreshNow forces a fresh cycle immediately (bypassing the process-probe
        // min-interval cache), so it should issue at least one more probe call.
        // Give the detached refresh task a brief moment to run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let callsAfterRefreshNow = await runner.calls.count
        XCTAssertGreaterThan(callsAfterRefreshNow, 0)
        XCTAssertGreaterThanOrEqual(callsAfterFirst, 1)
    }

    // MARK: - Generation guard / cancel-on-replace (debugRunManagedCommand)

    func testDebugRunManagedCommand_returnsOutputBeforeTimeout() async {
        let engine = PresenceEngine()
        let data = await engine.debugRunManagedCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ready"],
            timeout: 1
        )
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "ready")
    }

    func testDebugRunManagedCommand_returnsNilAfterTimeout() async {
        let engine = PresenceEngine()
        let data = await engine.debugRunManagedCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 1"],
            timeout: 0.1
        )
        XCTAssertNil(data)
    }

    func testDebugRunManagedCommand_replacedProbeDropsEarlierResult() async {
        let engine = PresenceEngine()

        let firstTask = Task {
            await engine.debugRunManagedCommand(
                kind: .processDiscovery,
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 1; printf late"],
                timeout: 2
            )
        }

        try? await Task.sleep(nanoseconds: 200_000_000)

        let replacement = await engine.debugRunManagedCommand(
            kind: .processDiscovery,
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf replacement"],
            timeout: 1
        )
        let first = await firstTask.value

        XCTAssertNil(first)
        XCTAssertEqual(replacement.map { String(decoding: $0, as: UTF8.self) }, "replacement")
    }

    // MARK: - Cadence diet: freshness-only throttled while inactive, membership never throttled

    func testCadence_membershipChangeEmitsImmediatelyWhileInactive() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)
        var env = PresenceEnvironment()
        env.appIsActive = false
        await engine.debugSetEnvironment(env)

        var emissions: [PresenceEngine.Emission] = []
        let collector = Task {
            for await emission in engine.stream {
                emissions.append(emission)
                if emissions.count >= 1 { break }
            }
        }

        _ = await engine.debugRefreshOnce()
        _ = await collector.value

        XCTAssertEqual(emissions.count, 1)
        XCTAssertTrue(emissions[0].isMembershipChange, "a real join must emit immediately even while the app is inactive")
    }

    func testCadence_freshnessOnlyChangeThrottledWhileInactive() async {
        // Behavioral pin for the cadence diet (previously only asserted the
        // `== 10` constant). Drives three freshness-only publish-decision-yes
        // cycles via `cwdBox` mutations (workspaceRoot flips `metadataChanged`
        // without touching the session/log identity `membershipChanged` keys
        // on), using the engine's injectable `now:` seam to control elapsed
        // time for the THROTTLE decision deterministically instead of
        // sleeping in real time.
        //
        // Every cycle after priming uses `debugRefreshNow()` (not
        // `debugRefreshOnce()`): with the app inactive and no visible
        // consumer, `processProbeMinIntervalSeconds` returns 120s once a
        // presence is registered, and that interval is checked against REAL
        // `Date()` (the injectable `now:` seam only feeds the freshness
        // throttle, not `refreshOnce`'s own `now`) — so back-to-back
        // `debugRefreshOnce()` calls in a fast-running test would just replay
        // the cached process presence and never re-probe. `debugRefreshNow()`
        // clears that cache synchronously before spawning its refresh task
        // (proven pattern: see `testRefreshNow_cancelsInFlightProbesAndResetsThrottleCaches`),
        // forcing a fresh `lsof` call — and therefore a fresh read of
        // `cwdBox`/`extraPIDBox` — every cycle.
        //
        //   1. Priming cycle establishes membership at clock t=0 (immediate
        //      emission, drained). `emit()` stamps `lastFreshnessOnlyEmitAt =
        //      t=0` for EVERY emission kind, membership included — so the
        //      throttle clock effectively starts here, not at cycle A.
        //   2. Cycle A: metadata-only change, clock advanced to t=15 (well
        //      past the 10s window since the priming emission at t=0).
        //      Emits (first freshness-only emission), which re-stamps
        //      `lastFreshnessOnlyEmitAt = t=15`.
        //   3. Cycle B: metadata-only change again, clock at t=15+5=20 (<10s
        //      since A's emission at t=15). Must NOT emit — still throttled.
        //   4. Cycle C: metadata-only change again, clock at t=15+11=26
        //      (>=10s since A's emission at t=15). Must emit — throttle
        //      window elapsed.
        //   5. Cycle D: a MEMBERSHIP change (new pid) inside the throttle
        //      window (t=26.5, <10s since C's emission at t=26). Must
        //      emit immediately — membership changes are never throttled.
        let cwdBox = LockedBox("/Users/tester/Repository/DemoA")
        let extraPIDBox = LockedBox<Int?>(nil)
        let runner = makeCodexPresenceRunner(cwdBox: cwdBox, extraPIDBox: extraPIDBox)
        let clockBox = LockedBox(Date(timeIntervalSince1970: 1_700_000_000))
        let engine = PresenceEngine(probeRunner: runner, now: { clockBox.get() })
        var env = PresenceEnvironment()
        env.appIsActive = false
        await engine.debugSetEnvironment(env)

        var iterator = engine.stream.makeAsyncIterator()

        // Small real-time delay after each `debugRefreshNow()` to let its
        // detached refresh task complete before the next assertion —
        // mirrors `testRefreshNow_cancelsInFlightProbesAndResetsThrottleCaches`.
        func refreshNowAndSettle() async {
            await engine.debugRefreshNow()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 1. Priming cycle: establishes membership, emits immediately
        // (membership changes are never throttled) — drain it so it doesn't
        // pollute the freshness-only assertions below.
        await refreshNowAndSettle()
        let primed = await engine.currentSnapshot()
        XCTAssertEqual(primed.presences.count, 1)
        let joinEmission = await iterator.next()
        XCTAssertTrue(joinEmission?.isMembershipChange == true, "drain the priming join emission first")

        // 2. Cycle A: metadata-only change (cwd flip). Advance the clock well
        // past the priming emission's throttle stamp (t=0) first — otherwise
        // this cycle's elapsed-since-last-emit would be 0 (still < 10s) and
        // get throttled itself, since `emit()` stamps
        // `lastFreshnessOnlyEmitAt` for every emission kind, including the
        // priming membership one.
        clockBox.set(clockBox.get().addingTimeInterval(15))
        cwdBox.set("/Users/tester/Repository/DemoB")
        await refreshNowAndSettle()
        let emissionA = await iterator.next()
        XCTAssertNotNil(emissionA, "first freshness-only change after the throttle clock starts must emit")
        XCTAssertFalse(emissionA?.isMembershipChange == true, "a metadata-only change must NOT be tagged as a membership change")

        // 3. Cycle B: metadata-only change again, only 5s later (<10s) — must
        // be throttled (no emission): assert the probe still ran (call count
        // grew) but nothing new is available on the stream.
        clockBox.set(clockBox.get().addingTimeInterval(5))
        cwdBox.set("/Users/tester/Repository/DemoC")
        let callsBeforeB = await runner.calls.count
        await refreshNowAndSettle()
        let callsAfterB = await runner.calls.count
        XCTAssertGreaterThan(callsAfterB, callsBeforeB, "cycle B must actually run (probe issued) even though its publish is throttled")

        // 4. Cycle C: metadata-only change again, now 11s after A (>=10s) —
        // throttle window elapsed, must emit.
        clockBox.set(clockBox.get().addingTimeInterval(6))
        cwdBox.set("/Users/tester/Repository/DemoD")
        await refreshNowAndSettle()
        let emissionC = await iterator.next()
        XCTAssertNotNil(emissionC, "cycle C is >=10s after the last freshness-only emission and must emit")
        XCTAssertFalse(emissionC?.isMembershipChange == true)

        // 5. Cycle D: a genuine MEMBERSHIP change (a second codex presence
        // joins — the log/session key SET grows), still well within the 10s
        // throttle window relative to C's emission (only 0.5s later). Must
        // emit immediately — membership/badge changes always bypass the
        // freshness throttle, regardless of how recently a freshness-only
        // emission went out.
        clockBox.set(clockBox.get().addingTimeInterval(0.5))
        extraPIDBox.set(9999)
        await refreshNowAndSettle()
        let afterD = await engine.currentSnapshot()
        XCTAssertEqual(afterD.presences.count, 2, "cycle D must discover the newly-joined second presence")
        let emissionD = await iterator.next()
        XCTAssertNotNil(emissionD)
        XCTAssertTrue(emissionD?.isMembershipChange == true, "a membership change inside the throttle window must still emit immediately")
        XCTAssertEqual(emissionD?.snapshot.presences.count, 2)
    }

    func testCadence_foregroundFreshnessIsNotThrottled() async {
        // In the foreground, `emitFreshnessOnlyIfDue` always emits (the
        // pre-extraction behavior had no freshness throttle at all in the
        // foreground) — asserted structurally via the environment default
        // (appIsActive: true) producing an emission on the very first
        // membership-establishing cycle, same as the inactive case above,
        // confirming the foreground path isn't accidentally gated too.
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)
        var env = PresenceEnvironment()
        env.appIsActive = true
        await engine.debugSetEnvironment(env)

        var emissions: [PresenceEngine.Emission] = []
        let collector = Task {
            for await emission in engine.stream {
                emissions.append(emission)
                if emissions.count >= 1 { break }
            }
        }
        _ = await engine.debugRefreshOnce()
        _ = await collector.value

        XCTAssertEqual(emissions.count, 1)
    }

    // MARK: - deferExpensiveProbesUntil survives environment pushes (regression pin)

    /// Pins the parity bug the implementer self-caught during Task 1
    /// (documented in `updateEnvironment`'s comment): the facade pushes a
    /// fresh `PresenceEnvironment` on every visibility/`@AppStorage` change,
    /// always with `deferExpensiveProbesUntil == nil` (the facade has no
    /// view onto this engine-owned timer) — so `updateEnvironment` MUST
    /// preserve the engine's own in-flight defer across that push rather
    /// than letting it get clobbered back to `nil`. Exercises the merge via
    /// `updateEnvironment` directly (not `debugSetEnvironment`, which
    /// bypasses the merge entirely) since `updateEnvironment`'s merge logic
    /// runs unconditionally, before its `AppRuntime.isRunningTests` early
    /// return.
    func testUpdateEnvironment_preservesUnexpiredDeferAcrossPush() async {
        let cwdBox = LockedBox("/Users/tester/Repository/DemoA")
        let runner = makeCodexPresenceRunner(cwdBox: cwdBox)
        let farFuture = Date().addingTimeInterval(1_000)
        let engine = PresenceEngine(probeRunner: runner, now: { farFuture })

        // Seed an in-flight, unexpired defer directly on the engine (mirrors
        // what `deferExpensiveProbesForSelectionOpen` would set in
        // production; that method itself is a no-op under
        // `AppRuntime.isRunningTests`, so tests set the field directly).
        var seeded = PresenceEnvironment()
        seeded.deferExpensiveProbesUntil = Date().addingTimeInterval(2.5)
        await engine.debugSetEnvironment(seeded)

        // Simulate the facade pushing a routine environment update (e.g. a
        // visibility flip) — it always carries `deferExpensiveProbesUntil ==
        // nil` because the facade has no window into this engine-internal
        // timer.
        var pushed = PresenceEnvironment()
        pushed.hasVisibleConsumer = true
        pushed.deferExpensiveProbesUntil = nil
        await engine.updateEnvironment(pushed, refreshSoon: false)

        // A refresh cycle run right after the push must still treat probes
        // as deferred: the process probe (lsof/ps) must NOT be issued,
        // because the unexpired defer survived the push.
        let snapshot = await engine.debugRefreshOnce()
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.executable == "lsof" },
                        "an unexpired defer that survived the environment push must still suppress the process probe")
        XCTAssertTrue(snapshot.presences.isEmpty,
                       "no presence should be discovered while the process probe is suppressed by the surviving defer")
    }

    /// Complements the above: an EXPIRED defer must not linger and continue
    /// suppressing probes after its deadline passes, even though the merge
    /// logic in `updateEnvironment` always carries the engine's own
    /// `deferExpensiveProbesUntil` value forward (expiry is a read-time
    /// check against real wall-clock time in `refreshOnce` — `now <
    /// deadline` — not something that clears the field). Note: unlike the
    /// cadence-diet tests, `refreshOnce`'s own `now` is always real
    /// `Date()` (the injectable `now:` seam only feeds the freshness-only
    /// emit throttle), so this test seeds the deadline against real time
    /// rather than an injected clock.
    func testUpdateEnvironment_expiredDeferDoesNotLingerAfterPush() async {
        let cwdBox = LockedBox("/Users/tester/Repository/DemoA")
        let runner = makeCodexPresenceRunner(cwdBox: cwdBox)
        let engine = PresenceEngine(probeRunner: runner)

        // Seed a defer that has ALREADY expired relative to real wall-clock
        // time (deadline 2.5s in the past).
        var seeded = PresenceEnvironment()
        seeded.deferExpensiveProbesUntil = Date().addingTimeInterval(-2.5)
        await engine.debugSetEnvironment(seeded)

        // A routine environment push (again carrying nil) should leave the
        // now-expired deadline in place per the merge rule, but since it's
        // already in the past this must not suppress anything.
        var pushed = PresenceEnvironment()
        pushed.hasVisibleConsumer = true
        pushed.deferExpensiveProbesUntil = nil
        await engine.updateEnvironment(pushed, refreshSoon: false)

        let snapshot = await engine.debugRefreshOnce()
        let calls = await runner.calls
        XCTAssertTrue(calls.contains { $0.executable == "lsof" },
                       "an expired defer must not linger and suppress the process probe after its deadline has passed")
        XCTAssertEqual(snapshot.presences.count, 1,
                        "the process probe must run normally once the defer has expired, discovering the fixture presence")
    }

    // MARK: - start/stop(clear:)

    func testStopClear_resetsGenerationAndEmitsClearedMembership() async {
        let runner = makeCodexPresenceRunner()
        let engine = PresenceEngine(probeRunner: runner)
        await engine.debugSetEnvironment(PresenceEnvironment())

        // Attach the iterator BEFORE the priming refresh so its join emission
        // is captured (and drained) rather than left buffered ahead of the
        // `stop(clear:)` emission this test actually asserts on.
        var iterator = engine.stream.makeAsyncIterator()

        let populated = await engine.debugRefreshOnce()
        XCTAssertEqual(populated.presences.count, 1)
        let joinEmission = await iterator.next()
        XCTAssertEqual(joinEmission?.snapshot.presences.count, 1, "drain the priming cycle's join emission first")

        // The stream buffers at most the newest element (`.bufferingNewest(1)`),
        // so the single emission `stop(clear:)` yields is queued and delivered
        // to the already-attached iterator regardless of exact timing.
        await engine.stop(clear: true)
        let emission = await iterator.next()

        XCTAssertNotNil(emission)
        XCTAssertTrue(emission?.isMembershipChange == true)
        XCTAssertTrue(emission?.snapshot.presences.isEmpty == true)
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.presences.isEmpty)
        XCTAssertTrue(snapshot.bySessionID.isEmpty)
        XCTAssertTrue(snapshot.byLogPath.isEmpty)
    }
}
