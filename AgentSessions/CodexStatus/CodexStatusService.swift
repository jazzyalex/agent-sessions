import Foundation
import Darwin
import SwiftUI
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Codex Usage Tracking Architecture Documentation
//
// This service implements a three-tier system for tracking Codex API rate limit usage:
//
// ## Data Sources (Priority Order)
//
// 1. **PRIMARY: JSONL Log Parsing** (Passive, Free)
//    - Scans ~/.codex/sessions/YYYY/MM/DD/*.jsonl files for rate_limit events
//    - Extracts 5-hour and weekly limit percentages from log events
//    - Zero token cost (reads existing logs, no API calls)
//    - Frequency: Every 5 minutes (reduced on battery)
//    - Limitation: Only reflects usage from recent local Codex sessions
//
// 2. **SECONDARY: Auto /status Probe** (Active, 1-2 messages)
//    - Triggers when: no recent sessions OR data looks stale AND visible AND user opted-in
//    - Uses tmux to run `codex` CLI and send `/status` command
//    - Token cost: 1-2 messages
//    - Gated by: `CodexAllowStatusProbe` preference + 10min cooldown
//    - Purpose: Fetch current usage when user hasn't used Codex recently
//
// 3. **TERTIARY: Hard Probe (Manual)** (Active, 1-2 messages)
//    - User-triggered via Preferences → Usage Probes → "Run hard Codex /status probe now"
//    - Always available regardless of staleness or auto-probe settings
//    - Returns full diagnostics (success/failure, script output, etc.)
//    - Sets 1-hour "freshness" TTL to prevent immediate re-staleness
//
// ## Current Data Model
//
// Stores usage as "percent remaining" (0-100%) to match server-side semantics (Nov 24, 2025).
//
// - CodexUsageSnapshot.fiveHourRemainingPercent: Stores "% remaining"
// - CodexUsageSnapshot.weekRemainingPercent: Stores "% remaining"
// - UI displays use helper methods to convert between used/remaining as needed
//
// Future Work — Quota Tracking:
// - Absolute quota tracking (e.g., "127 of 500 requests remaining")
// - "Buy credits" feature detection and UI
// - Mobile subscription quota display
//
// ## Staleness Semantics
//
// "Stale" means "data is old" NOT "data is inaccurate" (server data is fresh since Nov 2025).
//
// Staleness thresholds:
// - 5-hour window: 30 minutes since last event
// - Weekly window: 4 hours since last event
//
// Staleness triggers:
// - UI display: Shows "Last updated Xh ago" instead of reset time
// - Auto-probe: May trigger if no recent sessions + visible + opted-in
// - Freshness TTL: Manual probes set 1-hour "fresh" window to smooth UI
//
// ## Key Files
//
// - CodexStatusService.swift (this file): Main service, JSONL parsing, probe orchestration
// - Resources/codex_status_capture.sh: Bash script for tmux-based /status probing
// - CodexProbeConfig.swift: Probe session identification logic
// - CodexProbeProject.swift: Probe session cleanup/deletion logic
// - UsageStaleCheck.swift: Staleness detection logic (thresholds, event age)
// - UsageFreshness.swift: Freshness TTL management (1-hour grace period)
//
// ILLUSTRATIVE: Minimal model + service for Codex usage parsing with optional CLI /status probe.

// Snapshot of parsed values from Codex /status or banner
struct CodexUsageSnapshot: Equatable {
    var fiveHourRemainingPercent: Int = 0
    var fiveHourResetText: String = ""
    var hasFiveHourRateLimit: Bool = false
    var fiveHourLimitsSource: CodexLimitsSource? = nil
    var weekRemainingPercent: Int = 0
    var weekResetText: String = ""
    var hasWeekRateLimit: Bool = false
    var weekLimitsSource: CodexLimitsSource? = nil
    var limitsSource: CodexLimitsSource? = nil
    var usageLine: String? = nil
    var accountLine: String? = nil
    var modelLine: String? = nil
    var eventTimestamp: Date? = nil
    // New: surfaced usage (latest turn or snapshot)
    var lastInputTokens: Int? = nil
    var lastCachedInputTokens: Int? = nil
    var lastOutputTokens: Int? = nil
    var lastReasoningOutputTokens: Int? = nil
    var lastTotalTokens: Int? = nil

    // MARK: - Helper Methods for UI Display
    // Server now reports "remaining" but UI may want to show "used" (e.g., progress bars)

    func fiveHourPercentUsed() -> Int {
        return 100 - fiveHourRemainingPercent
    }

    func weekPercentUsed() -> Int {
        return 100 - weekRemainingPercent
    }
}

struct CodexProbeDiagnostics {
    let success: Bool
    let exitCode: Int32
    let scriptPath: String
    let workdir: String
    let codexBin: String?
    let tmuxBin: String?
    let timeoutSecs: String?
    let stdout: String
    let stderr: String
}

enum CodexLimitsSource: String, Equatable {
    case oauth
    case cliRPC = "cli_rpc"
    case jsonlFallback = "jsonl_fallback"
    case statusProbe = "status_probe"

    var displayName: String {
        switch self {
        case .oauth:
            return "OAuth"
        case .cliRPC:
            return "CLI RPC"
        case .jsonlFallback:
            return "JSONL fallback"
        case .statusProbe:
            return "/status probe"
        }
    }
}

@MainActor
final class CodexUsageModel: ObservableObject {
    static let shared = CodexUsageModel()

    @Published var fiveHourRemainingPercent: Int = 0
    @Published var fiveHourResetText: String = ""
    @Published var weekRemainingPercent: Int = 0
    @Published var weekResetText: String = ""
    @Published var limitsSource: CodexLimitsSource? = nil
    @Published var usageLine: String? = nil
    @Published var accountLine: String? = nil
    @Published var modelLine: String? = nil
    @Published var lastUpdate: Date? = nil
    @Published var lastEventTimestamp: Date? = nil
    @Published var cliUnavailable: Bool = false
    // New: surfaced usage (latest turn)
    @Published var lastInputTokens: Int? = nil
    @Published var lastCachedInputTokens: Int? = nil
    @Published var lastOutputTokens: Int? = nil
    @Published var lastReasoningOutputTokens: Int? = nil
    @Published var lastTotalTokens: Int? = nil
    @Published var isUpdating: Bool = false
    @Published var lastSuccessAt: Date? = nil

    private var service: CodexStatusService?
    private var isEnabled: Bool = false
    private var stripVisible: Bool = false
    private var menuVisible: Bool = false
    private var cockpitVisible: Bool = false
    private var cockpitPinned: Bool = false
    // Avoid touching NSApp during singleton initialization at app launch.
    // NSApp is an IUO and can be nil this early in startup.
    private var appIsActive: Bool = false

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
        let menuVisible = self.menuVisible || self.cockpitPinned
        let stripVisible = self.stripVisible || self.cockpitVisible
        let appIsActive = self.appIsActive
        Task.detached { [weak self] in
            await self?.service?.setVisibility(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        }
    }

    func refreshNow() {
        guard !AppRuntime.isRunningTests else { return }
        guard isEnabled else { return }
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                await svc.refreshNow()
                // Fallback timeout guard
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
                    if self.isUpdating { self.isUpdating = false }
                }
                return
            }
            // Fallback: one-shot refresh if the long-lived service isn't running.
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            await svc.refreshNow()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 65 * 1_000_000_000)
                if self.isUpdating { self.isUpdating = false }
            }
        }
    }

    // Hard-probe from Preferences pane: forces a /status tmux probe, shows result via callback
    func hardProbeNow(completion: @escaping (Bool) -> Void) {
        guard isEnabled else {
            completion(false)
            return
        }
        if isUpdating { return }
        isUpdating = true
        Task { [weak self] in
            guard let self = self else { return }
            if let svc = self.service {
                let diag = await svc.forceProbeNow()
                await MainActor.run {
                    if diag.success {
                        self.lastSuccessAt = Date()
                        setFreshUntil(for: .codex, until: Date().addingTimeInterval(UsageFreshnessTTL.probeFreshness))
                    }
                    self.isUpdating = false
                    completion(diag.success)
                }
                return
            }
            // Create a short-lived service for the probe
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if diag.success {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .codex, until: Date().addingTimeInterval(UsageFreshnessTTL.probeFreshness))
                }
                self.isUpdating = false
                completion(diag.success)
            }
        }
    }

    // Hard-probe variant that returns full diagnostics for UI display
    func hardProbeNowDiagnostics(completion: @escaping (CodexProbeDiagnostics) -> Void) {
        Task { [weak self] in
            guard let self = self else { return }
            guard self.isEnabled else {
                let diag = CodexProbeDiagnostics(
                    success: false,
                    exitCode: 125,
                    scriptPath: "(not run)",
                    workdir: CodexProbeConfig.probeWorkingDirectory(),
                    codexBin: nil,
                    tmuxBin: nil,
                    timeoutSecs: nil,
                    stdout: "",
                    stderr: "Codex usage tracking is disabled"
                )
                await MainActor.run { completion(diag) }
                return
            }
            if let svc = self.service {
                let diag = await svc.forceProbeNow()
                await MainActor.run {
                    if diag.success {
                        self.lastSuccessAt = Date()
                        setFreshUntil(for: .codex, until: Date().addingTimeInterval(UsageFreshnessTTL.probeFreshness))
                    }
                    completion(diag)
                }
                return
            }
            let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
                Task { @MainActor in self.apply(snapshot) }
            }
            let availability: @Sendable (Bool) -> Void = { unavailable in
                Task { @MainActor in self.cliUnavailable = unavailable }
            }
            let svc = CodexStatusService(updateHandler: handler, availabilityHandler: availability)
            let diag = await svc.forceProbeNow()
            await MainActor.run {
                if diag.success {
                    self.lastSuccessAt = Date()
                    setFreshUntil(for: .codex, until: Date().addingTimeInterval(UsageFreshnessTTL.probeFreshness))
                }
                self.isUpdating = false
                completion(diag)
            }
        }
    }

    private func start() {
        guard !AppRuntime.isRunningTests else { return }
        let model = self
        let handler: @Sendable (CodexUsageSnapshot) -> Void = { snapshot in
            Task { @MainActor in
                model.apply(snapshot)
            }
        }
        let availabilityHandler: @Sendable (Bool) -> Void = { unavailable in
            Task { @MainActor in
                model.cliUnavailable = unavailable
            }
        }
        let service = CodexStatusService(updateHandler: handler, availabilityHandler: availabilityHandler)
        self.service = service
        Task.detached {
            await service.start()
        }
        propagateVisibility()
    }

    private func stop() {
        Task.detached { [service] in
            await service?.stop()
        }
        service = nil
    }

    private func apply(_ s: CodexUsageSnapshot) {
        fiveHourRemainingPercent = clampPercent(s.fiveHourRemainingPercent)
        weekRemainingPercent = clampPercent(s.weekRemainingPercent)
        fiveHourResetText = s.fiveHourResetText
        weekResetText = s.weekResetText
        limitsSource = s.limitsSource
        usageLine = s.usageLine
        accountLine = s.accountLine
        modelLine = s.modelLine
        lastUpdate = Date()
        lastEventTimestamp = s.eventTimestamp
        lastInputTokens = s.lastInputTokens
        lastCachedInputTokens = s.lastCachedInputTokens
        lastOutputTokens = s.lastOutputTokens
        lastReasoningOutputTokens = s.lastReasoningOutputTokens
        lastTotalTokens = s.lastTotalTokens
        // Any snapshot means we received data; clear updating if set
        if isUpdating { isUpdating = false }
    }

}

