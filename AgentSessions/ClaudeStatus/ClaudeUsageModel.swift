import Foundation
import SwiftUI
import AppKit
#if os(macOS)
import IOKit.ps
#endif

// Snapshot of parsed values from Claude CLI /usage (kept for tmux path compatibility)
struct ClaudeUsageSnapshot: Equatable {
    var sessionRemainingPercent: Int = 0
    var sessionResetText: String = ""
    var weekAllModelsRemainingPercent: Int = 0
    var weekAllModelsResetText: String = ""
    var weekOpusRemainingPercent: Int? = nil
    var weekOpusResetText: String? = nil
    /// Model the scoped weekly window covers ("Fable"). nil when it came from the legacy
    /// `seven_day_opus` key, or when no scoped window is reported.
    var weekScopedLabel: String? = nil

    // MARK: - Helper Methods for UI Display
    // Server now reports "remaining" but UI may want to show "used" (e.g., progress bars)

    func sessionPercentUsed() -> Int {
        return 100 - sessionRemainingPercent
    }

    func weekAllModelsPercentUsed() -> Int {
        return 100 - weekAllModelsRemainingPercent
    }

    func weekOpusPercentUsed() -> Int? {
        guard let remaining = weekOpusRemainingPercent else { return nil }
        return 100 - remaining
    }
}

@MainActor
final class ClaudeUsageModel: ObservableObject {
    static let shared = ClaudeUsageModel()
    /// Task 10: shared one-shot signed-out notifier (see `AuthStatusNotifier.swift`).
    static let authNotifier = AuthStatusNotifier.shared

    @Published var sessionRemainingPercent: Int = 0
    @Published var sessionResetText: String = ""
    @Published var weekAllModelsRemainingPercent: Int = 0
    @Published var weekAllModelsResetText: String = ""
    @Published var weekOpusRemainingPercent: Int? = nil
    @Published var weekOpusResetText: String? = nil
    @Published var weekScopedLabel: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var cliUnavailable: Bool = false
    @Published var tmuxUnavailable: Bool = false
    @Published var loginRequired: Bool = false
    @Published var setupRequired: Bool = false
    @Published var setupHint: String? = nil
    // Task 9b auth-verdict surface, fed by ClaudeAuthClassifier via the
    // availability handler. `authStatus` carries the headline/remediation; views
    // read `authStatus?.state.isAlarming` directly to decide whether to show the
    // banner (signed out / expired / no CLI).
    @Published var authStatus: UsageAuthStatus?
    /// Calm caption for a transient (non-alarming) usage failure — network/5xx/429.
    /// `nil` when healthy. Distinct from `authStatus` (the alarming banner). (P2)
    @Published var transientReason: String?
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil
    @Published var dataIsStale: Bool = false
    @Published var unavailableMessage: String? = nil

    // Current source info for debug display
    @Published var currentSourceLabel: String = ""
    /// Current usage data source, for honest UI labeling (P4): when `.tmuxUsage`
    /// the strip/menu/Cockpit show a "via CLI probe" note distinguishing fallback
    /// data from the OAuth endpoint.
    @Published var currentSource: ClaudeUsageSource?
    @Published var currentHealthLabel: String = ""
    @Published var lastRawOAuthPayload: String? = nil
    @Published var fiveHourProjectedRunoutAt: Date? = nil
    @Published var fiveHourProjectionObservedAt: Date? = nil
    /// Set while a measured burn projects run-out at/after reset ("on track,
    /// fits the 5h window"); drives the smile glyph in the Quota Meter row.
    @Published var fiveHourOnTrackObservedAt: Date? = nil
    /// Recent same-reset weekly quota tick used by Session Runway.
    @Published var weeklyBurnRateEstimate: UsageLimitBurnRateEstimate? = nil

    private var sourceManager: ClaudeUsageSourceManager?
    /// Invalidates callbacks already queued by a stopped source manager. The
    /// callbacks deliberately yield before touching published state, so manager
    /// identity must survive that suspension explicitly.
    private var sourceManagerGeneration: UInt64 = 0
    // Kept for hard-probe diagnostics that need direct tmux access
    private var service: ClaudeStatusService?
    private let limitNotifier = UsageLimitNotifier.shared
    private var fiveHourProjectionTracker = UsageLimitProjectionTracker()
    private var weeklyBurnRateTracker = UsageLimitBurnRateTracker()
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false
    private var cockpitVisible: Bool = false
    private var cockpitPinned: Bool = false
    // Avoid touching NSApp during singleton initialization at app launch.
    // NSApp is an IUO and can be nil this early in startup.
    private var appIsActive: Bool = false
    private var wakeObservers: [NSObjectProtocol] = []
    /// Observer for an explicit refresh request (e.g. the no-CLI banner enabling
    /// Web API mode) — on NotificationCenter.default, removed separately. (P4)
    private var refreshRequestObserver: NSObjectProtocol?

#if DEBUG
    static var projectionDiagnosticsDefaultsForTesting: UserDefaults?
#endif

