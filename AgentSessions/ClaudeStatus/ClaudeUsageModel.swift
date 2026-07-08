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
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil
    @Published var dataIsStale: Bool = false
    @Published var unavailableMessage: String? = nil

    // Current source info for debug display
    @Published var currentSourceLabel: String = ""
    @Published var currentHealthLabel: String = ""
    @Published var lastRawOAuthPayload: String? = nil
    @Published var fiveHourProjectedRunoutAt: Date? = nil
    @Published var fiveHourProjectionObservedAt: Date? = nil
    /// Set while a measured burn projects run-out at/after reset ("on track,
    /// fits the 5h window"); drives the smile glyph in the Quota Meter row.
    @Published var fiveHourOnTrackObservedAt: Date? = nil

    private var sourceManager: ClaudeUsageSourceManager?
    // Kept for hard-probe diagnostics that need direct tmux access
    private var service: ClaudeStatusService?
    private let limitNotifier = UsageLimitNotifier.shared
    private var fiveHourProjectionTracker = UsageLimitProjectionTracker()
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false
    private var cockpitVisible: Bool = false
    private var cockpitPinned: Bool = false
    // Avoid touching NSApp during singleton initialization at app launch.
    // NSApp is an IUO and can be nil this early in startup.
    private var appIsActive: Bool = false
    private var wakeObservers: [NSObjectProtocol] = []

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
    func applyAvailability(_ availability: ClaudeServiceAvailability) {
        cliUnavailable = availability.cliUnavailable
        tmuxUnavailable = availability.tmuxUnavailable
        loginRequired = availability.loginRequired
        setupRequired = availability.setupRequired
        setupHint = availability.setupHint
        if let state = availability.authState {
            let newStatus = UsageAuthStatus.make(provider: .claude, state: state)
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
        let model = self
        let snapshotHandler: @Sendable (ClaudeLimitSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates (can happen when the menu bar
                // or strip visibility flips and the service immediately delivers a snapshot).
                await Task.yield()
                model.applyLimitSnapshot(snapshot)
            }
        }
        let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void = { availability in
            Task { @MainActor in
                // Avoid publishing changes during SwiftUI view updates.
                await Task.yield()
                model.applyAvailability(availability)
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
        recordProjectionDiagnostics(fiveHourProjectionTracker.lastDiagnostics, estimate: nil)
        removeWakeObservers()
    }

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
    }

    private func removeWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in wakeObservers {
            nc.removeObserver(token)
        }
        wakeObservers.removeAll()
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
    func hardProbeNowDiagnostics(completion: @escaping (ClaudeProbeDiagnostics) -> Void) {
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
            return
        }
        // I4: the hard probe uses the tmux `/usage` path, which hangs on a login /
        // re-auth / setup screen. If the current auth verdict is alarming (signed out /
        // expired / CLI not installed), short-circuit with a no-op diagnostics instead
        // of spawning the hanging probe. `forceProbeNow()` itself has no auth gate
        // (unlike Codex's), so the gate must live here, before the service is built.
        if let state = authStatus?.state, state.isAlarming {
            completion(Self.suppressedHardProbeDiagnostics())
            return
        }
        if isUpdating { return }
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
        sessionRemainingPercent = clampPercent(s.fiveHourRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weeklyRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)

        // Reset texts: store raw string so UsageResetText can parse at display time
        sessionResetText = s.fiveHourResetText
        weekAllModelsResetText = s.weeklyResetText
        weekOpusResetText = s.weekOpusResetText

        lastUpdate = s.fetchedAt
        unavailableMessage = nil
        currentSourceLabel = s.source.description
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
        sessionRemainingPercent = clampPercent(s.sessionRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weekAllModelsRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)
        sessionResetText = s.sessionResetText
        weekAllModelsResetText = s.weekAllModelsResetText
        weekOpusResetText = s.weekOpusResetText
        lastUpdate = now
        unavailableMessage = nil
        dataIsStale = false
        updateFiveHourProjection(
            remainingPercent: s.sessionRemainingPercent,
            remainingPercentExact: nil,
            resetText: s.sessionResetText,
            freshness: .fresh,
            observedAt: now,
            now: now
        )
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
        recordProjectionDiagnostics(diagnostics, estimate: nil)
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
}