// MARK: - Rate-limit models (log probe)

struct RateLimitWindowInfo {
    var remainingPercent: Int?
    var resetAt: Date?
    var windowMinutes: Int?
}

struct RateLimitSummary {
    var fiveHour: RateLimitWindowInfo
    var weekly: RateLimitWindowInfo
    var eventTimestamp: Date?
    var stale: Bool
    var sourceFile: URL?
    var missingRateLimits: Bool = false
}

// MARK: - Service

actor CodexStatusService {
    enum VisibilityMode: Sendable {
        case hidden
        case menuBackground
        case active
    }

    struct VisibilityContext: Sendable, Equatable {
        var menuVisible: Bool
        var stripVisible: Bool
        var appIsActive: Bool

        var effectiveVisible: Bool { menuVisible || (stripVisible && appIsActive) }
        var mode: VisibilityMode {
            if effectiveVisible {
                if appIsActive { return .active }
                if menuVisible { return .menuBackground }
            }
            return .hidden
        }
    }

    private enum State { case idle, starting, running, stopping }
    private static let probeSessionName = "status"
    private static let probeLabelPrefix = "as-cx-"
    private static let probeLabelLength = 12

    private static func makeRegex(
        pattern: String,
        options: NSRegularExpression.Options = [],
        label: String
    ) -> NSRegularExpression? {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        #if DEBUG
        print("[CodexStatus] Regex compile failed for \(label); using never-match fallback.")
        #endif
        return try? NSRegularExpression(pattern: "(?!)", options: [])
    }

#if DEBUG
    nonisolated static func buildRegexForTesting(
        pattern: String,
        options: NSRegularExpression.Options = [],
        label: String = "test"
    ) -> NSRegularExpression? {
        makeRegex(pattern: pattern, options: options, label: label)
    }

    func parseTokenCountTailForTesting(url: URL) -> RateLimitSummary? {
        parseTokenCountTail(url: url)
    }

    func parseStatusJSONForTesting(_ json: String) -> CodexUsageSnapshot? {
        parseStatusJSON(json)
    }

    func setSnapshotForTesting(_ snapshot: CodexUsageSnapshot) {
        self.snapshot = snapshot
    }

    func mergeRateLimitSnapshotForTesting(_ source: CodexUsageSnapshot, requirePositivePercent: Bool = false) -> CodexUsageSnapshot {
        var merged = snapshot
        mergeRateLimitSnapshot(source, into: &merged, requirePositivePercent: requirePositivePercent)
        return self.snapshot
    }

    func applyJSONLFallbackSummaryForTesting(_ summary: RateLimitSummary) -> CodexUsageSnapshot {
        var merged = snapshot
        applyJSONLFallbackSummary(summary, into: &merged)
        return self.snapshot
    }

    var lastFiveHourResetDateForTesting: Date? {
        lastFiveHourResetDate
    }

    var hasAuthoritativeLimitsSnapshotForTesting: Bool {
        hasAuthoritativeLimitsSnapshot
    }
#endif

    // Regex helpers
    private let percentRegex = CodexStatusService.makeRegex(
        pattern: "(\\d{1,3})\\s*%\\b",
        options: [.caseInsensitive],
        label: "percentRegex"
    )
    private let resetParenRegex = CodexStatusService.makeRegex(
        pattern: #"\((?:reset|resets)\s+([^)]+)\)"#,
        options: [.caseInsensitive],
        label: "resetParenRegex"
    )
    private let resetLineRegex = CodexStatusService.makeRegex(
        pattern: #"(?:reset|resets)\s*:?\s*(?:at:?\s*)?(.+)$"#,
        options: [.caseInsensitive],
        label: "resetLineRegex"
    )
    private let missingRateLimitsUsageLine = "Recent Codex logs omitted rate limits"

    private nonisolated let updateHandler: @Sendable (CodexUsageSnapshot) -> Void
    private nonisolated let availabilityHandler: @Sendable (Bool) -> Void

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var state: State = .idle
    private var tmuxProbeInFlight: Bool = false
    private var activeProbeLabel: String? = nil
    private var bufferOut = Data()
    private var bufferErr = Data()
    private var snapshot = CodexUsageSnapshot()
    private var lastFiveHourResetDate: Date?
    private var shouldRun: Bool = true
    private var visible: Bool = false
    private var visibilityContext = VisibilityContext(menuVisible: false, stripVisible: false, appIsActive: false)
    private var visibilityMode: VisibilityMode { visibilityContext.mode }
    private var backoffSeconds: UInt64 = 1
    private var refresherTask: Task<Void, Never>?
    private var deferredTmuxCleanupTask: Task<Void, Never>?
    private let codexOAuthFetcher: CodexOAuthUsageFetcher = {
        CodexOAuthUsageFetcher(credentials: CodexOAuthCredentials())
    }()
    private let codexRPCProbe = CodexCLIRPCProbe()
    private var lastStatusProbe: Date? = nil
    private var lastAppliedSourceFilePath: String? = nil
    private var lastAppliedSourceFileMTime: Date? = nil
    private var lastAppliedEventTimestamp: Date? = nil
    private var lastParseWasStaleOrFailed: Bool = false
    private let unchangedParseSkipFreshnessSeconds: TimeInterval = 12 * 60
    private let automaticProbeCooldownSeconds: TimeInterval = 4 * 60 * 60
    private let preferredLogProbeCandidateLimit: Int = 8
    private let fallbackLogProbeCandidateLimit: Int = 32
    private let logTailReadMaxBytes: Int = 192 * 1024
    private var hasResolvedTerminalPATH: Bool = false
    private var cachedTerminalPATH: String? = nil
    private var hasResolvedTmuxPath: Bool = false
    private var cachedTmuxPath: String? = nil
    private var lastOrphanCleanupAt: Date? = nil
    private let orphanCleanupMinInterval: TimeInterval = 3600 // 1 hour
    private var didRunMenuBarOrphanCleanup: Bool = false

    init(updateHandler: @escaping @Sendable (CodexUsageSnapshot) -> Void,
         availabilityHandler: @escaping @Sendable (Bool) -> Void) {
        self.updateHandler = updateHandler
        self.availabilityHandler = availabilityHandler
    }

    static func cleanupOrphansOnLaunch() async {
        let service = CodexStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.cleanupOrphanedProbeProcesses()
    }

    func start() async {
        shouldRun = true
        // Clear persisted auto-probe cooldown from a prior app session. The UI
        // freshness TTL is separate and should survive hard probes, but a stale
        // launch-time cooldown can incorrectly block the first eligible auto-probe.
        if let cooldown = codexAutoProbeCooldownUntil(), cooldown > Date() {
            setCodexAutoProbeCooldown(until: Date())
        }
        // Orphan cleanup is deferred until a usage surface becomes visible
        // to avoid heavy background work when the app is inactive/hidden.
        restartRefresherLoop()
    }

    private func restartRefresherLoop() {
        refresherTask?.cancel()
        refresherTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !(await self.shouldRun) { break }
                await self.refreshTick()
                if Task.isCancelled { break }
                let interval = await self.nextInterval()
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
            }
        }
    }

    func stop() async {
        shouldRun = false
        refresherTask?.cancel()
        refresherTask = nil
        if let label = activeProbeLabel {
            await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            activeProbeLabel = nil
        }
        tmuxProbeInFlight = false
    }

    func setVisible(_ isVisible: Bool) {
        // Back-compat shim: treat this as in-app visibility while active.
        setVisibility(menuVisible: false, stripVisible: isVisible, appIsActive: true)
    }

    func setVisibility(menuVisible: Bool, stripVisible: Bool, appIsActive: Bool) {
        let previousMode = visibilityMode
        visibilityContext = VisibilityContext(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)

        let wasVisible = visible
        visible = visibilityContext.effectiveVisible
        let mode = visibilityMode
        let becameActive = (previousMode != .active && mode == .active)
        let becameMenuBackground = (previousMode == .hidden && mode == .menuBackground)
        let visibilityModeChanged = previousMode != mode

        // If transitioning from hidden → visible, immediately refresh to show current data.
        // Menu-background visibility uses a cheap refresh path (no directory scans).
        if previousMode == .hidden, mode != .hidden, !wasVisible, visible {
            Task { [weak self] in
                guard let self else { return }
                if becameActive {
                    await self.ensureOrphanCleanupIfNeeded()
                } else if becameMenuBackground {
                    await self.ensureMenuBarOrphanCleanupIfNeeded()
                }
                await self.refreshTick()
            }
        } else if becameActive {
            // When transitioning from menu-background → active, clean up orphans once per launch.
            Task { [weak self] in
                guard let self else { return }
                await self.ensureOrphanCleanupIfNeeded()
            }
        } else if becameMenuBackground {
            // If the user only uses the menu bar while the app stays inactive, we still want
            // to clean up any orphaned tmux probes from prior crashes.
            Task { [weak self] in
                guard let self else { return }
                await self.ensureMenuBarOrphanCleanupIfNeeded()
            }
        }

        // Wake the refresher loop when visibility changes so we don't stay asleep
        // on a long hidden interval after becoming visible.
        if visibilityModeChanged, refresherTask != nil, shouldRun {
            restartRefresherLoop()
        }
    }

    func refreshNow() {
        // Manual refresh from strip/menu uses the same stale-only probe rule.
        Task { [weak self] in
            guard let self else { return }
            await self.ensureOrphanCleanupIfNeeded()
            await self.refreshTick(userInitiated: true)
        }
    }

    private func beginTmuxProbe() -> Bool {
        if tmuxProbeInFlight { return false }
        tmuxProbeInFlight = true
        return true
    }

    private func endTmuxProbe() {
        tmuxProbeInFlight = false
    }

    // MARK: - Core

    private func ensureProcessPrimed() async {
        if process?.isRunning == true { return }
        await launchREPL()
        if process?.isRunning == true {
            backoffSeconds = 1
            availabilityHandler(false)
            await send("ping\n/status\n")
        } else {
            availabilityHandler(true)
        }
    }

    private func launchREPL() async {
        if state == .starting || state == .running { return }
        state = .starting

        // Build a bash -lc command to use user's login shell PATH
        let command = "codex"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bash", "-lc", command]

        var env = ProcessInfo.processInfo.environment
        if let terminalPATH = terminalPATHCached() { env["PATH"] = terminalPATH }
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await self?.consume(data: data, isError: false) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await self?.consume(data: data, isError: true) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try proc.run()
            process = proc
            stdinPipe = stdin
            stdoutPipe = stdout
            stderrPipe = stderr
            state = .running
        } catch {
            state = .idle
        }
    }

    private func handleTermination() async {
        state = .idle
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        availabilityHandler(true)
        guard shouldRun else { return }
        // Exponential backoff restart
        let delay = min(backoffSeconds, 60)
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        backoffSeconds = min(delay * 2, 60)
        await ensureProcessPrimed()
    }

    private func terminateProcess() async {
        guard let p = process else { return }
        p.interrupt()
        // Give it a moment, then SIGTERM if needed
        try? await Task.sleep(nanoseconds: 500_000_000)
        if p.isRunning { p.terminate() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Avoid using non-existent kill() API on Process; rely on terminate.
        if p.isRunning { p.terminate() }
        process = nil
        state = .idle
    }

    private func send(_ text: String) async {
        guard state == .running, let fh = stdinPipe?.fileHandleForWriting else { return }
        if let data = text.data(using: .utf8) {
            // FileHandle.write(_:) is available and sufficient here.
            fh.write(data)
        }
    }

    private func consume(data: Data, isError: Bool) async {
        if isError { bufferErr.append(data) } else { bufferOut.append(data) }
        // Drain complete lines without holding an inout across await
        let lines = drainLines(fromError: isError)
        for line in lines {
            await handleLine(line)
        }
    }

    private func drainLines(fromError: Bool) -> [String] {
        var produced: [String] = []
        var buffer = fromError ? bufferErr : bufferOut
        while true {
            if let idx = buffer.firstIndex(of: 0x0a) { // newline byte
                let lineData = buffer.subdata(in: 0..<idx)
                buffer.removeSubrange(0...idx)
                if let line = String(data: lineData, encoding: .utf8) {
                    produced.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } else {
                break
            }
        }
        // Write back the remaining buffer
        if fromError {
            bufferErr = buffer
        } else {
            bufferOut = buffer
        }
        return produced
    }

    private func handleLine(_ line: String) async {
        if line.isEmpty { return }
        let clean = stripANSI(line)
        let lower = clean.lowercased()
        let isFiveHour = (lower.contains("5h") || lower.contains("5 h") || lower.contains("5-hour") || lower.contains("5 hour")) && lower.contains("limit")
        if isFiveHour {
            var s = snapshot
            s.fiveHourRemainingPercent = extractPercent(from: clean) ?? s.fiveHourRemainingPercent
            s.fiveHourResetText = extractResetText(from: clean) ?? s.fiveHourResetText
            s.hasFiveHourRateLimit = true
            snapshot = s
            updateHandler(snapshot)
            return
        }
        let isWeekly = (lower.contains("weekly") && lower.contains("limit")) || lower.contains("week limit")
        if isWeekly {
            var s = snapshot
            s.weekRemainingPercent = extractPercent(from: clean) ?? s.weekRemainingPercent
            s.weekResetText = extractResetText(from: clean) ?? s.weekResetText
            s.hasWeekRateLimit = true
            snapshot = s
            updateHandler(snapshot)
            return
        }
        if lower.hasPrefix("account:") { var s = snapshot; s.accountLine = clean; snapshot = s; updateHandler(snapshot); return }
        if lower.hasPrefix("model:") { var s = snapshot; s.modelLine = clean; snapshot = s; updateHandler(snapshot); return }
        if lower.hasPrefix("token usage:") { var s = snapshot; s.usageLine = clean; snapshot = s; updateHandler(snapshot); return }
    }

    private func extractPercent(from line: String) -> Int? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let m = percentRegex?.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            let str = (line as NSString).substring(with: m.range(at: 1))
            return Int(str)
        }
        return nil
    }

    private func extractResetText(from line: String) -> String? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = resetParenRegex?.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        if let m = resetLineRegex?.firstMatch(in: line, options: [], range: range), m.numberOfRanges >= 2 {
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func refreshTick(userInitiated: Bool = false) async {
        let mode = visibilityMode
        if mode == .hidden && !userInitiated { return }
        let roots = sessionsRoots()
        availabilityHandler(false)

        if mode == .menuBackground && !userInitiated {
            await refreshTickMenuBackground(roots: roots, now: Date())
            return
        }

        let now = Date()
        if !roots.isEmpty {
            let candidateDaysBack = lastParseWasStaleOrFailed ? 10 : 2
            var latestCandidate = newestCandidateFile(roots: roots, daysBack: candidateDaysBack, limit: 10)
            if latestCandidate == nil, candidateDaysBack < 10 {
                latestCandidate = newestCandidateFile(roots: roots, daysBack: 10, limit: 10)
            }

            let shouldSkipParse = shouldSkipLogParse(latestCandidate: latestCandidate, now: now)
            if !shouldSkipParse, let summary = probeLatestRateLimits(roots: roots, expandSearch: lastParseWasStaleOrFailed) {
                var s = snapshot
                if !summary.missingRateLimits {
                    applyJSONLFallbackSummary(summary, into: &s)
                } else if !hasAuthoritativeLimitsSnapshot {
                    markRateLimitsUnavailable(into: &s)
                    snapshot = s
                    updateHandler(snapshot)
                }

                if let sourceFile = summary.sourceFile {
                    lastAppliedSourceFilePath = sourceFile.path
                    lastAppliedSourceFileMTime = fileModificationDate(sourceFile)
                }
                lastAppliedEventTimestamp = summary.eventTimestamp
                lastParseWasStaleOrFailed = summary.stale
            } else if !shouldSkipParse {
                lastParseWasStaleOrFailed = true
            }
        }

        if mode == .active || mode == .menuBackground || userInitiated {
            _ = await refreshPreferredLiveLimits(visibleFastPath: mode == .active || userInitiated)
        }

        // Optional: run a one-shot tmux /status probe only when stale (manual or auto)
        if !FeatureFlags.disableCodexProbes, (mode == .active || userInitiated) {
            await maybeProbeStatusViaTMUX(userInitiated: userInitiated)
        }
    }

    private func refreshTickMenuBackground(roots: [URL], now: Date) async {
        // Menu bar should remain functional while the app is inactive, but background ticks
        // must stay extremely cheap to avoid energy warnings. Avoid directory scans.

        if let eventTime = snapshot.eventTimestamp {
            let stale = now.timeIntervalSince(eventTime) > 3 * 60
            if snapshot.usageLine != (stale ? "Usage is stale (>3m)" : nil) {
                var s = snapshot
                s.usageLine = stale ? "Usage is stale (>3m)" : nil
                snapshot = s
                updateHandler(snapshot)
            }
        }

        // Resolve the current source file and allow lightweight reseeding when activity
        // shifts to a different JSONL file while the app window is inactive.
        var sourceFile: URL? = nil
        if let path = lastAppliedSourceFilePath {
            let candidate = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                sourceFile = candidate
            } else {
                // The previously seeded file was rotated/removed. Clear and re-seed.
                lastAppliedSourceFilePath = nil
                lastAppliedSourceFileMTime = nil
            }
        }
        if let newest = newestCandidateFile(roots: roots, daysBack: 1, limit: 3) {
            if let current = sourceFile {
                let currentMTime = fileModificationDate(current) ?? .distantPast
                let newestMTime = fileModificationDate(newest) ?? .distantPast
                if newest.path != current.path, newestMTime >= currentMTime {
                    sourceFile = newest
                    lastAppliedSourceFilePath = newest.path
                    // Force one parse when switching files.
                    lastAppliedSourceFileMTime = nil
                }
            } else {
                lastAppliedSourceFilePath = newest.path
                sourceFile = newest
                // Do not seed mtime; we still need the first parse.
                lastAppliedSourceFileMTime = nil
            }
        }
        guard let sourceFile else { return }

        _ = await refreshPreferredLiveLimits(visibleFastPath: false)

        // Only parse when the file changes; otherwise rely on the cached snapshot.
        guard let mtime = fileModificationDate(sourceFile) else { return }
        if let lastAppliedSourceFileMTime,
           sourceFile.path == lastAppliedSourceFilePath,
           mtime == lastAppliedSourceFileMTime,
           lastAppliedEventTimestamp != nil {
            return
        }

        if let summary = parseTokenCountTail(url: sourceFile) {
            var s = snapshot
            if !summary.missingRateLimits {
                applyJSONLFallbackSummary(summary, into: &s)
            } else if !hasAuthoritativeLimitsSnapshot {
                markRateLimitsUnavailable(into: &s)
                snapshot = s
                updateHandler(snapshot)
            }
            lastAppliedSourceFilePath = sourceFile.path
            lastAppliedSourceFileMTime = mtime
            lastAppliedEventTimestamp = summary.eventTimestamp
            lastParseWasStaleOrFailed = summary.stale
        } else {
            lastParseWasStaleOrFailed = true
        }

        // Run probe in menu-background mode too (e.g. cockpit pinned, app inactive).
        if !FeatureFlags.disableCodexProbes {
            await maybeProbeStatusViaTMUX(userInitiated: false)
        }
    }

    // MARK: - Alternate rate-limit sources (OAuth API → CLI RPC)

    private var hasAuthoritativeLimitsSnapshot: Bool {
        isAuthoritativeLimitsSource(snapshot.fiveHourLimitsSource) &&
        isAuthoritativeLimitsSource(snapshot.weekLimitsSource)
    }

    /// Primary chain for authoritative limits. JSONL is deliberately excluded here and
    /// remains a fallback-only source handled by the log parsing path.
    private func fetchPreferredRateLimits(oauthSuccessCooldown: TimeInterval) async -> CodexUsageSnapshot? {
        if let snap = await codexOAuthFetcher.fetchUsage(cooldownSuccess: oauthSuccessCooldown) {
            return snap
        }
        if let snap = await codexRPCProbe.fetchRateLimits() {
            return snap
        }
        return nil
    }

    @discardableResult
    private func refreshPreferredLiveLimits(visibleFastPath: Bool) async -> CodexUsageSnapshot? {
        let successCooldown: TimeInterval = visibleFastPath ? 60 : 5 * 60
        guard let preferredSnap = await fetchPreferredRateLimits(oauthSuccessCooldown: successCooldown) else {
            return nil
        }
        var merged = snapshot
        mergeRateLimitSnapshot(preferredSnap, into: &merged)
        return preferredSnap
    }

    /// Merges rate-limit fields from `source` into `dest`, commits to `snapshot`,
    /// and notifies the UI. 0% remains valid for exhausted buckets when the probe
    /// actually returned a percentage, but reset-only probe fragments are ignored.
    private func mergeRateLimitSnapshot(_ source: CodexUsageSnapshot, into dest: inout CodexUsageSnapshot, requirePositivePercent: Bool = false) {
        let shouldMergeFiveHour = source.hasFiveHourRateLimit && (!requirePositivePercent || source.fiveHourRemainingPercent >= 0)
        if shouldMergeFiveHour {
            dest.fiveHourRemainingPercent = clampPercent(source.fiveHourRemainingPercent)
        }
        if shouldMergeFiveHour {
            dest.hasFiveHourRateLimit = true
            if !source.fiveHourResetText.isEmpty { dest.fiveHourResetText = source.fiveHourResetText }
            dest.fiveHourLimitsSource = source.fiveHourLimitsSource ?? source.limitsSource
        }
        let shouldMergeWeek = source.hasWeekRateLimit && (!requirePositivePercent || source.weekRemainingPercent >= 0)
        if shouldMergeWeek {
            dest.weekRemainingPercent = clampPercent(source.weekRemainingPercent)
        }
        if shouldMergeWeek {
            dest.hasWeekRateLimit = true
            if !source.weekResetText.isEmpty { dest.weekResetText = source.weekResetText }
            dest.weekLimitsSource = source.weekLimitsSource ?? source.limitsSource
        }
        dest.limitsSource = aggregateLimitsSource(for: dest)
        dest.usageLine = nil  // Fresh data from probe/API; clear any stale marker
        dest.eventTimestamp = Date()
        snapshot = dest
        updateHandler(snapshot)
    }

    private func applyJSONLFallbackSummary(_ summary: RateLimitSummary, into s: inout CodexUsageSnapshot) {
        let canApplyFiveHourFallback = !isAuthoritativeLimitsSource(s.fiveHourLimitsSource)
        if canApplyFiveHourFallback, let p = summary.fiveHour.remainingPercent {
            s.fiveHourRemainingPercent = clampPercent(p)
            s.hasFiveHourRateLimit = true
            s.fiveHourLimitsSource = .jsonlFallback
        }
        if canApplyFiveHourFallback, let resetAt = summary.fiveHour.resetAt {
            s.fiveHourResetText = formatResetISO8601(resetAt)
            s.hasFiveHourRateLimit = true
            s.fiveHourLimitsSource = .jsonlFallback
        }
        let canApplyWeekFallback = !isAuthoritativeLimitsSource(s.weekLimitsSource)
        if canApplyWeekFallback, let p = summary.weekly.remainingPercent {
            s.weekRemainingPercent = clampPercent(p)
            s.hasWeekRateLimit = true
            s.weekLimitsSource = .jsonlFallback
        }
        if canApplyWeekFallback, let resetAt = summary.weekly.resetAt {
            s.weekResetText = formatResetISO8601(resetAt)
            s.hasWeekRateLimit = true
            s.weekLimitsSource = .jsonlFallback
        }
        s.usageLine = summary.stale ? "Usage is stale (>3m)" : nil
        s.eventTimestamp = summary.eventTimestamp
        lastFiveHourResetDate = summary.fiveHour.resetAt
        s.limitsSource = aggregateLimitsSource(for: s)
        snapshot = s
        updateHandler(snapshot)
    }

    private func markRateLimitsUnavailable(into s: inout CodexUsageSnapshot) {
        if !isAuthoritativeLimitsSource(s.fiveHourLimitsSource) {
            s.fiveHourResetText = UsageStaleThresholds.unavailableCopy
            s.fiveHourLimitsSource = nil
        }
        if !isAuthoritativeLimitsSource(s.weekLimitsSource) {
            s.weekResetText = UsageStaleThresholds.unavailableCopy
            s.weekLimitsSource = nil
        }
        s.limitsSource = aggregateLimitsSource(for: s)
        s.usageLine = missingRateLimitsUsageLine
    }

    // MARK: - Optional tmux /status probe
    private func maybeProbeStatusViaTMUX(userInitiated: Bool) async {
        // Probes are strictly secondary: only run when we have NO recent local sessions.
        // With fresh server data (post Nov 24, 2025), "stale" just means "data is old",
        // not "data is inaccurate". We probe to get current usage when user hasn't used Codex recently.
        let now = Date()

        // Check if we have NO recent JSONL events (no local sessions in last 6 hours)
        var noRecentSessions = false
        if let eventTime = snapshot.eventTimestamp {
            if now.timeIntervalSince(eventTime) > UsageStaleThresholds.codexSeverelyStale { noRecentSessions = true }
        } else {
            noRecentSessions = true  // No events at all
        }

        // Also check staleness for backward compat (data age display)
        let stale5h = isResetInfoStale(kind: "5h", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
        let staleWeek = isResetInfoStale(kind: "week", source: .codex, lastUpdate: nil, eventTimestamp: snapshot.eventTimestamp, now: now)
        let missingRateLimits = isResetInfoUnavailable(raw: snapshot.fiveHourResetText) || isResetInfoUnavailable(raw: snapshot.weekResetText)

        // Auto probes run whenever data is stale, even during active sessions.
        // The 4-hour cooldown + user opt-in gate keep token cost negligible (≤1-2 msgs/4h).
        let shouldProbe = userInitiated
            ? (noRecentSessions || stale5h || staleWeek || missingRateLimits)
            : (stale5h || staleWeek || missingRateLimits)
        guard shouldProbe else { return }

        // Additional gates for automatic/background path only
        if !userInitiated {
            // When rate limits are completely missing (no JSONL data AND OAuth/RPC
            // both failed), bypass cooldowns and visibility gates — the user has NO
            // usable data and the probe is the last resort.
            let needsProbeOverride = missingRateLimits || (stale5h && staleWeek)

            if !needsProbeOverride {
                // Normal path: respect all gates
                if let cooldown = codexAutoProbeCooldownUntil(now: now), cooldown > now { return }
                let allowAuto = UserDefaults.standard.bool(forKey: "CodexAllowStatusProbe")
                guard allowAuto else { return }
                guard visible else { return }
                if let last = lastStatusProbe, now.timeIntervalSince(last) < automaticProbeCooldownSeconds { return }
            } else {
                // Override path: only respect in-memory cooldown (shorter, 30 min)
                // to prevent retry storms, but skip persisted cooldown and visibility.
                if let last = lastStatusProbe, now.timeIntervalSince(last) < 30 * 60 { return }
            }
        }

        let tmuxSnap = await runCodexStatusViaTMUX()
        // Set cooldown timestamp unconditionally so a failed probe doesn't allow
        // an immediate retry on the next tick.
        lastStatusProbe = now
        _ = CodexProbeCleanup.cleanupNowIfAuto()
        guard let tmuxSnap else { return }
        var merged = snapshot
        mergeRateLimitSnapshot(tmuxSnap, into: &merged, requirePositivePercent: true)
        // Persist auto-probe cooldown separately from UI freshness so a successful
        // probe does not make old data appear freshly updated for the whole window.
        setCodexAutoProbeCooldown(until: now.addingTimeInterval(automaticProbeCooldownSeconds))
    }

    // Hard-probe entry point: forces a tmux /status probe regardless of staleness or prefs.
    // Returns diagnostics; merges snapshot on success.
    func forceProbeNow() async -> CodexProbeDiagnostics {
        guard !FeatureFlags.disableCodexProbes else {
            return CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(not run)", workdir: CodexProbeConfig.probeWorkingDirectory(), codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Probes disabled by feature flag")
        }
        let (snap, diag) = await runCodexStatusViaTMUXAndCollect()
        _ = CodexProbeCleanup.cleanupNowIfAuto()
        if let tmuxSnap = snap {
            var merged = snapshot
            mergeRateLimitSnapshot(tmuxSnap, into: &merged, requirePositivePercent: true)
        }
        return diag
    }

    private func runCodexStatusViaTMUX() async -> CodexUsageSnapshot? {
        let (snap, _) = await runCodexStatusViaTMUXAndCollect()
        return snap
    }

    private func runCodexStatusViaTMUXAndCollect() async -> (CodexUsageSnapshot?, CodexProbeDiagnostics) {
        guard let scriptURL = Bundle.main.url(forResource: "codex_status_capture", withExtension: "sh") else {
            let d = CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(missing)", workdir: CodexProbeConfig.probeWorkingDirectory(), codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Script not found in bundle")
            return (nil, d)
        }
        let workDir = CodexProbeConfig.probeWorkingDirectory()
        guard beginTmuxProbe() else {
            let d = CodexProbeDiagnostics(success: false, exitCode: 125, scriptPath: "(not run)", workdir: workDir, codexBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Probe already running")
            return (nil, d)
        }
        defer { endTmuxProbe() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["TIMEOUT_SECS"] = env["TIMEOUT_SECS"] ?? "14"
        let resolver = CodexCLIEnvironment()
        let codexBin = resolver.resolveBinary(customPath: nil)?.path
        if let codexBin { env["CODEX_BIN"] = codexBin }
        let tmuxBin = resolveTmuxPathCached()
        if let tmuxBin { env["TMUX_BIN"] = tmuxBin }
        let probeLabel = makeProbeLabel()
        env["TMUX_LABEL"] = probeLabel
        activeProbeLabel = probeLabel
        defer { activeProbeLabel = nil }
        let timeoutValue = Int(env["TIMEOUT_SECS"] ?? "") ?? 14
        let scriptTimeoutSeconds = max(20, timeoutValue + 8)

        // Provide a Terminal-like PATH so Node and vendor binaries resolve inside tmux
        if let terminalPATH = terminalPATHCached() { env["PATH"] = terminalPATH }
        process.environment = env
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch {
            let d = CodexProbeDiagnostics(success: false, exitCode: 127, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: "", stderr: error.localizedDescription)
            #if DEBUG
            print("[CodexProbe] Failed to launch capture script: \(error.localizedDescription)")
            #endif
            return (nil, d)
        }
        let didExit = await waitForProcessExit(process, timeoutSeconds: scriptTimeoutSeconds, label: probeLabel, session: Self.probeSessionName)
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Schedule force-cleanup on ALL exit paths (success, error, timeout).
        // Waits 2s for shell EXIT trap, then kills by ps scanning — works even
        // when the socket was already deleted by the shell cleanup.
        let capturedLabel = probeLabel
        deferredTmuxCleanupTask?.cancel()
        deferredTmuxCleanupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await self?.forceCleanupProbeByLabel(capturedLabel)
            await self?.cleanupOrphanedTmuxLabels()
        }

        if !didExit {
            let d = CodexProbeDiagnostics(success: false, exitCode: 124, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr.isEmpty ? "Script timed out" : stderr)
            return (nil, d)
        }
        if process.terminationStatus != 0 {
            #if DEBUG
            if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[CodexProbe] Script non-zero (\(process.terminationStatus)). stdout: \n\(stdout)")
            }
            if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[CodexProbe] Script stderr: \n\(stderr)")
            }
            #endif
            let d = CodexProbeDiagnostics(success: false, exitCode: process.terminationStatus, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
            return (nil, d)
        }
        let snap = parseStatusJSON(stdout)
        let d = CodexProbeDiagnostics(success: snap != nil, exitCode: 0, scriptPath: scriptURL.path, workdir: workDir, codexBin: codexBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
        return (snap, d)
    }

    private func parseStatusJSON(_ json: String) -> CodexUsageSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ok = obj["ok"] as? Bool, !ok { return nil }
        var s = CodexUsageSnapshot()
        if let fh = obj["five_hour"] as? [String: Any] {
            let percent = statusProbePercent(from: fh)
            if let p = percent {
                s.fiveHourRemainingPercent = p
            }
            if let r = fh["resets"] as? String, percent != nil { s.fiveHourResetText = r }
            if percent != nil {
                s.hasFiveHourRateLimit = true
                s.fiveHourLimitsSource = .statusProbe
            }
        }
        if let wk = obj["weekly"] as? [String: Any] {
            let percent = statusProbePercent(from: wk)
            if let p = percent {
                s.weekRemainingPercent = p
            }
            if let r = wk["resets"] as? String, percent != nil { s.weekResetText = r }
            if percent != nil {
                s.hasWeekRateLimit = true
                s.weekLimitsSource = .statusProbe
            }
        }
        s.limitsSource = aggregateLimitsSource(for: s)
        s.eventTimestamp = Date()
        return s
    }

    private func statusProbePercent(from payload: [String: Any]) -> Int? {
        if let percent = payload["pct_left"] as? Int {
            return clampPercent(percent)
        }
        if let percent = payload["pct_left"] as? Double {
            return clampPercent(Int(percent.rounded()))
        }
        if let percent = payload["pct_left"] as? NSNumber {
            return clampPercent(percent.intValue)
        }
        return nil
    }

    private func isAuthoritativeLimitsSource(_ source: CodexLimitsSource?) -> Bool {
        switch source {
        case .oauth?, .cliRPC?, .statusProbe?:
            return true
        case .jsonlFallback?, nil:
            return false
        }
    }

    private func aggregateLimitsSource(for snapshot: CodexUsageSnapshot) -> CodexLimitsSource? {
        let sources = [snapshot.hasFiveHourRateLimit ? snapshot.fiveHourLimitsSource : nil,
                       snapshot.hasWeekRateLimit ? snapshot.weekLimitsSource : nil]
            .compactMap { $0 }
        guard let first = sources.first else { return nil }
        return sources.allSatisfy({ $0 == first }) ? first : nil
    }

    private func waitForProcessExit(_ process: Process,
                                    timeoutSeconds: Int,
                                    label: String,
                                    session: String) async -> Bool {
        let maxIterations = max(1, timeoutSeconds * 2)
        var iterations = 0
        while process.isRunning && iterations < maxIterations {
            try? await Task.sleep(nanoseconds: 500_000_000)
            iterations += 1
        }
        if process.isRunning {
            process.terminate()
            await cleanupTmuxProbe(label: label, session: session)
            var grace = 0
            while process.isRunning && grace < 6 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                grace += 1
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            return false
        }
        // Belt-and-suspenders: even on clean script exit, verify the tmux server
        // is gone. The shell EXIT trap should handle it, but may silently fail.
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.cleanupTmuxProbe(label: label, session: session)
        }
        return true
    }

    private func makeProbeLabel() -> String {
        let token = randomToken(length: Self.probeLabelLength)
        return Self.probeLabelPrefix + token
    }

    private func randomToken(length: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array("0123456789")
        let all = letters + digits
        var rng = SystemRandomNumberGenerator()
        guard length > 0 else { return "" }
        var chars: [Character] = []
        chars.reserveCapacity(length)
        chars.append(letters.randomElement(using: &rng) ?? "a")
        if length > 1 {
            for _ in 0..<(length - 2) {
                chars.append(all.randomElement(using: &rng) ?? "a")
            }
            chars.append(digits.randomElement(using: &rng) ?? "0")
        }
        return String(chars)
    }

    private func cleanupOrphanedProbeProcesses() async {
        let workDir = CodexProbeConfig.probeWorkingDirectory()
        let markers = workDirMarkers(workDir)
        let snapshot = await runProcess(executable: "/bin/ps",
                                        arguments: ["-A", "-o", "pid=", "-o", "command="],
                                        timeoutSeconds: 2)
        guard !snapshot.stdout.isEmpty else {
            await cleanupOrphanedTmuxLabels()
            return
        }
        var labels = Set<String>()
        var pids: [pid_t] = []
        for line in snapshot.stdout.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let splitIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidString = String(trimmed[..<splitIndex])
            let command = String(trimmed[splitIndex...]).trimmingCharacters(in: .whitespaces)
            guard let pidValue = Int32(pidString) else { continue }
            let lowerCommand = command.lowercased()
            guard lowerCommand.contains("codex") else { continue }
            if lowerCommand.contains("codex_status_capture") { continue }
            let envSnapshot = await runProcess(executable: "/bin/ps",
                                               arguments: ["eww", "-p", pidString],
                                               timeoutSeconds: 2)
            let envLine = envSnapshot.stdout
            guard !envLine.isEmpty else { continue }
            guard envLine.contains("__CFBundleIdentifier=com.triada.AgentSessions") else { continue }
            guard markers.contains(where: { envLine.contains($0) }) else { continue }
            pids.append(pid_t(pidValue))
            if let label = extractTmuxLabel(from: envLine, expectedPrefix: Self.probeLabelPrefix) {
                labels.insert(label)
            }
        }
        // Secondary: find codex processes whose CWD matches the probe working directory.
        // The ps-eww check above misses processes inside tmux (no inherited env markers).
        // "-c codex" is a prefix match and may capture unrelated processes (e.g. codex-something),
        // but the CWD equality check below provides a sufficient safety filter.
        let lsofResult = await runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["-w", "-a", "-c", "codex", "-d", "cwd", "-nP", "-F", "pn"],
            timeoutSeconds: 3
        )
        if !lsofResult.stdout.isEmpty {
            let normalizedWD = normalizeProbePath(workDir)
            var cwdPID: Int32? = nil
            for line in lsofResult.stdout.split(separator: "\n") {
                let s = String(line)
                if s.hasPrefix("p"), let pid = Int32(s.dropFirst()) {
                    cwdPID = pid
                } else if s.hasPrefix("n"), let pid = cwdPID {
                    if normalizeProbePath(String(s.dropFirst())) == normalizedWD,
                       !pids.contains(pid_t(pid)) {
                        pids.append(pid_t(pid))
                    }
                }
            }
        }
        labels.formUnion(scanTmuxLabels(prefix: Self.probeLabelPrefix))
        for label in labels {
            if await tmuxServerLooksLikeProbe(label: label,
                                              session: Self.probeSessionName,
                                              expectedCommandToken: "codex") {
                await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            }
        }
        for pid in pids {
            await terminateProcessGroup(pid: pid)
        }
        // Kill socketless probe tmux servers: these survive when kill-server can't reach
        // them because the socket was already deleted by a prior partial cleanup.
        // Reuse the snapshot already captured above to avoid a redundant ps -A call.
        terminateSocketlessProbeServers(labelPrefix: Self.probeLabelPrefix,
                                       psOutput: snapshot.stdout)
    }

    private func cleanupOrphanedTmuxLabels() async {
        let labels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        for label in labels {
            if await tmuxServerLooksLikeProbe(label: label,
                                              session: Self.probeSessionName,
                                              expectedCommandToken: "codex") {
                await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            } else {
                // Server is dead/unreachable — socket is an orphan. Remove it.
                // The as-cx- prefix is unique to our probes, so this is always safe.
                removeOrphanedSocketFiles(label: label)
            }
        }
        // Also kill socketless probe tmux servers (socket deleted but process alive).
        let psSnap = await runProcess(executable: "/bin/ps",
                                      arguments: ["-A", "-o", "pid=", "-o", "command="],
                                      timeoutSeconds: 2)
        terminateSocketlessProbeServers(labelPrefix: Self.probeLabelPrefix,
                                       psOutput: psSnap.stdout)
    }

    /// Forcefully clean up a probe by scanning the process table.
    /// Does NOT rely on tmux socket/commands — works even when socket is already deleted.
    private func forceCleanupProbeByLabel(_ label: String) async {
        // 1. Find and kill the tmux server process by its command-line label argument
        let psSnap = await runProcess(executable: "/bin/ps",
                                      arguments: ["-A", "-o", "pid=", "-o", "command="],
                                      timeoutSeconds: 2)
        let labelArg = "-L \(label)"
        for line in psSnap.stdout.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            if command.contains("tmux"), command.contains(labelArg) {
                _ = kill(pid_t(pid), SIGKILL)
            }
        }
        // 2. Kill orphaned codex processes by CWD. When another probe is active,
        // find its tmux server PID and protect its entire process tree.
        // Fresh ps snapshot is required: the active probe may have started after
        // the snapshot used for step 1, so its tmux server wouldn't appear there.
        var activeTmuxPID: Int32? = nil
        if let currentLabel = activeProbeLabel {
            activeTmuxPID = await findTmuxServerPID(label: currentLabel)
        }
        await killProbeProcessesByCWD(protectDescendantsOf: activeTmuxPID)
        // 3. Remove socket files
        removeOrphanedSocketFiles(label: label)
    }

    /// Kill codex processes whose CWD matches the probe working directory.
    /// When `protectDescendantsOf` is set, skips any process whose ancestor chain
    /// includes that PID (i.e., belongs to the active probe's tmux tree).
    private func killProbeProcessesByCWD(protectDescendantsOf protectedRootPID: Int32? = nil) async {
        let workDir = CodexProbeConfig.probeWorkingDirectory()
        let normalizedWD = normalizeProbePath(workDir)
        let lsofResult = await runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["-w", "-a", "-c", "codex", "-d", "cwd", "-nP", "-F", "pn"],
            timeoutSeconds: 3
        )
        guard !lsofResult.stdout.isEmpty else { return }

        // Build a pid→ppid map once (avoids per-process ps calls).
        var ppidMap: [Int32: Int32] = [:]
        if protectedRootPID != nil {
            let psSnap = await runProcess(executable: "/bin/ps",
                                          arguments: ["-A", "-o", "pid=", "-o", "ppid="],
                                          timeoutSeconds: 2)
            for line in psSnap.stdout.split(separator: "\n") {
                let cols = line.split(whereSeparator: { $0.isWhitespace })
                if cols.count >= 2, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) {
                    ppidMap[pid] = ppid
                }
            }
        }

        var cwdPID: Int32? = nil
        for line in lsofResult.stdout.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("p"), let pid = Int32(s.dropFirst()) {
                cwdPID = pid
            } else if s.hasPrefix("n"), let pid = cwdPID {
                if normalizeProbePath(String(s.dropFirst())) == normalizedWD {
                    if let root = protectedRootPID, isDescendant(pid, of: root, ppidMap: ppidMap) {
                        continue
                    }
                    await terminateProcessGroup(pid: pid_t(pid))
                }
            }
        }
    }

    /// Walk the ppid chain to check if `pid` is a descendant of `ancestorPID`.
    private func isDescendant(_ pid: Int32, of ancestorPID: Int32, ppidMap: [Int32: Int32]) -> Bool {
        var current = pid
        var hops = 0
        while let parent = ppidMap[current], parent > 1, hops < 20 {
            if parent == ancestorPID { return true }
            current = parent
            hops += 1
        }
        return false
    }

    /// Find the tmux **server** PID for a given label from a fresh ps snapshot.
    /// Filters out short-lived tmux client processes (capture-pane, send-keys, etc.)
    /// by requiring the command to contain "new-session" or "start-server", or by
    /// falling back to the process with the lowest PID (the server starts first).
    private func findTmuxServerPID(label: String) async -> Int32? {
        let snap = await runProcess(executable: "/bin/ps",
                                    arguments: ["-A", "-o", "pid=", "-o", "command="],
                                    timeoutSeconds: 2)
        let labelArg = "-L \(label)"
        var serverPID: Int32? = nil
        var lowestPID: Int32? = nil
        for line in snap.stdout.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            guard command.contains("tmux"), command.contains(labelArg) else { continue }
            // Prefer the server process (new-session or start-server in command)
            if command.contains("new-session") || command.contains("start-server") {
                serverPID = pid
                break
            }
            // Track lowest PID as fallback (server starts before clients)
            if lowestPID == nil || pid < (lowestPID ?? Int32.max) {
                lowestPID = pid
            }
        }
        return serverPID ?? lowestPID
    }

    private func removeOrphanedSocketFiles(label: String) {
        guard label.hasPrefix(Self.probeLabelPrefix) else { return }
        let uid = getuid()
        for root in ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"] {
            try? FileManager.default.removeItem(atPath: "\(root)/\(label)")
        }
    }

    private func extractTmuxLabel(from command: String, expectedPrefix: String) -> String? {
        guard let range = command.range(of: "TMUX=") else { return nil }
        let after = command[range.upperBound...]
        let end = after.firstIndex(where: { $0.isWhitespace }) ?? after.endIndex
        let value = String(after[..<end])
        let socketPath = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let socketPath else { return nil }
        let label = URL(fileURLWithPath: String(socketPath)).lastPathComponent
        return label.hasPrefix(expectedPrefix) ? label : nil
    }

    private func workDirMarkers(_ workDir: String) -> [String] {
        let escaped = workDir.replacingOccurrences(of: " ", with: "\\ ")
        if escaped == workDir {
            return ["WORKDIR=\(workDir)"]
        }
        return ["WORKDIR=\(workDir)", "WORKDIR=\(escaped)"]
    }

    private func scanTmuxLabels(prefix: String) -> Set<String> {
        let uid = getuid()
        let roots = ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
        var labels = Set<String>()
        let fm = FileManager.default
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let contents = try? fm.contentsOfDirectory(at: rootURL,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for entry in contents {
                let name = entry.lastPathComponent
                if name.hasPrefix(prefix) {
                    labels.insert(name)
                }
            }
        }
        return labels
    }

    private func tmuxServerLooksLikeProbe(label: String,
                                          session: String,
                                          expectedCommandToken: String) async -> Bool {
        guard let tmuxPath = resolveTmuxPathCached() else { return false }
        let sessions = await runProcess(executable: tmuxPath,
                                        arguments: ["-L", label, "list-sessions", "-F", "#{session_name}"],
                                        timeoutSeconds: 2)
        guard sessions.status == 0 else { return false }
        let sessionNames = sessions.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard sessionNames.contains(session) else { return false }
        let clients = await runProcess(executable: tmuxPath,
                                       arguments: ["-L", label, "list-clients", "-t", session, "-F", "#{client_name}"],
                                       timeoutSeconds: 2)
        if clients.status == 0 {
            let trimmedClients = clients.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedClients.isEmpty { return false }
        }
        let env = await runProcess(executable: tmuxPath,
                                   arguments: ["-L", label, "show-environment", "-g"],
                                   timeoutSeconds: 2)
        if env.status == 0, env.stdout.contains("AS_PROBE=1") {
            guard env.stdout.contains("AS_PROBE_APP=com.triada.AgentSessions") else { return false }
            guard env.stdout.contains("AS_PROBE_KIND=codex") else { return false }
            return true
        }
        let panes = await runProcess(executable: tmuxPath,
                                     arguments: ["-L", label, "list-panes", "-t", session, "-F", "#{pane_current_command} #{pane_start_command}"],
                                     timeoutSeconds: 2)
        guard panes.status == 0 else { return false }
        let paneInfo = panes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !paneInfo.isEmpty else { return false }
        return paneInfo.contains(expectedCommandToken.lowercased())
    }

    private func cleanupTmuxProbe(label: String, session: String) async {
        guard let tmuxPath = resolveTmuxPathCached() else { return }
        if let panePid = await tmuxPanePID(tmuxPath: tmuxPath, label: label, session: session) {
            await terminateProcessGroup(pid: panePid)
        }
        _ = await runProcess(executable: tmuxPath,
                             arguments: ["-L", label, "kill-session", "-t", session],
                             timeoutSeconds: 2)
        _ = await runProcess(executable: tmuxPath,
                             arguments: ["-L", label, "kill-server"],
                             timeoutSeconds: 2)
        // Remove orphaned socket files (parity with claude_usage_capture.sh)
        let uid = getuid()
        for root in ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"] {
            let socketPath = "\(root)/\(label)"
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func tmuxPanePID(tmuxPath: String, label: String, session: String) async -> pid_t? {
        let result = await runProcess(executable: tmuxPath,
                                      arguments: ["-L", label, "display-message", "-p", "-t", "\(session):0.0", "#{pane_pid}"],
                                      timeoutSeconds: 2)
        guard result.status == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidValue = Int32(trimmed) else { return nil }
        return pid_t(pidValue)
    }

    private func terminateProcessGroup(pid: pid_t) async {
        guard pid > 0 else { return }
        if pid == getpid() { return }
        let pgid = getpgid(pid)
        let appPgid = getpgrp()
        if pgid > 0 && pgid != appPgid {
            _ = kill(-pgid, SIGTERM)
        } else {
            _ = kill(pid, SIGTERM)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if pgid > 0 && pgid != appPgid {
            _ = kill(-pgid, SIGKILL)
        } else {
            _ = kill(pid, SIGKILL)
        }
    }

    private func runProcess(executable: String,
                            arguments: [String],
                            timeoutSeconds: Int) async -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return (127, "") }
        let maxIterations = max(1, timeoutSeconds * 10)
        var iterations = 0
        while process.isRunning && iterations < maxIterations {
            try? await Task.sleep(nanoseconds: 100_000_000)
            iterations += 1
        }
        if process.isRunning {
            process.terminate()
            return (124, "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout)
    }

    private func nextInterval() -> UInt64 {
        // Read Codex-specific polling interval (defaults to 300s = 5 min)
        let userInterval = UInt64(UserDefaults.standard.object(forKey: "CodexPollingInterval") as? Int ?? 300)

        // Energy optimization: Stop polling entirely when nothing is visible
        // (menu bar and strips both hidden)
        let urgent = isUrgent()
        if visibilityMode == .hidden && !urgent {
            // When hidden and not urgent: don't poll at all (1 hour = effectively disabled)
            return 3600 * 1_000_000_000
        }

        // Energy optimization: Menu-bar background visibility should tick rarely and cheaply.
        if visibilityMode == .menuBackground && !urgent {
            if !Self.onACPower() {
                return 10 * 60 * 1_000_000_000
            }
            // Clamp to at least 60s on AC power; JSONL parse is mtime-guarded so fast ticks are cheap.
            return max(UInt64(60), userInterval) * 1_000_000_000
        }

        // Policy when visible or urgent:
        // - On AC power: use userInterval
        // - On battery: 300s
        if !Self.onACPower() {
            return 300 * 1_000_000_000
        }
        return userInterval * 1_000_000_000
    }

    private func isUrgent() -> Bool {
        // Urgent if 5-hour limit is running low (≤20% remaining = ≥80% used)
        if snapshot.fiveHourPercentUsed() >= 80 { return true }
        if let reset = lastFiveHourResetDate {
            if reset.timeIntervalSinceNow <= 15 * 60 { return true }
        }
        return false
    }

    private func ensureOrphanCleanupIfNeeded() async {
        if let last = lastOrphanCleanupAt, Date().timeIntervalSince(last) < orphanCleanupMinInterval { return }
        lastOrphanCleanupAt = Date()
        await cleanupOrphanedProbeProcesses()
    }

    private func ensureMenuBarOrphanCleanupIfNeeded() async {
        if let last = lastOrphanCleanupAt, Date().timeIntervalSince(last) < orphanCleanupMinInterval { return }
        // didRunMenuBarOrphanCleanup is intentionally one-shot per session: the menu-bar
        // path only needs to run once on launch. Periodic re-runs are handled by
        // ensureOrphanCleanupIfNeeded (which calls cleanupOrphanedProbeProcesses).
        guard !didRunMenuBarOrphanCleanup else { return }
        didRunMenuBarOrphanCleanup = true

        // Cheap guard: if there are no tmux labels, avoid resolving tmux or running commands.
        let labels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        guard !labels.isEmpty else { return }
        await cleanupOrphanedTmuxLabels()
    }

    private static func onACPower() -> Bool {
        // Best-effort detection using IOKit; fall back to assuming AC if unavailable.
        #if os(macOS)
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let typeCF = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() {
            let type = typeCF as String
            return type == (kIOPSACPowerValue as String)
        }
        #endif
        // Fallback: if Low Power Mode is enabled, treat as battery-like
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        }
        return true
    }

    // MARK: - Log probe helpers

    private func sessionsRoots() -> [URL] {
        var roots: [URL] = []
        func add(_ path: String) {
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append(url)
            }
        }
        if let override = UserDefaults.standard.string(forKey: "SessionsRootOverride"), !override.isEmpty {
            add(override)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            add((env as NSString).appendingPathComponent("sessions"))
        }
        add((NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions"))
        // Dedup by path
        var seen = Set<String>()
        roots = roots.filter { seen.insert($0.path).inserted }
        return roots
    }

    private func shouldSkipLogParse(latestCandidate: URL?, now: Date) -> Bool {
        guard let latestCandidate else { return false }
        guard let candidateMTime = fileModificationDate(latestCandidate) else { return false }
        guard latestCandidate.path == lastAppliedSourceFilePath else { return false }
        guard candidateMTime == lastAppliedSourceFileMTime else { return false }
        guard let lastEvent = lastAppliedEventTimestamp else { return false }
        return now.timeIntervalSince(lastEvent) <= unchangedParseSkipFreshnessSeconds
    }

    private func newestCandidateFile(roots: [URL], daysBack: Int, limit: Int) -> URL? {
        var newest: URL? = nil
        var newestDate: Date = .distantPast
        for root in roots {
            let candidates = findCandidateFiles(root: root, daysBack: daysBack, limit: limit)
            guard let first = candidates.first else { continue }
            let modified = fileModificationDate(first) ?? .distantPast
            if modified > newestDate {
                newest = first
                newestDate = modified
            }
        }
        return newest
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    private func probeLatestRateLimits(roots: [URL], expandSearch: Bool) -> RateLimitSummary? {
        var files: [URL] = []
        for r in roots {
            files.append(contentsOf: findCandidateFiles(root: r,
                                                        daysBack: 10,
                                                        limit: preferredLogProbeCandidateLimit))
        }
        // Global sort by mtime desc across roots
        files.sort { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        for url in files {
            if let summary = parseTokenCountTail(url: url) { return summary }
        }

        if expandSearch {
            var expanded: [URL] = []
            for r in roots {
                expanded.append(contentsOf: findCandidateFiles(root: r,
                                                               daysBack: 10,
                                                               limit: fallbackLogProbeCandidateLimit))
            }
            expanded.sort { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return da > db
            }
            for url in expanded {
                if let summary = parseTokenCountTail(url: url) { return summary }
            }
        }

        return RateLimitSummary(
            fiveHour: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
            weekly: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
            eventTimestamp: nil,
            stale: true,
            sourceFile: nil,
            missingRateLimits: true
        )
    }

    private func findCandidateFiles(root: URL, daysBack: Int, limit: Int) -> [URL] {
        var urls: [URL] = []
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let fm = FileManager.default
        for offset in 0...daysBack {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let folder = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for u in items where u.pathExtension.lowercased() == "jsonl" {
                        urls.append(u)
                    }
                }
            }
            if urls.count >= limit { break }
        }
        urls.sort { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        if urls.count > limit { urls = Array(urls.prefix(limit)) }
        return urls
    }

    private func parseTokenCountTail(url: URL) -> RateLimitSummary? {
        guard let lines = tailLines(url: url, maxBytes: logTailReadMaxBytes) else { return nil }
        var fallbackSummary: RateLimitSummary? = nil
        var didCaptureNewestUsage = false
        var newestRelevantTimestamp: Date? = nil
        // Walk most-recent → older. Be permissive about shape; Codex logs can vary.
        for raw in lines.reversed() {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Prefer nested payload, but fall back to top-level when payload is absent.
            let payload = (obj["payload"] as? [String: Any]) ?? obj

            // Establish a createdAt for this event (best-effort)
            let createdAt = decodeFlexibleDate(obj["created_at"]) ??
                            decodeFlexibleDate(payload["created_at"]) ??
                            decodeFlexibleDate(obj["timestamp"]) ??
                            decodeFlexibleDate(payload["timestamp"]) ??
                            Date()
            if newestRelevantTimestamp == nil, isRelevantRateLimitOrUsageEvent(payload: payload, obj: obj) {
                newestRelevantTimestamp = createdAt
            }

            // Surface usage tokens if present (new or legacy forms)
            if !didCaptureNewestUsage {
                didCaptureNewestUsage = extractUsageIfPresent(from: payload, createdAt: createdAt)
            }

            // Rate limits may appear at payload.rate_limits or (legacy) at top-level
            if let rate = (payload["rate_limits"] as? [String: Any]) ?? (obj["rate_limits"] as? [String: Any]) {
                guard let summary = makeRateLimitSummary(rate: rate, createdAt: createdAt, sourceFile: url) else { continue }
                let limitID = normalizeLimitID(rate["limit_id"])
                if limitID == "codex" || limitID == nil {
                    return summary
                }
                if fallbackSummary == nil {
                    fallbackSummary = summary
                }
                continue
            }

            // Legacy: token_count style where rate_limits nested under payload.info
            if let kind = payload["type"] as? String, kind.lowercased() == "token_count" {
                if let info = payload["info"] as? [String: Any], let rate = info["rate_limits"] as? [String: Any] {
                    guard let summary = makeRateLimitSummary(rate: rate, createdAt: createdAt, sourceFile: url) else { continue }
                    let limitID = normalizeLimitID(rate["limit_id"])
                    if limitID == "codex" || limitID == nil {
                        return summary
                    }
                    if fallbackSummary == nil {
                        fallbackSummary = summary
                    }
                }
            }
        }
        if let fallbackSummary {
            return fallbackSummary
        }
        if let newestRelevantTimestamp {
            return RateLimitSummary(
                fiveHour: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
                weekly: RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil),
                eventTimestamp: newestRelevantTimestamp,
                stale: true,
                sourceFile: url,
                missingRateLimits: true
            )
        }
        return nil
    }

    private func isRelevantRateLimitOrUsageEvent(payload: [String: Any], obj: [String: Any]) -> Bool {
        if (payload["rate_limits"] as? [String: Any]) != nil || (obj["rate_limits"] as? [String: Any]) != nil {
            return true
        }
        let kind = (payload["type"] as? String)?.lowercased() ?? ""
        if kind == "token_count" { return true }
        if kind == "turn.completed" || kind == "turn_completed" || kind == "turn-completed" { return true }
        return false
    }

    // MARK: - Usage extraction (new + legacy)

    @discardableResult
    private func extractUsageIfPresent(from payload: [String: Any], createdAt: Date) -> Bool {
        // New model: turn.completed with usage {...}
        if let kind = (payload["type"] as? String)?.lowercased(), kind == "turn.completed" || kind == "turn_completed" || kind == "turn-completed" {
            if let usage = payload["usage"] as? [String: Any] ?? (payload["data"] as? [String: Any])?["usage"] as? [String: Any] {
                let parsedInput = intValue(usage["input_tokens"])
                let parsedCachedInput = intValue(usage["cached_input_tokens"])
                let parsedOutput = intValue(usage["output_tokens"])
                let parsedReasoning = intValue(usage["reasoning_output_tokens"])
                let parsedTotal = intValue(usage["total_tokens"])
                var s = snapshot
                var decodedAnyField = false
                if let parsedInput {
                    s.lastInputTokens = parsedInput
                    decodedAnyField = true
                }
                if let parsedCachedInput {
                    s.lastCachedInputTokens = parsedCachedInput
                    decodedAnyField = true
                }
                if let parsedOutput {
                    s.lastOutputTokens = parsedOutput
                    decodedAnyField = true
                }
                if let parsedReasoning {
                    s.lastReasoningOutputTokens = parsedReasoning
                    decodedAnyField = true
                }
                if let parsedTotal {
                    s.lastTotalTokens = parsedTotal
                    decodedAnyField = true
                } else if (parsedInput != nil || parsedOutput != nil),
                          let i = s.lastInputTokens,
                          let o = s.lastOutputTokens {
                    s.lastTotalTokens = i + o
                    decodedAnyField = true
                }

                guard decodedAnyField else { return false }
                snapshot = s
                updateHandler(snapshot)
                // Usage sampling for cap ETA disabled; analytics will compute on demand.
                return true
            }
        }
        // Legacy path: token_count.info.last_token_usage {...}
        if let kind = (payload["type"] as? String)?.lowercased(), kind == "token_count" {
            if let info = payload["info"] as? [String: Any] {
                if let last = info["last_token_usage"] as? [String: Any] {
                    let parsedInput = intValue(last["input_tokens"])
                    let parsedCachedInput = intValue(last["cached_input_tokens"])
                    let parsedOutput = intValue(last["output_tokens"])
                    let parsedReasoning = intValue(last["reasoning_output_tokens"])
                    let parsedTotal = intValue(last["total_tokens"])
                    var s = snapshot
                    var decodedAnyField = false
                    if let parsedInput {
                        s.lastInputTokens = parsedInput
                        decodedAnyField = true
                    }
                    if let parsedCachedInput {
                        s.lastCachedInputTokens = parsedCachedInput
                        decodedAnyField = true
                    }
                    if let parsedOutput {
                        s.lastOutputTokens = parsedOutput
                        decodedAnyField = true
                    }
                    if let parsedReasoning {
                        s.lastReasoningOutputTokens = parsedReasoning
                        decodedAnyField = true
                    }
                    if let parsedTotal {
                        s.lastTotalTokens = parsedTotal
                        decodedAnyField = true
                    } else if (parsedInput != nil || parsedOutput != nil),
                              let i = s.lastInputTokens,
                              let o = s.lastOutputTokens {
                        s.lastTotalTokens = i + o
                        decodedAnyField = true
                    }

                    guard decodedAnyField else { return false }
                    snapshot = s
                    updateHandler(snapshot)
                    // Usage sampling for cap ETA disabled; analytics will compute on demand.
                    return true
                }
            }
        }
        return false
    }

    private func intValue(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Double(s) { return Int(v.rounded()) }
        return nil
    }

    private func makeRateLimitSummary(rate: [String: Any], createdAt: Date, sourceFile: URL) -> RateLimitSummary? {
        let capturedAt = decodeFlexibleDate(rate["captured_at"] as Any?) ?? createdAt
        if capturedAt > Date() { return nil }
        let primary = rate["primary"] as? [String: Any]
        let secondary = rate["secondary"] as? [String: Any]
        let five = decodeWindow(primary, created: createdAt, capturedAt: capturedAt)
        let week = decodeWindow(secondary, created: createdAt, capturedAt: capturedAt)
        let stale = Date().timeIntervalSince(capturedAt) > 3 * 60
        return RateLimitSummary(fiveHour: five, weekly: week, eventTimestamp: capturedAt, stale: stale, sourceFile: sourceFile)
    }

    private func normalizeLimitID(_ any: Any?) -> String? {
        guard let raw = any as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    // MARK: - Flexible date decoding for Codex logs

    private func decodeFlexibleDate(_ any: Any?) -> Date? {
        guard let any = any else { return nil }
        // Numeric epoch seconds/millis/micros
        if let d = any as? Double { return Date(timeIntervalSince1970: normalizeEpochSeconds(d)) }
        if let i = any as? Int { return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(i))) }
        if let s = any as? String {
            // Digits-only string → numeric epoch
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)),
               let val = Double(s) {
                return Date(timeIntervalSince1970: normalizeEpochSeconds(val))
            }
            // ISO8601 with or without fractional seconds
            let iso1 = ISO8601DateFormatter(); iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso1.date(from: s) { return d }
            let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: s) { return d }
            // Common textual fallbacks
            let fmts = [
                "yyyy-MM-dd HH:mm:ssZZZZZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy/MM/dd HH:mm:ssZZZZZ",
                "yyyy/MM/dd HH:mm:ss"
            ]
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
            for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        }
        return nil
    }

    private func normalizeEpochSeconds(_ value: Double) -> Double {
        // Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private func decodeWindow(_ dict: [String: Any]?, created: Date, capturedAt: Date?) -> RateLimitWindowInfo {
        guard let dict else { return RateLimitWindowInfo(remainingPercent: nil, resetAt: nil, windowMinutes: nil) }

        // Parse remaining percentage (post Nov 24, 2025 server-side change)
        var remaining: Int?
        if let d = dict["remaining_percent"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["remaining_percent"] as? Int { remaining = max(0, min(100, i)) }
        else if let n = dict["remaining_percent"] as? NSNumber { remaining = Int(truncating: n) }
        // Alternate naming: pct_left, pct_remaining
        else if let d = dict["pct_left"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["pct_left"] as? Int { remaining = max(0, min(100, i)) }
        else if let d = dict["pct_remaining"] as? Double { remaining = Int(d.rounded()) }
        else if let i = dict["pct_remaining"] as? Int { remaining = max(0, min(100, i)) }
        // Fallback: JSONL still uses used_percent (convert to remaining)
        else if let d = dict["used_percent"] as? Double { remaining = max(0, min(100, 100 - Int(d.rounded()))) }
        else if let i = dict["used_percent"] as? Int { remaining = max(0, min(100, 100 - i)) }
        else if let n = dict["used_percent"] as? NSNumber { remaining = max(0, min(100, 100 - Int(truncating: n))) }

        var resetsVal: Double?
        if let d = dict["resets_in_seconds"] as? Double { resetsVal = d }
        else if let i = dict["resets_in_seconds"] as? Int { resetsVal = Double(i) }
        else if let n = dict["resets_in_seconds"] as? NSNumber { resetsVal = n.doubleValue }

        let minutes = dict["window_minutes"] as? Int

        var resetAt: Date?
        if let delta = resetsVal {
            // New semantics: delta is relative to capturedAt when present
            let base = capturedAt ?? created
            resetAt = base.addingTimeInterval(delta)
        }

        // New format uses absolute epoch under various keys (resets_at / reset_at / resetsAt)
        if resetAt == nil {
            let absoluteKeys = [
                "resets_at",
                "reset_at",
                "resetsAt",
                "resetAt",
                "resets_at_ms",
                "reset_at_ms"
            ]
            for key in absoluteKeys {
                guard let value = dict[key] else { continue }
                if key.hasSuffix("_ms") {
                    if let num = value as? Double {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num))
                        break
                    }
                    if let num = value as? Int {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(Double(num)))
                        break
                    }
                    if let num = value as? NSNumber {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num.doubleValue))
                        break
                    }
                    if let s = value as? String, let num = Double(s) {
                        resetAt = Date(timeIntervalSince1970: normalizeEpochSeconds(num))
                        break
                    }
                } else if let date = decodeFlexibleDate(value) {
                    resetAt = date
                    break
                }
            }
        }

        return RateLimitWindowInfo(remainingPercent: remaining, resetAt: resetAt, windowMinutes: minutes)
    }

    private func tailLines(url: URL, maxBytes: Int) -> [String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let toRead = min(maxBytes, max(0, fileSize))
        let startOffset = UInt64(max(0, fileSize - toRead))
        do { try fh.seek(toOffset: startOffset) } catch { return nil }
        let data = (try? fh.readToEnd()) ?? Data()
        guard !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { if let lastNL = text.lastIndex(of: "\n") { text = String(text[..<lastNL]) } }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    }

    private func stripANSI(_ s: String) -> String {
        var result = s
        // Remove CSI escape sequences: ESC [ ... final byte in @-~
        if let re = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", options: []) {
            result = re.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        // Remove OSC sequences ending with BEL: ESC ] ... BEL
        if let re2 = try? NSRegularExpression(pattern: "\u{001B}\\][^\u{0007}]*\u{0007}", options: []) {
            result = re2.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        return result
    }

    private func terminalPATHCached() -> String? {
        if !hasResolvedTerminalPATH {
            cachedTerminalPATH = Self.resolveTerminalPATHFromLoginShell()
            hasResolvedTerminalPATH = true
        }
        return cachedTerminalPATH
    }

    private func resolveTmuxPathCached() -> String? {
        if !hasResolvedTmuxPath {
            cachedTmuxPath = Self.resolveTmuxPathFromLoginShell()
            hasResolvedTmuxPath = true
        }
        return cachedTmuxPath
    }

    private static func resolveTerminalPATHFromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "echo -n \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitForExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // Strip OSC escapes injected by terminal shell integrations.
        let raw = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    // Resolve tmux path via the user's login shell so GUI-launched app can find Homebrew installs.
    private static func resolveTmuxPathFromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "command -v tmux || true"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitForExit()
        var s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Strip OSC escapes injected by terminal shell integrations.
        s = s.replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