    private static var projectionDiagnosticsDefaults: UserDefaults {
#if DEBUG
        if let projectionDiagnosticsDefaultsForTesting {
            return projectionDiagnosticsDefaultsForTesting
        }
#endif
        return .standard
    }

    func setEnabled(_ enabled: Bool) {
        if AppRuntime.isRunningTests {
            if !enabled { stop() }
            return
        }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setVisible(_ visible: Bool) {
        // Back-compat shim: treat as strip visibility
        setStripVisible(visible)
    }

    func setStripVisible(_ visible: Bool) {
        stripVisible = visible
        propagateVisibility()
    }

    func setMenuVisible(_ visible: Bool) {
        menuVisible = visible
        propagateVisibility()
    }

    func setAppActive(_ active: Bool) {
        guard !AppRuntime.isRunningTests else { return }
        appIsActive = active
        propagateVisibility()
    }

    /// Called by the cockpit HUD window. When `pinned`, the cockpit is always on top
    /// and should poll even when the app loses focus (treated like menu bar visibility).
    func setCockpitVisible(_ visible: Bool, pinned: Bool) {
        cockpitVisible = visible
        cockpitPinned = visible && pinned
        propagateVisibility()
    }

    private func propagateVisibility() {
        // Treat the in-app strip as non-visible while the app is inactive to avoid
        // background polling. Menu bar visibility should remain effective even when
        // the app is inactive so the user can still read live usage in the menu bar.
        // A pinned cockpit window is treated like the menu bar (always-on polls).
        let mgr = self.sourceManager
        let menuVisible = self.menuVisible || self.cockpitPinned
        let stripVisible = self.stripVisible || self.cockpitVisible
        let appIsActive = self.appIsActive
        Task.detached {
            await mgr?.setVisibility(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        }
    }

    func refreshNow() {
        guard !AppRuntime.isRunningTests else { return }
        guard isEnabled else { return }
        if isUpdating { return }
        isUpdating = true
        let mgr = self.sourceManager
        Task.detached {
            await mgr?.refreshNow()
            try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
            await MainActor.run {
                if ClaudeUsageModel.shared.isUpdating { ClaudeUsageModel.shared.isUpdating = false }
            }
        }
    }

    private func usageMode() -> ClaudeUsageMode {
        let raw = UserDefaults.standard.string(forKey: PreferencesKey.claudeUsageMode) ?? ClaudeUsageMode.auto.rawValue
        return ClaudeUsageMode(rawValue: raw) ?? .auto
    }

    /// Applies a service-availability update to the published surfaces. Extracted
    /// from the availability handler closure so the Task 9b auth-verdict mapping
    /// is unit-testable without a subprocess/network. The auth fields are only
    /// written when the emit actually carries a verdict, so legacy tmux/probe
    /// emits (authState == nil) don't disturb the banner.
#if DEBUG
    /// Test/debug seam: forces the CLI-presence result used to pick the remediation
    /// rung, so the no-CLI ladder can be exercised deterministically (the real disk
    /// check returns true on any machine with the CLI installed). `nil` = real check.
    static var cliPresenceOverrideForTesting: Bool?
#endif

    #if DEBUG
    /// Test seam: the public setEnabled() deliberately no-ops under tests so
    /// suites never spawn services; entry-point contract tests still need to
    /// exercise the enabled guard ordering. Sets the flag only — no start().
    func setEnabledForTesting(_ enabled: Bool) { isEnabled = enabled }
    #endif

    /// Deterministic Claude-CLI presence used to choose the remediation rung. Same
    /// disk check `classifyAndPublishAuthState` uses; overridable in DEBUG for tests.
    private func resolveClaudeCLIPresent() -> Bool {
        #if DEBUG
        if let forced = Self.cliPresenceOverrideForTesting { return forced }
        #endif
        return CLIBinaryPresence.claudeInstalled(
            overridePath: UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath))
    }

    func applyAvailability(_ availability: ClaudeServiceAvailability) {
        // A nil transient reason means "this availability producer has no
        // opinion", not "clear another producer's active failure". OAuth, Web,
        // and tmux all share this channel; treating every legacy nil as a global
        // clear let fallback startup erase an OAuth 429 before Quota Meter drew
        // it. Recovery must be explicit, or arrive as a live usage snapshot.
        if let reason = availability.transientReason {
            if transientReason != reason { transientReason = reason }
        } else if availability.clearsTransientReason, transientReason != nil {
            transientReason = nil
        }
        // A caption-only emit (a transient blip: 429 / pre-escalation) carries no
        // meaningful legacy bools or authState — leave the orthogonal setup/CLI/login
        // state and the banner exactly as they are.
        if availability.captionOnly { return }
        cliUnavailable = availability.cliUnavailable
        tmuxUnavailable = availability.tmuxUnavailable
        loginRequired = availability.loginRequired
        setupRequired = availability.setupRequired
        setupHint = availability.setupHint
        if let state = availability.authState {
            // Pick the remediation rung by CLI presence: a Desktop-only user with
            // no CLI gets the Web-API/guided-install ladder instead of a copy
            // command they can't run.
            let cliPresent = resolveClaudeCLIPresent()
            let newStatus = UsageAuthStatus.make(provider: .claude, state: state, cliPresent: cliPresent)
            // F7: only assign the @Published verdict when it actually changed, so a
            // steady auth state doesn't fire objectWillChange on every 60s poll.
            if authStatus != newStatus { authStatus = newStatus }
            // The notifier is called every poll (not gated by the change check): its
            // own episode store dedups, and it must keep being invoked while an
            // alarming episode persists so a notification permission granted
            // mid-episode still fires.
            if !AppRuntime.isRunningTests {
                Task { await Self.authNotifier.onStatus(newStatus, provider: .claude) }
            }
        }
    }

    private func start() {
        guard !AppRuntime.isRunningTests else { return }
        sourceManagerGeneration &+= 1
        let generation = sourceManagerGeneration
        let model = self
        let snapshotHandler: @Sendable (ClaudeLimitSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates (can happen when the menu bar
                // or strip visibility flips and the service immediately delivers a snapshot).
                await Task.yield()
                guard model.sourceManagerGeneration == generation else { return }
                model.applyLimitSnapshot(snapshot)
            }
        }
        let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates.
                await Task.yield()
                model.applyAvailability(availability, sourceManagerGeneration: generation)
            }
        }

