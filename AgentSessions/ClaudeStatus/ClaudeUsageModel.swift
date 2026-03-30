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
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil
    @Published var dataIsStale: Bool = false

    // Current source info for debug display
    @Published var currentSourceLabel: String = ""
    @Published var currentHealthLabel: String = ""
    @Published var lastRawOAuthPayload: String? = nil

    private var sourceManager: ClaudeUsageSourceManager?
    // Kept for hard-probe diagnostics that need direct tmux access
    private var service: ClaudeStatusService?
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false
    private var cockpitVisible: Bool = false
    private var cockpitPinned: Bool = false
    // Avoid touching NSApp during singleton initialization at app launch.
    // NSApp is an IUO and can be nil this early in startup.
    private var appIsActive: Bool = false
    private var wakeObservers: [NSObjectProtocol] = []

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
                model.cliUnavailable = availability.cliUnavailable
                model.tmuxUnavailable = availability.tmuxUnavailable
                model.loginRequired = availability.loginRequired
                model.setupRequired = availability.setupRequired
                model.setupHint = availability.setupHint
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
        guard stripVisible || menuVisible else { return }
        if UserDefaults.standard.bool(forKey: PreferencesKey.claudeUsageEnabled) == false { return }
        guard Self.onACPower() else { return }
        refreshNow()
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
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self else { return }
            // Create a short-lived service for the forced probe
            let handler: @Sendable (ClaudeUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in
                    await Task.yield()
                    self.apply(snapshot)
                    // Persist immediately — the snapshot is right here, no ordering dependency
                    self.persistHardProbeSnapshot(snapshot)
                }
            }
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
                if diag.success {
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
        sessionRemainingPercent = clampPercent(s.fiveHourRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weeklyRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)

        // Reset texts: store raw string so UsageResetText can parse at display time
        sessionResetText = s.fiveHourResetText
        weekAllModelsResetText = s.weeklyResetText
        weekOpusResetText = s.weekOpusResetText

        lastUpdate = Date()
        currentSourceLabel = s.source.description
        currentHealthLabel = s.health.description
        dataIsStale = (s.health == .stale || s.health == .degraded)
        if isUpdating { isUpdating = false }
        if s.source == .oauthEndpoint { fetchRawOAuthPayload() }
    }

    /// Apply a ClaudeUsageSnapshot from the legacy tmux path (used for hard-probe results).
    private func apply(_ s: ClaudeUsageSnapshot) {
        sessionRemainingPercent = clampPercent(s.sessionRemainingPercent)
        weekAllModelsRemainingPercent = clampPercent(s.weekAllModelsRemainingPercent)
        weekOpusRemainingPercent = s.weekOpusRemainingPercent.map(clampPercent)
        sessionResetText = s.sessionResetText
        weekAllModelsResetText = s.weekAllModelsResetText
        weekOpusResetText = s.weekOpusResetText
        lastUpdate = Date()
        dataIsStale = false
        if isUpdating { isUpdating = false }
    }

}

struct ClaudeServiceAvailability {
    var cliUnavailable: Bool
    var tmuxUnavailable: Bool
    var loginRequired: Bool = false
    var setupRequired: Bool = false
    var setupHint: String? = nil
}
