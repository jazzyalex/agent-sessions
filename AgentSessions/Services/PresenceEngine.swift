import Foundation

/// Sendable environment pushed into the engine by the `@MainActor` facade.
/// Mirrors the inputs `refreshOnce`/`pollIntervalSeconds` read from
/// `CodexActiveSessionsModel` instance state (visibility sets collapsed to a
/// bool, `@AppStorage`-backed fields, and the app-active flag). The engine has
/// no other window into main-actor state — everything it needs crosses here.
struct PresenceEnvironment: Sendable, Equatable {
    var enabled: Bool = true
    var registryRootOverride: String = ""
    var hudOpen: Bool = false
    var hudPinned: Bool = false
    var appIsActive: Bool = true
    var hasVisibleConsumer: Bool = false
    var hasVisibleCockpitConsumer: Bool = false
    var hasVisibleCockpitWindow: Bool = false
    var lastCockpitVisibleAt: Date? = nil
    var deferExpensiveProbesUntil: Date? = nil

    var isCockpitVisible: Bool { hasVisibleCockpitWindow && hudOpen }
    var isPinnedCockpitVisible: Bool { hasVisibleCockpitConsumer && hudOpen && hudPinned }
}

/// Injectable seam over `Process`-based probe execution so engine tests can
/// supply canned output instead of forking real subprocesses. The default
/// implementation is the real fork/exec path (ported byte-for-byte from
/// `CodexActiveSessionsModel.runManagedCommand`).
protocol ProbeRunner: Sendable {
    /// Run `executable` with `arguments`, returning captured stdout or `nil`
    /// on failure/timeout/cancellation. `kind` is used only for the in-flight
    /// bookkeeping key (one in-flight command per kind, matching today's
    /// cancel-on-replace behavior).
    func run(kind: PresenceEngine.ManagedProbeKind,
             executable: URL,
             arguments: [String],
             timeout: TimeInterval) async -> Data?

    /// Cancel any in-flight command of this kind (best-effort SIGTERM then SIGKILL).
    func cancel(kind: PresenceEngine.ManagedProbeKind, reason: String) async

    /// Cancel every in-flight command, regardless of kind.
    func cancelAll(reason: String) async
}

/// Off-main-actor presence engine. Owns the poll loop, interval policy,
/// registry reads, probe launches (process fork/exec), merge/dedup,
/// classification (including the osascript batch probe), the publish
/// decision (signature diff + suppression heuristics + version bumps), and
/// the Cockpit-gated SQLite subagent-badge read.
///
/// All *pure* computation (merge, classify, signature diffing, cadence
/// arithmetic, parsers) is intentionally left in place as `nonisolated
/// static` members on `CodexActiveSessionsModel` — those are covered by
/// ~55 existing `CodexActiveSessionsRegistryTests` call sites by exact
/// qualified name and MUST NOT move. `nonisolated static` members are
/// callable from any isolation domain, so the engine calls them directly
/// with zero duplication. What moves here is the *stateful orchestration*:
/// the mutable caches, generation counters, in-flight probe bookkeeping,
/// and the poll loop that used to live as main-actor instance state.
actor PresenceEngine {
    enum ManagedProbeKind: String, Hashable, Sendable {
        case processDiscovery
        case iTermInventory
        case iTermBatchProbe
    }

    // MARK: - Public stream

    /// One element per publish-decision-yes, exactly matching the pre-extraction
    /// conditions (`refreshPublish`'s membership/metadata/live-state change
    /// check, minus whatever the cadence diet additionally throttles).
    struct Emission: Sendable {
        let snapshot: PresenceSnapshot
        let isMembershipChange: Bool
    }

    private var continuation: AsyncStream<Emission>.Continuation?
    nonisolated let stream: AsyncStream<Emission>

    // MARK: - Injected dependencies

    private let probeRunner: ProbeRunner

    /// Wall-clock seam used ONLY by the cadence-diet throttle
    /// (`emitFreshnessOnlyIfDue`/`emit`). Everything else in the engine
    /// (`refreshOnce`'s `now`, `deferExpensiveProbesForSelectionOpen`) still
    /// calls `Date()` directly — this narrow seam exists solely so
    /// `PresenceEngineTests` can drive the throttle deterministically without
    /// sleeping in real time. Defaults to the real clock in production.
    private let now: () -> Date

    // MARK: - Environment (pushed in from the facade)

    private var environment = PresenceEnvironment()

    // MARK: - Cadence diet (new behavior — the only intended behavior change)

    /// Freshness-only (non-membership) emissions are throttled to this minimum
    /// spacing while the app is inactive. Membership/badge changes always emit
    /// immediately regardless of this gate.
    static let inactiveFreshnessMinInterval: TimeInterval = 10
    private var lastFreshnessOnlyEmitAt: Date? = nil

    // MARK: - Poll loop

    private var pollTask: Task<Void, Never>? = nil
    private var refreshTask: Task<Void, Never>? = nil
    private var refreshInFlight: Bool = false
    private var refreshQueued: Bool = false

    // MARK: - Generation bookkeeping (ported from CodexActiveSessionsModel)

    private var refreshGeneration: UInt64 = 0
    private var activeRefreshGeneration: UInt64 = 0

    // MARK: - Latest published snapshot (used for signature diffing + lookups)

    private var latestSnapshot: PresenceSnapshot = .empty
    private var lastPublishedPresenceSignatures: [String: String] = [:]
    private var lastPublishedRuntimeSubagentCountsByPresenceKey: [String: Int] = [:]

    // MARK: - Per-cycle caches (ported 1:1 from CodexActiveSessionsModel private state)

    private var cachedProcessPresences: [CodexActivePresence] = []
    private var cachedITermPresences: [CodexActivePresence] = []
    private var cachedITermTabTitleByTTY: [String: String] = [:]
    private var cachedITermTabTitleBySessionGuid: [String: String] = [:]
    private var lastProcessProbeAt: Date? = nil
    private var lastITermProbeAt: Date? = nil
    private var resumeProbeBudgetIndex: Int? = nil
    private var itermProbeRoundRobinCursor: Int = 0
    private var forceFullProbeNextRefresh: Bool = false
    private var consecutiveStableCycles: Int = 0
    private var consecutiveEmptySuppressedCycles: Int = 0

    // MARK: - Debug metrics (parity with CodexActiveSessionsModel's #if DEBUG DebugMetrics)

#if DEBUG
    struct DebugPerformanceSnapshot: Sendable {
        let refreshGeneration: UInt64
        let staleRefreshResultsDropped: UInt64
    }
    private var staleRefreshResultsDropped: UInt64 = 0
#endif

    init(probeRunner: ProbeRunner = RealProbeRunner(), now: @escaping () -> Date = Date.init) {
        self.probeRunner = probeRunner
        self.now = now
        var continuation: AsyncStream<Emission>.Continuation!
        // Only the latest snapshot matters to a consumer that's behind: each
        // `PresenceSnapshot` carries FULL state (not a delta), so coalescing
        // to the newest element is lossless — a busy main actor should apply
        // one fresh snapshot, not replay a backlog of redundant body re-evals.
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            continuation = cont
        }
        self.continuation = continuation
    }

    deinit {
        pollTask?.cancel()
        refreshTask?.cancel()
        continuation?.finish()
    }

    // MARK: - Environment / control surface (facade forwards here)

    /// Push updated environment inputs. Mirrors what the facade's visibility
    /// setters / `setAppActive` / `@AppStorage` `didSet`s used to do directly.
    /// Returns quickly; scheduling decisions (ramp/backoff resets, refreshSoon)
    /// happen the same way `setAppActive`/`setUnifiedConsumerVisible` etc. did.
    func updateEnvironment(_ next: PresenceEnvironment, refreshSoon triggerRefreshSoon: Bool) {
        let previous = environment
        // `deferExpensiveProbesUntil` is engine-owned (set only by
        // `deferExpensiveProbesForSelectionOpen`) — the facade always pushes
        // `nil` for this field since it has no view onto engine-internal
        // timers, so preserve the engine's own value across every push
        // rather than letting each visibility/AppStorage change clobber an
        // in-flight defer window. This mirrors the pre-extraction facade,
        // where `deferExpensiveProbesUntil` was independent instance state
        // never touched by the visibility setters.
        var merged = next
        merged.deferExpensiveProbesUntil = environment.deferExpensiveProbesUntil
        environment = merged

        guard !AppRuntime.isRunningTests else { return }
        applyEnvironmentScheduling(previous: previous, next: next, refreshSoon: triggerRefreshSoon)
    }

    /// Start/stop/backoff/ramp/refreshSoon side effects for an environment
    /// transition. Split out of `updateEnvironment` so its scheduling parity
    /// can be exercised under XCTest (via `debugApplyEnvironmentScheduling`)
    /// without the `AppRuntime.isRunningTests` early-return that keeps the
    /// production start/stop machinery quiet during test runs.
    private func applyEnvironmentScheduling(previous: PresenceEnvironment,
                                            next: PresenceEnvironment,
                                            refreshSoon triggerRefreshSoon: Bool) {
        if next.enabled, !previous.enabled {
            startPollingIfNeeded()
        } else if !next.enabled, previous.enabled {
            stopPolling(clear: true)
        }

        let hadVisibleConsumer = previous.hasVisibleConsumer
        let hasVisibleConsumerNow = next.hasVisibleConsumer
        let appBecameActive = next.appIsActive && !previous.appIsActive
        let hadVisibleCockpitWindow = previous.hasVisibleCockpitWindow
        let hasVisibleCockpitWindowNow = next.hasVisibleCockpitWindow
        let cockpitWindowBecameVisible = !hadVisibleCockpitWindow && hasVisibleCockpitWindowNow

        if hasVisibleConsumerNow != hadVisibleConsumer || previous.appIsActive != next.appIsActive {
            resetStablePollBackoff()
        }
        // Arming parity with v4.0's per-setter `armForegroundProbeRamp()` calls
        // (`armForegroundProbeRamp` itself still gates on `hasVisibleConsumer`,
        // so each edge below is the same guard v4.0 applied at the call site):
        //   - consumer became visible while active (setUnifiedConsumerVisible /
        //     setCockpitConsumerVisible),
        //   - app became active (setAppActive — v4.0 armed unconditionally on
        //     `active`; the internal `hasVisibleConsumer` guard is what makes
        //     it a no-op when nothing is visible),
        //   - cockpit window became visible while active (setCockpitWindowVisible —
        //     `!hadVisibleCockpitWindow && hasVisibleCockpitWindow && appIsActive`).
        if (!hadVisibleConsumer && hasVisibleConsumerNow && next.appIsActive)
            || appBecameActive
            || (cockpitWindowBecameVisible && next.appIsActive) {
            armForegroundProbeRamp()
        }

        if triggerRefreshSoon {
            refreshSoon()
        }
    }

    /// Manual refresh: bypass probe throttling caches, cancel in-flight probes,
    /// and run a fresh cycle immediately. Identical semantics to the
    /// pre-extraction `refreshNow()`.
    func refreshNow() async {
        guard !AppRuntime.isRunningTests else { return }
        await performRefreshNow()
    }

    private func performRefreshNow() async {
        lastProcessProbeAt = nil
        cachedProcessPresences = []
        lastITermProbeAt = nil
        cachedITermPresences = []
        cachedITermTabTitleByTTY = [:]
        cachedITermTabTitleBySessionGuid = [:]
        environment.deferExpensiveProbesUntil = nil
        forceFullProbeNextRefresh = true
        consecutiveEmptySuppressedCycles = 0
        resetStablePollBackoff()
        armForegroundProbeRamp()
        refreshTask?.cancel()
        await probeRunner.cancelAll(reason: "manual-refresh")
        refreshTask = Task { [weak self] in
            await self?.refreshOnce()
        }
    }

    func deferExpensiveProbesForSelectionOpen(duration: TimeInterval = 2.5) {
        guard !AppRuntime.isRunningTests else { return }
        environment.deferExpensiveProbesUntil = Date().addingTimeInterval(duration)
    }

    func start() {
        startPollingIfNeeded()
    }

    func stop(clear: Bool) {
        stopPolling(clear: clear)
    }

    // MARK: - Sync-ish accessors for facade/tests

    func currentSnapshot() -> PresenceSnapshot {
        latestSnapshot
    }