        let mode = usageMode()
        let mgr = ClaudeUsageSourceManager()
        self.sourceManager = mgr

        installWakeObservers()
        Task.detached {
            await mgr.start(mode: mode, handler: snapshotHandler, availabilityHandler: availabilityHandler)
        }
        propagateVisibility()
    }

    private func stop() {
        sourceManagerGeneration &+= 1
        let mgr = sourceManager
        Task.detached {
            await mgr?.stop()
        }
        sourceManager = nil
        service = nil
        fiveHourProjectionTracker.reset()
        fiveHourProjectedRunoutAt = nil
        fiveHourProjectionObservedAt = nil
        fiveHourOnTrackObservedAt = nil
        weeklyBurnRateTracker.reset()
        weeklyBurnRateEstimate = nil
        // A replacement source manager starts with no knowledge of the previous
        // manager's auth episode. Do not let an old alarming verdict mask a new
        // transient response (notably a 429) after tracking is re-enabled.
        authStatus = nil
        transientReason = nil
        cliUnavailable = false
        tmuxUnavailable = false
        loginRequired = false
        setupRequired = false
        setupHint = nil
        recordProjectionDiagnostics(fiveHourProjectionTracker.lastDiagnostics, estimate: nil)
        removeWakeObservers()
    }

    /// Applies manager output only while it belongs to the currently active
    /// manager generation. Internal for deterministic lifecycle regression tests.
    func applyAvailability(_ availability: ClaudeServiceAvailability,
                           sourceManagerGeneration generation: UInt64) {
        guard generation == sourceManagerGeneration else { return }
        applyAvailability(availability)
    }

#if DEBUG
    var sourceManagerGenerationForTesting: UInt64 { sourceManagerGeneration }
#endif

    private func installWakeObservers() {
        guard wakeObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        wakeObservers.append(
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWake()
                }
            }
        )
        wakeObservers.append(
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWake()
                }
            }
        )
        // Explicit refresh request: the no-CLI banner's "Enable Web API mode" flips
        // the pref then posts this so runway returns promptly instead of waiting for
        // the next poll (P4 finding-1 fix). Registered on NotificationCenter.default.
        if refreshRequestObserver == nil {
            refreshRequestObserver = NotificationCenter.default.addObserver(
                forName: .claudeUsageRefreshRequested, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNow() }
            }
        }
    }

    private func removeWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in wakeObservers {
            nc.removeObserver(token)
        }
        wakeObservers.removeAll()
        if let obs = refreshRequestObserver {
            NotificationCenter.default.removeObserver(obs)
            refreshRequestObserver = nil
        }
    }

    private func handleWake() {
        guard !AppRuntime.isRunningTests else { return }
        guard isEnabled else { return }
        guard Self.shouldRefreshOnWake(
            isRunningTests: AppRuntime.isRunningTests,
            isEnabled: isEnabled,
            stripVisible: stripVisible,
            menuVisible: menuVisible,
            cockpitVisible: cockpitVisible,
            cockpitPinned: cockpitPinned,
            appIsActive: appIsActive,
            claudeUsageEnabled: UserDefaults.standard.bool(forKey: PreferencesKey.claudeUsageEnabled),
            onACPower: Self.onACPower()
        ) else { return }
        refreshNow()
    }

    private static func shouldRefreshOnWake(isRunningTests: Bool,
                                            isEnabled: Bool,
                                            stripVisible: Bool,
                                            menuVisible: Bool,
                                            cockpitVisible: Bool,
                                            cockpitPinned: Bool,
                                            appIsActive: Bool,
                                            claudeUsageEnabled: Bool,
                                            onACPower: Bool) -> Bool {
        guard !isRunningTests else { return false }
        guard isEnabled else { return false }
        let effectiveVisible = menuVisible || cockpitPinned || ((stripVisible || cockpitVisible) && appIsActive)
        guard effectiveVisible else { return false }
        guard claudeUsageEnabled else { return false }
        guard onACPower else { return false }
        return true
    }

    private static func onACPower() -> Bool {
        #if os(macOS)
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() {
            let type = typeCF as String
            return type == (kIOPSACPowerValue as String)
        }
        #endif
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        }
        return true
    }

    // MARK: - Hard probe (tmux path, for diagnostics)

    /// Neutral no-op diagnostics returned when a hard probe is suppressed
    /// because auth is known-bad (signed out / expired / CLI missing).
    /// Shared by both the debounced-verdict guard and the authoritative
    /// pre-spawn CLI check so their short-circuit shape stays identical.
    private static func suppressedHardProbeDiagnostics() -> ClaudeProbeDiagnostics {
        ClaudeProbeDiagnostics(
            success: false,
            exitCode: 126,
            scriptPath: "(not run)",
            workdir: ClaudeProbeConfig.probeWorkingDirectory(),
            claudeBin: nil,
            tmuxBin: nil,
            timeoutSecs: nil,
            stdout: "",
            stderr: "Probe suppressed: signed out, session expired, or CLI not installed"
        )
    }

    // Hard-probe entry: run a one-off /usage probe and return diagnostics.
    // Bypasses the source manager to always use the tmux path for direct diagnostics.
    @discardableResult
    func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) -> Bool {
        if isUpdating { return false }
        guard isEnabled else {
            let diag = ClaudeProbeDiagnostics(
                success: false,
                exitCode: 125,
                scriptPath: "(not run)",
                workdir: ClaudeProbeConfig.probeWorkingDirectory(),
                claudeBin: nil,
                tmuxBin: nil,
                timeoutSecs: nil,
                stdout: "",
                stderr: "Claude usage tracking is disabled"
            )
            completion(diag)
            return true
        }
        // I4: the hard probe uses the tmux `/usage` path, which hangs on a login /
        // re-auth / setup screen. If the current auth verdict is alarming (signed out /
        // expired / CLI not installed), short-circuit with a no-op diagnostics instead
        // of spawning the hanging probe. `forceProbeNow()` itself has no auth gate
        // (unlike Codex's), so the gate must live here, before the service is built.
        if let state = authStatus?.state, state.isAlarming {
            completion(Self.suppressedHardProbeDiagnostics())
            return true
        }
        isUpdating = true
        Task { [weak self] in
            guard let self else { return }
            // I4: authoritative pre-spawn check. The debounced `authStatus` verdict
            // above can still be `.unknown`/nil during the signed-out cold-start
            // window (~60-120s before the debounce commits `.signedOut`), letting
            // the isAlarming guard pass through. Query the CLI directly here,
            // before building the service / spawning the tmux probe — it is
            // authoritative and never falsely reports `.signedOut` (any ambiguity,
            // timeout, or launch failure yields `.unknown`, which falls through to
            // the normal probe path).
            let cliStatus = await CLIAuthStatusProbe.probeClaudeAuthStatus()
            if cliStatus == .signedOut || cliStatus == .cliMissing {
                let diag = Self.suppressedHardProbeDiagnostics()
                await MainActor.run {
                    self.isUpdating = false
                    completion(diag)
                }
                return
            }
            // Create a short-lived service for the forced probe. Apply the returned
            // snapshot below so completion cannot race ahead of model publication.
            let handler: @Sendable (ClaudeUsageSnapshot) -> Void = { _ in }
            let availability: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
                Task { @MainActor in
                    await Task.yield()
                    self.cliUnavailable = availability.cliUnavailable
                    self.tmuxUnavailable = availability.tmuxUnavailable
                    self.loginRequired = availability.loginRequired
                    self.setupRequired = availability.setupRequired
                    self.setupHint = availability.setupHint
                }
            }
            let svc = ClaudeStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if let snapshot = diag.snapshot {
                    self.apply(snapshot)
                    self.persistHardProbeSnapshot(snapshot)
                }
                if diag.success, let unavailable = diag.unavailableMessage {
                    self.unavailableMessage = unavailable
                    self.dataIsStale = self.lastUpdate == nil ? true : self.dataIsStale
                    self.recordUnavailableProjectionDiagnostics(unavailable)
                } else if diag.success {
                    self.unavailableMessage = nil
                }
                if diag.success && diag.unavailableMessage == nil && diag.snapshot != nil {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .claude, until: Date().addingTimeInterval(UsageFreshnessTTL.probeFreshness))
                }
                self.isUpdating = false
                completion(diag)
            }
        }
        return true
    }

    /// Convert a tmux snapshot and persist it for cold-start restore.
    /// Accepts the snapshot directly to avoid ordering dependency on model state.
    private func persistHardProbeSnapshot(_ s: ClaudeUsageSnapshot) {
        let snapshot = ClaudeLimitSnapshot(
            fetchedAt: Date(),
            source: .tmuxUsage,
            health: .live,
            fiveHourUsedRatio: Double(100 - max(0, min(100, s.sessionRemainingPercent))) / 100.0,
            fiveHourResetText: s.sessionResetText,
            weeklyUsedRatio: Double(100 - max(0, min(100, s.weekAllModelsRemainingPercent))) / 100.0,
            weeklyResetText: s.weekAllModelsResetText,
            weekOpusUsedRatio: s.weekOpusRemainingPercent.map { Double(100 - max(0, min(100, $0))) / 100.0 },
            weekOpusResetText: s.weekOpusResetText,
            weekScopedLabel: s.weekScopedLabel,
            rawPayloadHash: nil
        )
        let mgr = self.sourceManager
        Task.detached {
            await mgr?.saveSnapshot(snapshot)
        }
    }

    // MARK: - Snapshot application

    func fetchRawOAuthPayload() {
        let mgr = sourceManager
        Task.detached { [weak self] in
            let payload = await mgr?.lastRawOAuthPayload
            guard let self else { return }
            await MainActor.run { self.lastRawOAuthPayload = payload }
        }
    }

    /// Apply a normalized ClaudeLimitSnapshot from the source manager.
    private func applyLimitSnapshot(_ s: ClaudeLimitSnapshot) {
        let now = Date()
        let freshness = Self.alertFreshness(for: s, now: now)
        // A serving source is authoritative recovery. Failed fallback
        // availability alone is not; it must not clear an OAuth rate-limit
        // episode until a usable snapshot actually arrives.
        if s.health == .live, transientReason != nil { transientReason = nil }
        prepareWeeklyBurnRateTracker(for: s.source)
        sessionRemainingPercent = clampPercent(s.fiveHourRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weeklyRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)

        // Reset texts: store raw string so UsageResetText can parse at display time
        sessionResetText = s.fiveHourResetText
        weekAllModelsResetText = s.weeklyResetText
        weekOpusResetText = s.weekOpusResetText
        weekScopedLabel = s.weekScopedLabel

        lastUpdate = s.fetchedAt
        // Mark that we have real data so `isInitialLoading` (isUpdating && lastSuccessAt == nil)
        // stops blanking the meters to a spinner on OAuth-only setups — previously
        // only the tmux hard probe ever set this, so it stayed nil forever here.
        lastSuccessAt = s.fetchedAt
        unavailableMessage = nil
        currentSourceLabel = s.source.description
        currentSource = s.source
        currentHealthLabel = s.health.description
        dataIsStale = (s.health == .stale || s.health == .degraded)
        updateFiveHourProjection(
            remainingPercent: s.fiveHourRemainingPercent,
            remainingPercentExact: s.fiveHourUsedRatio.map { 100 - ($0 * 100) },
            resetText: s.fiveHourResetText,
            freshness: freshness,
            observedAt: s.fetchedAt,
            now: now
        )
        weeklyBurnRateEstimate = weeklyBurnRateTracker.update(with: UsageLimitProjectionSample(
            source: .claude,
            remainingPercent: s.weeklyRemainingPercent,
            remainingPercentExact: s.weeklyUsedRatio.map { 100 - ($0 * 100) },
            resetText: s.weeklyResetText,
            hasRateLimit: !s.weeklyResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            freshness: freshness,
            observedAt: s.fetchedAt
        ), now: now)
        // Weekly %/h calibration — see the Codex counterpart. Claude's weekly
        // percent is integer-quantized exactly like Codex's: the OAuth payload
        // returns `utilization` as 27.0 / 11.0 and `limits[].percent` as a literal
        // JSON integer. `weeklyUsedRatio` is a Double only because the normalizer
        // divides by 100 — it does NOT imply sub-point resolution, so this reports
        // itself as inexact and takes the 1pp acceptance floor.
        if let weeklyRatio = s.weeklyUsedRatio,
           freshness.allowsProjectedDisplay,
           // Anchor, not display: the weekly reset identifies the window for both
           // the bootstrap cache key and the tracker's interval matching. The tmux
           // fallback supplies a relative countdown, which resolves against `now`
           // and so names a new window every poll — it wrote seven bogus cache keys
           // in 75 minutes before this guard existed.
           // Only a source that states which quota week this is. The tmux path
           // supplies a countdown, already formatted into a localized date before
           // this snapshot exists — see `weeklyResetAnchorText`.
           let weeklyResetAnchorText = s.weeklyResetAnchorText,
           let weekResetAt = UsageResetText.resetAnchorDate(kind: "Wk",
                                                            source: .claude,
                                                            raw: weeklyResetAnchorText,
                                                            now: s.fetchedAt),
           weekResetAt > s.fetchedAt {
            // Historical bootstrap, same as Codex: without this the Claude rows
            // wait out the 60s budget and fall to "n/a" permanently, because a
            // weekly tick is far too rare to be a first reading.
            WeeklyQuotaCalibrationStore.shared.ensureBootstrap(
                provider: "claude",
                root: ClaudeWeeklyQuotaBootstrapScanner.defaultProjectsRoot,
                resetsAt: weekResetAt,
                windowMinutes: 10080,
                usedPercentPoints: weeklyRatio * 100,
                limitShape: s.weekOpusUsedRatio != nil ? "weekly+scoped" : "weekly",
                now: now
            )
            WeeklyQuotaCalibrationStore.shared.observeQuota(
                provider: "claude",
                remainingPercent: 100 - (weeklyRatio * 100),
                // Integer-quantized, per the payload above. Claiming exactness here
                // lowered the acceptance floor to 0.25pp on a source whose real
                // quantum is a full point.
                hasExactPercent: false,
                resetAt: weekResetAt,
                observedAt: s.fetchedAt,
                scope: WeeklyQuotaCalibrationScope(
                    provider: "claude",
                    // Claude's normalized snapshot carries no account or org id, so
                    // this stays nil: the calibration is memory-only and cannot
                    // survive a possible account switch across restarts.
                    accountHash: nil,
                    sourceFamily: "\(s.source)",
                    limitShape: s.weekOpusUsedRatio != nil ? "weekly+scoped" : "weekly",
                    priceRevision: RunwayPriceTable.shared.revision
                ),
                now: now
            )
        }
        limitNotifier.handle(snapshot: usageLimitSnapshot(
            fiveHourRemainingPercent: s.fiveHourRemainingPercent,
            fiveHourRemainingPercentExact: s.fiveHourUsedRatio.map { 100 - ($0 * 100) },
            fiveHourResetText: s.fiveHourResetText,
            weeklyRemainingPercent: s.weeklyRemainingPercent,
            weeklyRemainingPercentExact: s.weeklyUsedRatio.map { 100 - ($0 * 100) },
            weeklyResetText: s.weeklyResetText,
            freshness: freshness,
            observedAt: s.fetchedAt,
            sourceDescription: s.source.description
        ))
        if isUpdating { isUpdating = false }
        if s.source == .oauthEndpoint { fetchRawOAuthPayload() }
    }