#if DEBUG
    func debugPerformanceSnapshot() -> DebugPerformanceSnapshot {
        DebugPerformanceSnapshot(
            refreshGeneration: activeRefreshGeneration,
            staleRefreshResultsDropped: staleRefreshResultsDropped
        )
    }

    /// Test/debug hook mirroring `CodexActiveSessionsModel.debugRunManagedCommand` —
    /// exercises the exact probe-launch + generation-guard + cancel-on-replace path.
    func debugRunManagedCommand(kind: ManagedProbeKind = .processDiscovery,
                                executable: URL,
                                arguments: [String],
                                timeout: TimeInterval,
                                generation: UInt64? = nil) async -> Data? {
        await runManagedCommand(
            kind: kind,
            generation: generation ?? activeRefreshGeneration,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
    }

    /// Test-only: sets the environment directly, bypassing the
    /// `AppRuntime.isRunningTests` side-effect gate in `updateEnvironment`
    /// (which exists to keep production start/stop/refresh scheduling quiet
    /// under XCTest). `PresenceEngineTests` needs the gate OFF so it can drive
    /// `debugRefreshOnce()` cycles directly against injected environments.
    func debugSetEnvironment(_ next: PresenceEnvironment) {
        environment = next
    }

    /// Test-only: runs exactly one refresh cycle synchronously (awaited),
    /// exercising the full discovery -> merge -> classify -> publish-decision
    /// pipeline against whatever `ProbeRunner` was injected at init.
    @discardableResult
    func debugRefreshOnce() async -> PresenceSnapshot {
        await refreshOnce()
        return latestSnapshot
    }

    /// Test-only: bypasses the `AppRuntime.isRunningTests` gate on
    /// `refreshNow()` so `PresenceEngineTests` can exercise the exact
    /// cancel-inflight-probes + cache-reset semantics that the gate exists
    /// to keep quiet under production XCTest runs.
    func debugRefreshNow() async {
        await performRefreshNow()
    }

    /// Test-only: runs the environment scheduling side effects (start/stop,
    /// backoff reset, foreground-probe-ramp arming, refreshSoon) for a
    /// `previous -> next` transition, bypassing the `AppRuntime.isRunningTests`
    /// early-return in `updateEnvironment`. Sets `environment = next` first so
    /// downstream reads (e.g. `armForegroundProbeRamp`'s `hasVisibleConsumer`
    /// gate) see the post-transition state, matching production ordering.
    func debugApplyEnvironmentScheduling(previous: PresenceEnvironment, next: PresenceEnvironment) {
        environment = next
        applyEnvironmentScheduling(previous: previous, next: next, refreshSoon: false)
    }

    /// Test-only: whether the foreground probe ramp is currently armed
    /// (`resumeProbeBudgetIndex == 0`, the value `armForegroundProbeRamp` sets).
    func debugIsForegroundProbeRampArmed() -> Bool {
        resumeProbeBudgetIndex == 0
    }

    /// Test-only: exercises `startPollingIfNeeded`'s `environment.enabled`
    /// gate + `pollTask == nil` dedupe without the `AppRuntime.isRunningTests`
    /// early-return that keeps the real poll loop from spinning during XCTest.
    /// The spawned poll task's body still short-circuits at `refreshOnce`'s own
    /// `environment.enabled` guard, so no probes run — the observable effect is
    /// solely whether a `pollTask` was created (`debugPollTaskIsRunning`).
    func debugStartPollingIfNeeded() {
        guard environment.enabled else { return }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                let interval = await self.pollIntervalSeconds()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Test-only: whether a poll loop task is currently live.
    func debugPollTaskIsRunning() -> Bool {
        pollTask != nil
    }
#endif

    // MARK: - Polling (ported from CodexActiveSessionsModel.startPollingIfNeeded/stopPolling)

    private func startPollingIfNeeded() {
        guard !AppRuntime.isRunningTests else { return }
        guard environment.enabled else { return }
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshOnce()
                let interval = await self.pollIntervalSeconds()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopPolling(clear: Bool) {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        Task { await probeRunner.cancelAll(reason: clear ? "stop-clear" : "stop") }
        refreshInFlight = false
        refreshQueued = false
        resetStablePollBackoff()
        if clear {
            cachedProcessPresences = []
            cachedITermPresences = []
            cachedITermTabTitleByTTY = [:]
            cachedITermTabTitleBySessionGuid = [:]
            lastProcessProbeAt = nil
            lastITermProbeAt = nil
            lastPublishedPresenceSignatures = [:]
            lastPublishedRuntimeSubagentCountsByPresenceKey = [:]
            resumeProbeBudgetIndex = nil
            itermProbeRoundRobinCursor = 0
            forceFullProbeNextRefresh = false
            refreshGeneration &+= 1
            activeRefreshGeneration = refreshGeneration
            let cleared = PresenceSnapshot(
                presences: [],
                bySessionID: [:],
                byLogPath: [:],
                liveStateByPresenceKey: [:],
                idleReasonByPresenceKey: [:],
                lastActivityByPresenceKey: [:],
                runtimeSubagentCountsByPresenceKey: [:],
                membershipVersion: latestSnapshot.membershipVersion &+ 1,
                badgeVersion: latestSnapshot.badgeVersion
            )
            latestSnapshot = cleared
            emit(cleared, isMembershipChange: true)
        }
    }

    private func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.refreshOnce()
        }
    }

    private func pollIntervalSeconds() -> TimeInterval {
        let baseInterval = CodexActiveSessionsModel.effectivePollIntervalSeconds(
            appIsActive: environment.appIsActive,
            hasVisibleConsumer: environment.hasVisibleConsumer,
            isCockpitVisible: environment.isCockpitVisible,
            isPinnedCockpitVisible: environment.isPinnedCockpitVisible
        )
        return CodexActiveSessionsModel.effectiveStableBackoffPollInterval(
            baseInterval: baseInterval,
            consecutiveStableCycles: consecutiveStableCycles,
            appIsActive: environment.appIsActive,
            isCockpitVisible: environment.isCockpitVisible,
            isPinnedCockpitVisible: environment.isPinnedCockpitVisible
        )
    }

    private func armForegroundProbeRamp() {
        guard environment.hasVisibleConsumer else { return }
        resumeProbeBudgetIndex = 0
        resetStablePollBackoff()
    }

    private func resetStablePollBackoff() {
        consecutiveStableCycles = 0
    }

    private func nextITermProbeBudget() -> Int {
        let next = CodexActiveSessionsModel.nextITermProbeBudget(resumeIndex: resumeProbeBudgetIndex)
        resumeProbeBudgetIndex = next.nextResumeIndex
        return next.budget
    }

    // MARK: - Generation guard (ported from CodexActiveSessionsModel)

    private func beginRefreshGeneration() -> UInt64 {
        refreshGeneration &+= 1
        activeRefreshGeneration = refreshGeneration
        return activeRefreshGeneration
    }

    private func isCurrentRefreshGeneration(_ generation: UInt64) -> Bool {
        generation == activeRefreshGeneration
    }

    private func markStaleRefreshDrop() {
#if DEBUG
        staleRefreshResultsDropped &+= 1
#endif
    }

    // MARK: - Probe launches (ported from runManagedCommand)

    private func runManagedCommand(kind: ManagedProbeKind,
                                   generation: UInt64,
                                   executable: URL,
                                   arguments: [String],
                                   timeout: TimeInterval) async -> Data? {
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return nil
        }
        let data = await probeRunner.run(kind: kind, executable: executable, arguments: arguments, timeout: timeout)
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return nil
        }
        return data
    }

    // MARK: - Registry root discovery (ported from CodexActiveSessionsModel)

    private func registryRoots() -> [URL] {
        var candidates: [URL] = []

        if let override = Self.parsePath(environment.registryRootOverride) {
            candidates.append(override)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("active"))
        }
        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL.deletingLastPathComponent().appendingPathComponent("active"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/active"))
        return Self.dedupRoots(candidates)
    }

    private func codexSessionsRoots() -> [URL] {
        var candidates: [URL] = []
        if let sessionsOverride = UserDefaults.standard.string(forKey: "SessionsRootOverride"),
           let sessionsURL = Self.parsePath(sessionsOverride) {
            candidates.append(sessionsURL)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], let envURL = Self.parsePath(env) {
            candidates.append(envURL.appendingPathComponent("sessions"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"))
        return Self.dedupRoots(candidates)
    }

    private func claudeSessionsRoots() -> [URL] {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: PreferencesKey.Paths.claudeSessionsRootOverride)
            ?? defaults.string(forKey: "ClaudeSessionsRootOverride")
            ?? ""
        let discovery = ClaudeSessionDiscovery(customRoot: override.isEmpty ? nil : override)
        return Self.dedupRoots([discovery.sessionsRoot()])
    }

    private func opencodeSessionsRoots() -> [URL] {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: PreferencesKey.Paths.opencodeSessionsRootOverride)
            ?? defaults.string(forKey: "OpenCodeSessionsRootOverride")
            ?? ""
        let discovery = OpenCodeSessionDiscovery(customRoot: override.isEmpty ? nil : override)
        return Self.dedupRoots([discovery.sessionsRoot()])
    }

    private func antigravitySessionsRoots() -> [URL] {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: "AntigravitySessionsRootOverride") ?? ""
        let discovery = AntigravitySessionDiscovery(customRoot: override.isEmpty ? nil : override)
        return Self.dedupRoots([discovery.sessionsRoot()])
    }

    private static func dedupRoots(_ candidates: [URL]) -> [URL] {
        var out: [URL] = []
        var seen: Set<String> = []
        for u in candidates {
            let key = u.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(u) }
        }
        return out
    }

    private static func parsePath(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - The refresh cycle (ported from CodexActiveSessionsModel.refreshOnce)

    private func refreshOnce() async {
        guard environment.enabled else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        let generation = beginRefreshGeneration()
        refreshInFlight = true
        defer {
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in
                    await self?.refreshOnce()
                }
            }
        }

        let now = Date()
        let ttl = CodexActiveSessionsModel.defaultStaleTTL
        let rootPaths = registryRoots().map(\.path)
        let codexSessionRoots = codexSessionsRoots().map(\.path)
        let claudeSessionRoots = claudeSessionsRoots().map(\.path)
        let antigravitySessionRoots = antigravitySessionsRoots().map(\.path)
        let opencodeSessionRoots = opencodeSessionsRoots().map(\.path)

        let previousLogKeys = Set(latestSnapshot.byLogPath.keys)
        let previousSessionKeys = Set(latestSnapshot.bySessionID.keys)
        let previousLiveStates = latestSnapshot.liveStateByPresenceKey

        let hasVisibleConsumerSnapshot = environment.hasVisibleConsumer
        let appIsActiveSnapshot = environment.appIsActive
        let isCockpitVisibleSnapshot = environment.isCockpitVisible
        let isPinnedCockpitVisibleSnapshot = environment.isPinnedCockpitVisible
        let deferExpensiveProbesSnapshot = environment.deferExpensiveProbesUntil.map { now < $0 } ?? false

        let shouldUseITermSnapshot = CodexActiveSessionsModel.shouldProbeITermSessions(
            appIsActive: appIsActiveSnapshot,
            hasVisibleConsumer: hasVisibleConsumerSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )
        let shouldProbeITermSnapshot: Bool = {
            guard !deferExpensiveProbesSnapshot else { return false }
            guard shouldUseITermSnapshot else { return false }
            let probeMinInterval = CodexActiveSessionsModel.itermProbeMinIntervalSeconds(
                appIsActive: appIsActiveSnapshot,
                isCockpitVisible: isCockpitVisibleSnapshot,
                isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
            )
            guard let last = lastITermProbeAt else { return true }
            return now.timeIntervalSince(last) >= probeMinInterval
        }()

        guard let probeResult = await performRefreshDiscovery(
            generation: generation,
            now: now,
            ttl: ttl,
            rootPaths: rootPaths,
            codexSessionRoots: codexSessionRoots,
            claudeSessionRoots: claudeSessionRoots,
            antigravitySessionRoots: antigravitySessionRoots,
            opencodeSessionRoots: opencodeSessionRoots,
            hasVisibleConsumerSnapshot: hasVisibleConsumerSnapshot,
            appIsActiveSnapshot: appIsActiveSnapshot,
            isCockpitVisibleSnapshot: isCockpitVisibleSnapshot,
            isPinnedCockpitVisibleSnapshot: isPinnedCockpitVisibleSnapshot,
            deferExpensiveProbesSnapshot: deferExpensiveProbesSnapshot,
            shouldUseITermSnapshot: shouldUseITermSnapshot,
            shouldProbeITermSnapshot: shouldProbeITermSnapshot
        ) else {
            return
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return
        }

        let latestProcessProbe = CodexActiveSessionsModel.filterSupportedPresences(
            probeResult.loaded.filter { $0.publisher == "agent-sessions-process" }
        )
        let loaded = CodexActiveSessionsModel.coalescePresencesByTTY(
            CodexActiveSessionsModel.filterSupportedPresences(probeResult.loaded)
        )

        if probeResult.didProbeITerm {
            cachedITermPresences = probeResult.itermPresences
            lastITermProbeAt = now
            if !probeResult.itermTabTitleByTTY.isEmpty || !probeResult.itermTabTitleBySessionGuid.isEmpty {
                cachedITermTabTitleByTTY = probeResult.itermTabTitleByTTY
                cachedITermTabTitleBySessionGuid = probeResult.itermTabTitleBySessionGuid
            }
        } else if shouldUseITermSnapshot {
            cachedITermPresences = cachedITermPresences.filter { !$0.isStale(now: now, ttl: ttl) }
        }

        if probeResult.didProbeProcesses {
            cachedProcessPresences = latestProcessProbe
            lastProcessProbeAt = now
        } else {
            cachedProcessPresences = cachedProcessPresences.filter { !$0.isStale(now: now, ttl: ttl) }
        }

        var sessionMap: [String: CodexActivePresence] = [:]
        var logMap: [String: CodexActivePresence] = [:]
        var fallbackMap: [String: CodexActivePresence] = [:]
        for p in loaded {
            var keyed = false
            if let id = p.sessionId, !id.isEmpty {
                let key = CodexActiveSessionsModel.sessionLookupKey(source: p.source, sessionId: id)
                sessionMap[key] = CodexActiveSessionsModel.merge(sessionMap[key], p)
                keyed = true
            }
            if let log = p.sessionLogPath, !log.isEmpty {
                let norm = CodexActiveSessionsModel.normalizePath(log)
                let key = CodexActiveSessionsModel.logLookupKey(source: p.source, normalizedPath: norm)
                logMap[key] = CodexActiveSessionsModel.merge(logMap[key], p)
                keyed = true
            }
            if !keyed {
                let key = CodexActiveSessionsModel.presenceKey(for: p)
                if key != "unknown" {
                    fallbackMap[key] = CodexActiveSessionsModel.merge(fallbackMap[key], p)
                }
            }
        }

        var ui: [CodexActivePresence] = Array(logMap.values)
        for p in sessionMap.values {
            if let log = p.sessionLogPath, !log.isEmpty {
                let key = CodexActiveSessionsModel.logLookupKey(source: p.source, normalizedPath: CodexActiveSessionsModel.normalizePath(log))
                if logMap[key] != nil { continue }
            }
            ui.append(p)
        }
        let sortedFallbacks = Array(fallbackMap.values).sorted { a, b in
            (a.pid != nil ? 0 : 1) < (b.pid != nil ? 0 : 1)
        }
        ui = CodexActiveSessionsModel.reconcileFallbackPresences(sortedFallbacks, into: ui)
        let (effectiveTabTitleByTTY, effectiveTabTitleBySessionGuid) = CodexActiveSessionsModel.effectiveITermTitleMaps(
            didProbeITerm: probeResult.didProbeITerm,
            probeTitleByTTY: probeResult.itermTabTitleByTTY,
            probeTitleBySessionGuid: probeResult.itermTabTitleBySessionGuid,
            cachedTitleByTTY: cachedITermTabTitleByTTY,
            cachedTitleBySessionGuid: cachedITermTabTitleBySessionGuid
        )
        ui = CodexActiveSessionsModel.enrichPresencesWithITermTabTitles(
            ui,
            tabTitleByTTY: effectiveTabTitleByTTY,
            tabTitleBySessionGuid: effectiveTabTitleBySessionGuid
        )

        let probedITermPresenceKeys = plannedITermProbePresenceKeys(
            for: ui,
            previousLiveStates: previousLiveStates,
            hasVisibleConsumer: shouldProbeITermSnapshot,
            appIsActive: appIsActiveSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )

        let classification = await classifyLiveStatesAsync(
            for: ui,
            generation: generation,
            now: now,
            probeITerm: shouldUseITermSnapshot,
            timeout: Self.processProbeTimeout,
            previousLiveStates: previousLiveStates,
            probedITermPresenceKeys: probedITermPresenceKeys
        )
        let nextLiveStates = classification.liveStates
        let rawIdleReasons = classification.idleReasons
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return
        }

        let nextLastActivityByPresenceKey = CodexActiveSessionsModel.lastActivityByPresenceKey(for: ui)

        let cockpitRecentlyVisible = environment.lastCockpitVisibleAt.map { now.timeIntervalSince($0) < 10 } ?? false
        let cockpitIsOrWasVisible = isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot || cockpitRecentlyVisible
        let baseSuppressEmptyPublish = CodexActiveSessionsModel.shouldSuppressTransientEmptyPublish(
            ui: ui,
            cockpitVisible: isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot,
            cockpitRecentlyVisible: cockpitRecentlyVisible,
            didProbeProcesses: probeResult.didProbeProcesses,
            didProbeITerm: probeResult.didProbeITerm,
            registryHadPresences: probeResult.registryHadPresences
        )
        let shouldSuppressRecentTransition = CodexActiveSessionsModel.shouldSuppressEmptyTransition(
            uiIsEmpty: ui.isEmpty,
            hadPreviouslyPublishedPresences: !lastPublishedPresenceSignatures.isEmpty,
            cockpitIsOrWasVisible: cockpitIsOrWasVisible,
            consecutiveSuppressedCycles: consecutiveEmptySuppressedCycles
        )
        let shouldSuppressEmptyPublish = baseSuppressEmptyPublish || shouldSuppressRecentTransition
        if shouldSuppressEmptyPublish, ui.isEmpty {
            consecutiveEmptySuppressedCycles += 1
        } else {
            consecutiveEmptySuppressedCycles = 0
        }

        var nextSnapshot = latestSnapshot
        if !shouldSuppressEmptyPublish {
            nextSnapshot.bySessionID = sessionMap
            nextSnapshot.byLogPath = logMap
            nextSnapshot.liveStateByPresenceKey = nextLiveStates
            nextSnapshot.lastActivityByPresenceKey = nextLastActivityByPresenceKey

            var idleReasonByPresenceKey = nextSnapshot.idleReasonByPresenceKey
            let idleKeys = Set(rawIdleReasons.keys)
            for key in Array(idleReasonByPresenceKey.keys) where !idleKeys.contains(key) {
                idleReasonByPresenceKey.removeValue(forKey: key)
            }
            for (key, reason) in rawIdleReasons {
                idleReasonByPresenceKey[key] = reason
            }
            nextSnapshot.idleReasonByPresenceKey = idleReasonByPresenceKey
        }

        let nextLogKeys = Set(logMap.keys)
        let nextSessionKeys = Set(sessionMap.keys)
        let membershipChanged = (nextLogKeys != previousLogKeys) || (nextSessionKeys != previousSessionKeys)
        let liveStateChanged = nextLiveStates != previousLiveStates

        let nextSignatures = CodexActiveSessionsModel.stablePresenceSignatures(for: ui)
        let metadataChanged = nextSignatures != lastPublishedPresenceSignatures
        let stateChanged = CodexActiveSessionsModel.shouldResetStablePollBackoff(
            membershipChanged: membershipChanged,
            liveStateChanged: liveStateChanged,
            metadataChanged: metadataChanged
        )

        // `didPublishPresences` mirrors the pre-extraction publish condition
        // exactly (membership OR metadata OR live-state change). `isRealMembershipChange`
        // narrows that to true join/leave (the log/session key sets actually
        // differ) — this is the NEW distinction the cadence diet needs: a
        // live-state flip (activeWorking <-> openIdle) with no membership
        // change is "freshness-only" and may be throttled while the app is
        // inactive; a real join/leave (or badge change) never is.
        var didPublishPresences = false
        if !shouldSuppressEmptyPublish, (membershipChanged || metadataChanged || liveStateChanged) {
            nextSnapshot.presences = ui.sorted(by: { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) })
            lastPublishedPresenceSignatures = nextSignatures
            nextSnapshot.membershipVersion &+= 1
            didPublishPresences = true
        }
        let isRealMembershipChange = membershipChanged

        var didPublishBadge = false
        let shouldTrackRuntimeSubagentBadges = (isCockpitVisibleSnapshot || isPinnedCockpitVisibleSnapshot)
            && ui.contains(where: { $0.source == .codex })
        if shouldTrackRuntimeSubagentBadges {
            let nextRuntimeSubagentCountsByPresenceKey = CodexActiveSessionsModel.runtimeCodexSubagentCountsByPresenceKey(
                presences: ui,
                stateDBURL: nil
            )
            if nextRuntimeSubagentCountsByPresenceKey != lastPublishedRuntimeSubagentCountsByPresenceKey {
                lastPublishedRuntimeSubagentCountsByPresenceKey = nextRuntimeSubagentCountsByPresenceKey
                nextSnapshot.runtimeSubagentCountsByPresenceKey = nextRuntimeSubagentCountsByPresenceKey
                nextSnapshot.badgeVersion &+= 1
                didPublishBadge = true
            }
        }

        if stateChanged {
            resetStablePollBackoff()
        } else {
            consecutiveStableCycles = min(consecutiveStableCycles + 1, 1_000_000)
        }

        latestSnapshot = nextSnapshot

        if didPublishPresences || didPublishBadge {
            // Membership (join/leave) and badge changes always emit immediately —
            // never subject to the inactive-freshness throttle, matching the
            // plan's "membership/badge changes always emit immediately" rule.
            let isMembershipChange = isRealMembershipChange || didPublishBadge
            if isMembershipChange {
                emit(nextSnapshot, isMembershipChange: true)
            } else {
                emitFreshnessOnlyIfDue(nextSnapshot)
            }
        }
    }

    /// Cadence diet: a freshness-only change (live-state flip or stable-metadata
    /// churn with no real membership/badge change) is throttled to at most one
    /// emission per `inactiveFreshnessMinInterval` while the app is inactive.
    /// In the foreground the throttle is a no-op (interval treated as 0), so
    /// foreground cadence is byte-identical to pre-extraction behavior — the
    /// ONLY intended behavior change is this background throttle.
    private func emitFreshnessOnlyIfDue(_ snapshot: PresenceSnapshot) {
        guard !environment.appIsActive else {
            emit(snapshot, isMembershipChange: false)
            return
        }
        let nowValue = now()
        let elapsed = lastFreshnessOnlyEmitAt.map { nowValue.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard elapsed >= Self.inactiveFreshnessMinInterval else { return }
        emit(snapshot, isMembershipChange: false)
    }

    private func emit(_ snapshot: PresenceSnapshot, isMembershipChange: Bool) {
        lastFreshnessOnlyEmitAt = now()
        continuation?.yield(Emission(snapshot: snapshot, isMembershipChange: isMembershipChange))
    }

    // MARK: - Discovery (ported from performRefreshDiscovery/discoverProcessPresences)

    private struct RefreshDiscoveryResult {
        let loaded: [CodexActivePresence]
        let didProbeProcesses: Bool
        let didProbeITerm: Bool
        let registryHadPresences: Bool
        let itermPresences: [CodexActivePresence]
        let itermTabTitleByTTY: [String: String]
        let itermTabTitleBySessionGuid: [String: String]
    }

    private func performRefreshDiscovery(generation: UInt64,
                                         now: Date,
                                         ttl: TimeInterval,
                                         rootPaths: [String],
                                         codexSessionRoots: [String],
                                         claudeSessionRoots: [String],
                                         antigravitySessionRoots: [String],
                                         opencodeSessionRoots: [String],
                                         hasVisibleConsumerSnapshot: Bool,
                                         appIsActiveSnapshot: Bool,
                                         isCockpitVisibleSnapshot: Bool,
                                         isPinnedCockpitVisibleSnapshot: Bool,
                                         deferExpensiveProbesSnapshot: Bool,
                                         shouldUseITermSnapshot: Bool,
                                         shouldProbeITermSnapshot: Bool) async -> RefreshDiscoveryResult? {
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return nil
        }

        var out: [CodexActivePresence] = []
        var itermPresences: [CodexActivePresence] = []
        var itermTabTitleByTTY: [String: String] = [:]
        var itermTabTitleBySessionGuid: [String: String] = [:]
        let decoder = CodexActiveSessionsModel.makeDecoder()
#if DEBUG
        let _lpSpan = Perf.begin("loadPresences", thresholdMs: 4, "roots=\(rootPaths.count)")
#endif
        for path in rootPaths {
            out.append(contentsOf: CodexActiveSessionsModel.filterSupportedPresences(
                CodexActiveSessionsModel.loadPresences(from: URL(fileURLWithPath: path), decoder: decoder, now: now, ttl: ttl)
            ))
        }
#if DEBUG
        Perf.end(_lpSpan)
#endif

        let registryHasPresences = !out.isEmpty
        let processProbeMinInterval = CodexActiveSessionsModel.processProbeMinIntervalSeconds(
            registryHasPresences: registryHasPresences,
            hasVisibleConsumer: hasVisibleConsumerSnapshot,
            appIsActive: appIsActiveSnapshot,
            isCockpitVisible: isCockpitVisibleSnapshot,
            isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
        )
        let processPresenceCacheTTL = CodexActiveSessionsModel.effectiveCachedProcessPresenceTTL(
            baseTTL: ttl,
            processProbeMinInterval: processProbeMinInterval,
            pollInterval: CodexActiveSessionsModel.effectivePollIntervalSeconds(
                appIsActive: appIsActiveSnapshot,
                hasVisibleConsumer: hasVisibleConsumerSnapshot,
                isCockpitVisible: isCockpitVisibleSnapshot,
                isPinnedCockpitVisible: isPinnedCockpitVisibleSnapshot
            ),
            hasVisibleConsumer: hasVisibleConsumerSnapshot
        )
        let shouldProbeProcesses: Bool = {
            guard !deferExpensiveProbesSnapshot else { return false }
            guard let last = lastProcessProbeAt else { return true }
            return now.timeIntervalSince(last) >= processProbeMinInterval
        }()

        if shouldProbeProcesses {
            let processPresences = await discoverProcessPresences(
                generation: generation,
                now: now,
                codexSessionRoots: codexSessionRoots,
                claudeSessionRoots: claudeSessionRoots,
                antigravitySessionRoots: antigravitySessionRoots,
                opencodeSessionRoots: opencodeSessionRoots,
                timeout: Self.processProbeTimeout
            )
            guard isCurrentRefreshGeneration(generation) else {
                markStaleRefreshDrop()
                return nil
            }
            out.append(contentsOf: processPresences)
        } else {
            out.append(contentsOf: CodexActiveSessionsModel.filterSupportedPresences(
                cachedProcessPresences.filter { !$0.isStale(now: now, ttl: processPresenceCacheTTL) }
            ))
        }

        if shouldProbeITermSnapshot {
            let sessions = await loadITermSessions(generation: generation, timeout: Self.processProbeTimeout)
            guard isCurrentRefreshGeneration(generation) else {
                markStaleRefreshDrop()
                return nil
            }
            if !sessions.isEmpty {
                itermTabTitleByTTY = CodexActiveSessionsModel.itermTabTitleByTTY(sessions)
                itermTabTitleBySessionGuid = CodexActiveSessionsModel.itermTabTitleBySessionGuid(sessions)
                itermPresences = CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .codex, now: now)
                itermPresences += CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .claude, now: now)
                itermPresences += CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .antigravity, now: now)
                itermPresences += CodexActiveSessionsModel.presencesFromITermSessions(sessions, source: .opencode, now: now)
                out.append(contentsOf: itermPresences)
            }
        } else if shouldUseITermSnapshot {
            itermPresences = CodexActiveSessionsModel.filterSupportedPresences(
                cachedITermPresences.filter { !$0.isStale(now: now, ttl: ttl) }
            )
            itermTabTitleByTTY = cachedITermTabTitleByTTY
            itermTabTitleBySessionGuid = cachedITermTabTitleBySessionGuid
            out.append(contentsOf: itermPresences)
        }

        return RefreshDiscoveryResult(
            loaded: out,
            didProbeProcesses: shouldProbeProcesses,
            didProbeITerm: shouldProbeITermSnapshot,
            registryHadPresences: registryHasPresences,
            itermPresences: itermPresences,
            itermTabTitleByTTY: itermTabTitleByTTY,
            itermTabTitleBySessionGuid: itermTabTitleBySessionGuid
        )
    }

    private static let processProbeTimeout: TimeInterval = 0.75

    private func discoverProcessPresences(generation: UInt64,
                                          now: Date,
                                          codexSessionRoots: [String],
                                          claudeSessionRoots: [String],
                                          antigravitySessionRoots: [String],
                                          opencodeSessionRoots: [String],
                                          timeout: TimeInterval) async -> [CodexActivePresence] {
        let user = NSUserName()
        let psData = await runManagedCommand(
            kind: .processDiscovery,
            generation: generation,
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["axww", "-o", "pid=,tty=,command="],
            timeout: timeout
        )
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }

        let commandInfos = psData.map { CodexActiveSessionsModel.parsePSCommandListOutput(String(decoding: $0, as: UTF8.self)) } ?? []
        let claudeCommandPIDs = Array(
            Set(
                commandInfos
                    .filter { info in
                        guard info.tty != nil else { return false }
                        return CodexActiveSessionsModel.commandContainsNeedle(info.command, needles: ["claude", "claude-code"])
                    }
                    .map(\.pid)
            )
        ).sorted()
        let opencodeCommandPIDs = Array(
            Set(
                commandInfos
                    .filter { info in
                        guard info.tty != nil else { return false }
                        return CodexActiveSessionsModel.commandContainsNeedle(info.command, needles: ["opencode"])
                    }
                    .map(\.pid)
            )
        ).sorted()
        let antigravityCommandPIDs = Array(
            Set(
                commandInfos
                    .filter { info in
                        guard info.tty != nil else { return false }
                        return CodexActiveSessionsModel.commandContainsNeedle(info.command, needles: ["agy", "antigravity"])
                    }
                    .map(\.pid)
            )
        ).sorted()

        let codexInfos = await discoverLsofPIDInfos(
            generation: generation,
            queryArguments: ["-w", "-a", "-c", "codex", "-u", user, "-nP", "-F", "pftn"],
            sessionsRoots: codexSessionRoots,
            source: .codex,
            timeout: timeout
        )
        let claudeInfos: [Int: CodexActiveSessionsModel.LsofPIDInfo]
        if claudeCommandPIDs.isEmpty {
            claudeInfos = [:]
        } else {
            claudeInfos = await discoverLsofPIDInfos(
                generation: generation,
                queryArguments: ["-w", "-a", "-p", claudeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: claudeSessionRoots,
                source: .claude,
                timeout: timeout
            )
        }
        let opencodeInfos = await discoverLsofPIDInfos(
            generation: generation,
            queryArguments: ["-w", "-a", "-c", "opencode", "-u", user, "-nP", "-F", "pftn"],
            sessionsRoots: opencodeSessionRoots,
            source: .opencode,
            timeout: timeout
        )
        let opencodeCommandInfos: [Int: CodexActiveSessionsModel.LsofPIDInfo]
        if opencodeCommandPIDs.isEmpty {
            opencodeCommandInfos = [:]
        } else {
            opencodeCommandInfos = await discoverLsofPIDInfos(
                generation: generation,
                queryArguments: ["-w", "-a", "-p", opencodeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: opencodeSessionRoots,
                source: .opencode,
                timeout: timeout
            )
        }
        let antigravityInfos: [Int: CodexActiveSessionsModel.LsofPIDInfo]
        if antigravityCommandPIDs.isEmpty {
            antigravityInfos = [:]
        } else {
            antigravityInfos = await discoverLsofPIDInfos(
                generation: generation,
                queryArguments: ["-w", "-a", "-p", antigravityCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: antigravitySessionRoots,
                source: .antigravity,
                timeout: timeout
            )
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }
        let pidInfoBySource: [SessionSource: [Int: CodexActiveSessionsModel.LsofPIDInfo]] = [
            .codex: codexInfos,
            .claude: claudeInfos,
            .antigravity: antigravityInfos,
            .opencode: CodexActiveSessionsModel.mergePIDInfos(opencodeInfos, with: opencodeCommandInfos)
        ]
        let allPIDs = Array(pidInfoBySource.values.flatMap(\.keys)).sorted()
        var envByPID: [Int: CodexActiveSessionsModel.PSProcessEnvMeta] = [:]
        if !allPIDs.isEmpty,
           let envData = await runManagedCommand(
                kind: .processDiscovery,
                generation: generation,
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["eww", "-p", allPIDs.map(String.init).joined(separator: ",")],
                timeout: timeout
           ) {
            envByPID = CodexActiveSessionsModel.parsePSEnvironmentOutput(String(decoding: envData, as: UTF8.self))
        }
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return []
        }

        var out: [CodexActivePresence] = []
        var assignedLogPaths: Set<String> = []
        for (source, infos) in pidInfoBySource {
            for var info in infos.values {
                if let envMeta = envByPID[info.pid] {
                    info.termProgram = envMeta.termProgram
                    info.itermSessionId = envMeta.itermSessionId
                }
                var presence = CodexActivePresence()
                presence.schemaVersion = 1
                presence.publisher = "agent-sessions-process"
                presence.kind = "interactive"
                presence.source = source
                presence.sessionId = info.sessionID
                presence.sessionLogPath = info.sessionLogPath
                presence.workspaceRoot = info.cwd
                if presence.sessionLogPath == nil, source == .claude, let cwd = info.cwd {
                    let root = claudeSessionRoots.first ?? (NSHomeDirectory() + "/.claude")
                    let candidates = CodexActiveSessionsModel.claudeSessionLogCandidates(cwd: cwd, claudeRoot: root, recencyCutoff: now.addingTimeInterval(-60))
                    if let match = candidates.first(where: { !assignedLogPaths.contains($0.path) }) {
                        presence.sessionLogPath = match.path
                        presence.sessionId = match.sessionID
                        assignedLogPaths.insert(match.path)
                    }
                } else if let logPath = presence.sessionLogPath {
                    assignedLogPaths.insert(logPath)
                }
                presence.pid = info.pid
                presence.tty = CodexActiveSessionsModel.normalizedTTY(info.tty)
                presence.openSessionLogPaths = info.openSessionLogPaths
                presence.lastSeenAt = now
                var terminal = CodexActivePresence.Terminal()
                terminal.termProgram = info.termProgram
                terminal.itermSessionId = info.itermSessionId
                presence.terminal = terminal
                out.append(presence)
            }
        }
        return out
    }

    private func discoverLsofPIDInfos(generation: UInt64,
                                      queryArguments: [String],
                                      sessionsRoots: [String],
                                      source: SessionSource,
                                      timeout: TimeInterval) async -> [Int: CodexActiveSessionsModel.LsofPIDInfo] {
        guard let out = await runManagedCommand(
            kind: .processDiscovery,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: queryArguments,
            timeout: timeout
        ) else {
            return [:]
        }
        let roots = sessionsRoots.map(CodexActiveSessionsModel.normalizePath)
        return CodexActiveSessionsModel.parseLsofMachineOutput(String(decoding: out, as: UTF8.self), sessionsRoots: roots, source: source)
    }

    // MARK: - Classification (ported from classifyLiveStatesAsync)

    private func classifyLiveStatesAsync(for presences: [CodexActivePresence],
                                         generation: UInt64,
                                         now: Date,
                                         probeITerm: Bool,
                                         timeout: TimeInterval,
                                         previousLiveStates: [String: CodexLiveState],
                                         probedITermPresenceKeys: Set<String>) async -> CodexActiveSessionsModel.LiveStateClassification {
        let probeTargets = CodexActiveSessionsModel.itermProbeTargets(
            from: presences,
            selectedPresenceKeys: probedITermPresenceKeys,
            probeITerm: probeITerm
        )
        let batchProbeResults = await captureBatchedITermProbeResults(
            generation: generation,
            for: probeTargets,
            timeout: timeout
        )
        guard isCurrentRefreshGeneration(generation) else {
            markStaleRefreshDrop()
            return CodexActiveSessionsModel.LiveStateClassification(liveStates: previousLiveStates, idleReasons: [:])
        }
#if DEBUG
        let _classifySpan = Perf.begin("refreshClassify", thresholdMs: 4)
#endif
        let result = CodexActiveSessionsModel.classifyLiveStates(
            for: presences,
            now: now,
            probeITerm: probeITerm,
            previousLiveStates: previousLiveStates,
            probedITermPresenceKeys: probedITermPresenceKeys,
            batchProbeResults: batchProbeResults
        )
#if DEBUG
        Perf.end(_classifySpan)
#endif
        return result
    }

    private func plannedITermProbePresenceKeys(for presences: [CodexActivePresence],
                                               previousLiveStates: [String: CodexLiveState],
                                               hasVisibleConsumer: Bool,
                                               appIsActive: Bool,
                                               isCockpitVisible: Bool,
                                               isPinnedCockpitVisible: Bool) -> Set<String> {
        guard hasVisibleConsumer else { return [] }
        let candidates = CodexActiveSessionsModel.itermProbeCandidateKeys(for: presences).sorted()
        guard !candidates.isEmpty else { return [] }

        if forceFullProbeNextRefresh {
            forceFullProbeNextRefresh = false
            resumeProbeBudgetIndex = nil
            itermProbeRoundRobinCursor = candidates.count == 0 ? 0 : (itermProbeRoundRobinCursor % candidates.count)
            return Set(candidates)
        }

        if !appIsActive, (isPinnedCockpitVisible || isCockpitVisible) {
            let selection = CodexActiveSessionsModel.selectPinnedBackgroundITermProbeKeys(
                sortedCandidateKeys: candidates,
                previousLiveStates: previousLiveStates,
                waitingBudget: CodexActiveSessionsModel.pinnedBackgroundWaitingITermProbeBudget,
                start: itermProbeRoundRobinCursor
            )
            itermProbeRoundRobinCursor = selection.nextCursor
            return Set(selection.selected)
        }

        let budget = nextITermProbeBudget()
        let selection = CodexActiveSessionsModel.selectRoundRobinKeys(
            sortedKeys: candidates,
            start: itermProbeRoundRobinCursor,
            budget: budget
        )
        itermProbeRoundRobinCursor = selection.nextCursor
        return Set(selection.selected)
    }

    // MARK: - iTerm batch probe (ported from captureBatchedITermProbeResults)

    private func captureBatchedITermProbeResults(generation: UInt64,
                                                 for targets: [CodexActiveSessionsModel.ITermProbeTarget],
                                                 timeout: TimeInterval) async -> [String: CodexActiveSessionsModel.ITermProbeResult] {
        guard !targets.isEmpty else { return [:] }

        let rowSeparator = String(UnicodeScalar(0x1E)!)
        let fieldSeparator = String(UnicodeScalar(0x1F)!)
        let scriptLines = [
            "on run argv",
            "set rowSep to character id 30",
            "set fieldSep to character id 31",
            "set outRows to {}",
            "set targetCount to ((count of argv) div 3)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sttyBase to stty",
            "if sttyBase starts with \"/dev/\" then set sttyBase to text 6 thru -1 of sttyBase",
            "repeat with idx from 1 to targetCount",
            "set baseIndex to ((idx - 1) * 3)",
            "set presenceKey to item (baseIndex + 1) of argv",
            "set targetGuid to item (baseIndex + 2) of argv",
            "set targetTTY to item (baseIndex + 3) of argv",
            "set targetTTYBase to targetTTY",
            "if targetTTYBase starts with \"/dev/\" then set targetTTYBase to text 6 thru -1 of targetTTYBase",
            "if ((targetGuid is not \"\" and sid is targetGuid) or (targetTTYBase is not \"\" and (stty is targetTTY or stty is targetTTYBase or sttyBase is targetTTYBase))) then",
            "set txt to \"\"",
            "try",
            "set txt to contents of s",
            "on error",
            "set txt to \"\"",
            "end try",
            "set txtLen to length of txt",
            "if txtLen > 4000 then",
            "set txt to text (txtLen - 3999) thru txtLen of txt",
            "end if",
            "set processing to false",
            "try",
            "set processing to is processing of s",
            "on error",
            "set processing to false",
            "end try",
            "set atPrompt to false",
            "try",
            "set atPrompt to is at shell prompt of s",
            "on error",
            "set atPrompt to false",
            "end try",
            "set end of outRows to (presenceKey & fieldSep & (processing as string) & fieldSep & (atPrompt as string) & fieldSep & txt)",
            "exit repeat",
            "end if",
            "end repeat",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "set AppleScript's text item delimiters to rowSep",
            "return outRows as text",
            "end run"
        ]

        let arguments = scriptLines.flatMap { ["-e", $0] } + targets.flatMap { target in
            [target.presenceKey, target.guid, target.tty]
        }
        guard let out = await runManagedCommand(
            kind: .iTermBatchProbe,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: arguments,
            timeout: timeout
        ) else {
            return [:]
        }

        let raw = String(decoding: out, as: UTF8.self)
        return CodexActiveSessionsModel.parseBatchedITermProbeOutput(raw, rowSeparator: rowSeparator, fieldSeparator: fieldSeparator)
    }

    // MARK: - iTerm inventory (ported from loadITermSessions instance variant)

    private func loadITermSessions(generation: UInt64, timeout: TimeInterval) async -> [CodexActiveSessionsModel.ITermSessionInfo] {
        let scriptLines = [
            "set outRows to {}",
            "set sep to (ASCII character 9)",
            "tell application \"iTerm2\"",
            "repeat with w in windows",
            "set wname to name of w",
            "repeat with t in tabs of w",
            "repeat with s in sessions of t",
            "set sid to id of s",
            "set stty to tty of s",
            "set sname to name of s",
            "set ttitle to \"\"",
            "try",
            "set ttitle to title of t",
            "on error",
            "set ttitle to \"\"",
            "end try",
            "if ttitle is missing value then set ttitle to \"\"",
            "set end of outRows to (sid & sep & stty & sep & sname & sep & ttitle & sep & wname)",
            "end repeat",
            "end repeat",
            "end repeat",
            "end tell",
            "set AppleScript's text item delimiters to linefeed",
            "return outRows as text"
        ]
        guard let out = await runManagedCommand(
            kind: .iTermInventory,
            generation: generation,
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: scriptLines.flatMap { ["-e", $0] },
            timeout: timeout
        ) else {
            return []
        }
        return CodexActiveSessionsModel.parseITermSessionListOutput(String(decoding: out, as: UTF8.self))
    }
}