#if DEBUG
    static func shouldRefreshOnWakeForTesting(isRunningTests: Bool,
                                              isEnabled: Bool,
                                              stripVisible: Bool,
                                              menuVisible: Bool,
                                              cockpitVisible: Bool,
                                              cockpitPinned: Bool,
                                              appIsActive: Bool,
                                              claudeUsageEnabled: Bool,
                                              onACPower: Bool) -> Bool {
        shouldRefreshOnWake(
            isRunningTests: isRunningTests,
            isEnabled: isEnabled,
            stripVisible: stripVisible,
            menuVisible: menuVisible,
            cockpitVisible: cockpitVisible,
            cockpitPinned: cockpitPinned,
            appIsActive: appIsActive,
            claudeUsageEnabled: claudeUsageEnabled,
            onACPower: onACPower
        )
    }

    func applyLimitSnapshotForTesting(_ snapshot: ClaudeLimitSnapshot) {
        applyLimitSnapshot(snapshot)
    }
#endif

    /// Apply a ClaudeUsageSnapshot from the legacy tmux path (used for hard-probe results).
    private func apply(_ s: ClaudeUsageSnapshot) {
        let now = Date()
        if transientReason != nil { transientReason = nil }
        prepareWeeklyBurnRateTracker(for: .tmuxUsage)
        sessionRemainingPercent = clampPercent(s.sessionRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weekAllModelsRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)
        sessionResetText = s.sessionResetText
        weekAllModelsResetText = s.weekAllModelsResetText
        weekOpusResetText = s.weekOpusResetText
        weekScopedLabel = s.weekScopedLabel
        lastUpdate = now
        unavailableMessage = nil
        dataIsStale = false
        currentSource = .tmuxUsage   // hard probe is always the CLI /usage path
        updateFiveHourProjection(
            remainingPercent: s.sessionRemainingPercent,
            remainingPercentExact: nil,
            resetText: s.sessionResetText,
            freshness: .fresh,
            observedAt: now,
            now: now
        )
        weeklyBurnRateEstimate = weeklyBurnRateTracker.update(with: UsageLimitProjectionSample(
            source: .claude,
            remainingPercent: s.weekAllModelsRemainingPercent,
            resetText: s.weekAllModelsResetText,
            hasRateLimit: !s.weekAllModelsResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            freshness: .fresh,
            observedAt: now
        ), now: now)
        limitNotifier.handle(snapshot: usageLimitSnapshot(
            fiveHourRemainingPercent: s.sessionRemainingPercent,
            fiveHourRemainingPercentExact: nil,
            fiveHourResetText: s.sessionResetText,
            weeklyRemainingPercent: s.weekAllModelsRemainingPercent,
            weeklyRemainingPercentExact: nil,
            weeklyResetText: s.weekAllModelsResetText,
            freshness: .fresh,
            observedAt: lastUpdate,
            sourceDescription: ClaudeUsageSource.tmuxUsage.description
        ))
        if isUpdating { isUpdating = false }
    }

    private func recordUnavailableProjectionDiagnostics(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostics = trimmed.isEmpty ? "Claude usage unavailable" : trimmed
        fiveHourProjectedRunoutAt = nil
        fiveHourProjectionObservedAt = nil
        fiveHourOnTrackObservedAt = nil
        weeklyBurnRateTracker.reset()
        weeklyBurnRateEstimate = nil
        recordProjectionDiagnostics(diagnostics, estimate: nil)
    }

    /// Different Claude sources can disagree by a fraction because OAuth/Web
    /// expose exact ratios while the CLI probe is integer-rounded. Never turn a
    /// source transition into an apparent quota tick. Runs before the caller
    /// overwrites `currentSource`, so that field still holds the previous
    /// poll's source here.
    private func prepareWeeklyBurnRateTracker(for source: ClaudeUsageSource) {
        guard currentSource != source else { return }
        weeklyBurnRateTracker.reset()
        weeklyBurnRateEstimate = nil
    }

    private func updateFiveHourProjection(remainingPercent: Int,
                                          remainingPercentExact: Double?,
                                          resetText: String,
                                          freshness: UsageLimitAlertFreshness,
                                          observedAt: Date,
                                          now: Date) {
        let hasFiveHour = !resetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let projectionEstimate = fiveHourProjectionTracker.update(with: UsageLimitProjectionSample(
            source: .claude,
            remainingPercent: remainingPercent,
            remainingPercentExact: remainingPercentExact,
            resetText: resetText,
            hasRateLimit: hasFiveHour,
            freshness: freshness,
            observedAt: observedAt
        ), now: now)
        fiveHourProjectedRunoutAt = projectionEstimate?.runoutAt
        fiveHourProjectionObservedAt = projectionEstimate?.observedAt
        fiveHourOnTrackObservedAt = fiveHourProjectionTracker.lastOnTrackObservedAt
        recordProjectionDiagnostics(fiveHourProjectionTracker.lastDiagnostics, estimate: projectionEstimate)
    }

    private func recordProjectionDiagnostics(_ value: String, estimate: UsageLimitProjectionEstimate?) {
        let defaults = Self.projectionDiagnosticsDefaults
        defaults.set(value, forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjection)
        defaults.set(
            estimate?.runoutAt.timeIntervalSince1970 ?? 0,
            forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjectionRunoutAt
        )
        defaults.set(
            estimate?.observedAt.timeIntervalSince1970 ?? 0,
            forKey: PreferencesKey.usageLimitDiagnosticsClaudeProjectionObservedAt
        )
    }

    private func usageLimitSnapshot(fiveHourRemainingPercent: Int,
                                    fiveHourRemainingPercentExact: Double?,
                                    fiveHourResetText: String,
                                    weeklyRemainingPercent: Int,
                                    weeklyRemainingPercentExact: Double?,
                                    weeklyResetText: String,
                                    freshness: UsageLimitAlertFreshness,
                                    observedAt: Date?,
                                    sourceDescription: String?) -> UsageLimitSnapshot {
        let hasFiveHour = !fiveHourResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWeekly = !weeklyResetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return UsageLimitSnapshot(
            provider: .claude,
            fiveHourRemainingPercent: fiveHourRemainingPercent,
            fiveHourRemainingPercentExact: fiveHourRemainingPercentExact,
            fiveHourResetText: fiveHourResetText,
            hasFiveHourRateLimit: hasFiveHour,
            weeklyRemainingPercent: weeklyRemainingPercent,
            weeklyRemainingPercentExact: weeklyRemainingPercentExact,
            weeklyResetText: weeklyResetText,
            hasWeeklyRateLimit: hasWeekly,
            freshness: freshness,
            observedAt: observedAt,
            sourceDescription: sourceDescription
        )
    }

    private static func alertFreshness(for snapshot: ClaudeLimitSnapshot, now: Date = Date()) -> UsageLimitAlertFreshness {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        switch (snapshot.source, snapshot.health) {
        case (.oauthEndpoint, .live), (.webEndpoint, .live), (.tmuxUsage, .live):
            return age <= 3 * 60 ? .fresh : .stale
        case (.cachedOAuth, _), (.cachedWeb, _), (_, .degraded):
            return age <= 10 * 60 ? .recentCached : .stale
        default:
            return .stale
        }
    }

}

extension Notification.Name {
    /// Posted to ask the Claude usage model to re-fetch immediately (e.g. after the
    /// no-CLI banner enables Web API mode, so runway returns without waiting for the
    /// next poll). (P4)
    static let claudeUsageRefreshRequested = Notification.Name("ClaudeUsageRefreshRequested")
}

struct ClaudeServiceAvailability {
    var cliUnavailable: Bool
    var tmuxUnavailable: Bool
    var loginRequired: Bool = false
    var setupRequired: Bool = false
    var setupHint: String? = nil
    /// Full auth verdict (Task 9b). Carries states the legacy bools can't
    /// express (notably `.expired`); `nil` means "no auth update in this emit"
    /// so existing constructions and callers that don't classify stay valid.
    var authState: UsageAuthState? = nil
    /// Calm, non-alarming caption for transient failures (network / 5xx / 429).
    /// The strip shows it in `.secondary` without raising the banner. `nil`
    /// means no update; recovery uses `clearsTransientReason` or a live snapshot.
    /// (P2, spec §3/§4.)
    var transientReason: String? = nil
    /// Explicit permission to clear a prior transient cause. The default is
    /// deliberately false because legacy dependency/fallback availability with
    /// no reason is "unchanged", not proof that usage recovered.
    var clearsTransientReason: Bool = false
    /// This emit carries ONLY the transient caption — `applyAvailability` updates
    /// `transientReason` and leaves the orthogonal legacy bools (setup/CLI/login)
    /// and the banner untouched, so a rate-limit/transient blip can't clobber an
    /// unrelated state. Set by the pure-caption emits (429 + pre-escalation).
    var captionOnly: Bool = false
}