/// Real fork/exec `ProbeRunner`, ported unchanged from
/// `CodexActiveSessionsModel.ManagedProbeCommand` / `runManagedCommand` /
/// `waitForManagedProbeExit` / `readManagedProbeOutput`. This is the only
/// place `Process.run()` (fork/exec) happens for presence probes — it now
/// executes off the main actor, inside the `PresenceEngine` actor's isolation
/// (via `await` from actor-isolated callers), rather than pre-await on main.
actor RealProbeRunner: ProbeRunner {
    private final class ManagedProbeCommand {
        let id = UUID()
        let process = Process()
        let stdoutPipe = Pipe()

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
        }

        func start() throws {
            try process.run()
        }

        func terminate() {
            guard process.isRunning else { return }
            process.terminate()
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private enum WaitResult {
        case exited
        case timedOut
    }

    private final class WaitState {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WaitResult, Never>?

        init(_ continuation: CheckedContinuation<WaitResult, Never>) {
            self.continuation = continuation
        }

        func resumeIfNeeded(_ result: WaitResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    private var inFlightCommands: [PresenceEngine.ManagedProbeKind: ManagedProbeCommand] = [:]

    func run(kind: PresenceEngine.ManagedProbeKind,
             executable: URL,
             arguments: [String],
             timeout: TimeInterval) async -> Data? {
        let command = ManagedProbeCommand(executable: executable, arguments: arguments)
        if let existing = inFlightCommands[kind] {
            existing.terminate()
        }
        inFlightCommands[kind] = command

        do {
            try command.start()
        } catch {
            if inFlightCommands[kind]?.id == command.id {
                inFlightCommands.removeValue(forKey: kind)
            }
            return nil
        }

        let stdoutHandle = command.stdoutPipe.fileHandleForReading
        async let drainedOutput = Self.readOutput(from: stdoutHandle)
        let waitResult = await withTaskCancellationHandler {
            await self.waitForExit(command.process, timeout: timeout)
        } onCancel: { [weak self] in
            Task { await self?.cancel(kind: kind, reason: "task-cancelled") }
        }
        command.process.terminationHandler = nil
        let timedOut = waitResult == .timedOut
        if timedOut {
            await cancel(kind: kind, reason: "timeout")
        }
        let wasCancelled = Task.isCancelled
        let data = await drainedOutput
        let stillOwned = inFlightCommands[kind]?.id == command.id
        if inFlightCommands[kind]?.id == command.id {
            inFlightCommands.removeValue(forKey: kind)
        }
        if wasCancelled || timedOut || !stillOwned { return nil }
        return data
    }

    func cancel(kind: PresenceEngine.ManagedProbeKind, reason: String) async {
        guard let command = inFlightCommands.removeValue(forKey: kind) else { return }
        command.terminate()
    }

    func cancelAll(reason: String) async {
        let kinds = Array(inFlightCommands.keys)
        for kind in kinds {
            await cancel(kind: kind, reason: reason)
        }
    }

    private nonisolated static func readOutput(from handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close() }
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async -> WaitResult {
        await withCheckedContinuation { continuation in
            let state = WaitState(continuation)
            let timeoutItem = DispatchWorkItem {
                state.resumeIfNeeded(.timedOut)
            }

            process.terminationHandler = { _ in
                timeoutItem.cancel()
                state.resumeIfNeeded(.exited)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(timeout, 0),
                execute: timeoutItem
            )

            if !process.isRunning {
                timeoutItem.cancel()
                state.resumeIfNeeded(.exited)
            }
        }
    }
}
