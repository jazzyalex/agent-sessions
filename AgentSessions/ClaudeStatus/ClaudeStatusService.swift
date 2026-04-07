import Foundation
import Darwin
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Claude Usage Tracking Architecture Documentation
//
// This service implements a two-tier system for tracking Claude CLI rate limit usage:
//
// ## Data Sources (Priority Order)
//
// 1. **PRIMARY: Periodic /usage Probe** (Active)
//    - Uses tmux to run `claude` CLI and send `/usage` command
//    - WARNING: Not guaranteed free. Running Claude Code and invoking `/usage` may
//      generate server requests and may count toward Claude Code usage limits.
//    - Frequency: Every 15 minutes (reduced on battery, disabled when hidden)
//    - Limitation: Requires active polling and launches Claude Code
//    - Note: Unlike Codex, Claude CLI doesn't expose usage logs for passive parsing
//
// 2. **SECONDARY: Hard Probe (Manual)** (Active)
//    - User-triggered via Preferences → Usage Probes → "Refresh Claude usage now"
//    - Always available for on-demand refresh
//    - Returns full diagnostics (success/failure, script output, limits)
//    - Sets 1-hour "freshness" TTL to prevent immediate re-staleness
//
// ## Current Data Model
//
// Stores usage as "percent remaining" (0-100%) to match CLI output format (Nov 24, 2025).
//
// - ClaudeUsageSnapshot.sessionRemainingPercent: Stores "% remaining"
// - ClaudeUsageSnapshot.weekAllModelsRemainingPercent: Stores "% remaining"
// - ClaudeUsageSnapshot.weekOpusRemainingPercent: Stores "% remaining"
// - UI displays use helper methods to convert between used/remaining as needed
//
// Future Work — Quota Tracking:
// - Absolute quota tracking (e.g., "42 of 200 messages remaining")
// - Quota-based feature gating
// - Mobile/team subscription quota display
//
// ## Staleness Semantics
//
// "Stale" means "data is old" NOT "data is inaccurate" (CLI reports fresh server data).
//
// Staleness thresholds (based on last poll time):
// - 5-hour (session) window: 90 minutes since last poll
// - Weekly window: 6 hours since last poll
//
// Staleness triggers:
// - UI display: Shows "Last updated Xh ago" instead of reset time
// - Freshness TTL: Manual probes set 1-hour "fresh" window to smooth UI
//
// Note: Unlike Codex, Claude has no "auto-probe on stale" feature. Polling is continuous
// at configured intervals, or user can manually refresh anytime.
//
// ## Key Files
//
// - ClaudeStatusService.swift (this file): Main service, tmux probe orchestration
// - Resources/claude_usage_capture.sh: Bash script for tmux-based /usage probing
// - ClaudeProbeConfig.swift: Probe session identification logic
// - ClaudeProbeProject.swift: Probe session cleanup/deletion logic
// - UsageStaleCheck.swift: Staleness detection logic (thresholds, poll age)
// - UsageFreshness.swift: Freshness TTL management (1-hour grace period)
//
// Service for fetching Claude CLI usage via headless script execution
actor ClaudeStatusService {
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

    private enum State { case idle, running, stopping }
    private enum TmuxSocketState {
        case stale
        case live
        case unknown
    }
    private static let probeSessionName = "usage"
    private static let probeLabelPrefix = "as-cc-"
    private static let probeLabelLength = 12
    private static let tmuxCleanupPlanner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)
    private static let tmuxCleanupMaxLabelsPerPass = 80
    private static let tmuxCleanupFollowUpDelayNanoseconds: UInt64 = 1_000_000_000
    private static let tmuxCleanupMaxKillAttemptsPerLabel = 2
    private static let tmuxPathCacheTTLSeconds: TimeInterval = 30 * 60
    private static let terminalPathCacheTTLSeconds: TimeInterval = 30 * 60
    private static let defaultScriptBootTimeoutSeconds = 10
    private static let scriptRuntimeBufferSeconds = 18
    private static let minimumScriptRuntimeTimeoutSeconds = 30

    private nonisolated let updateHandler: @Sendable (ClaudeUsageSnapshot) -> Void
    private nonisolated let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void

    private var state: State = .idle
    private var activeProbeLabel: String? = nil
    private var snapshot = ClaudeUsageSnapshot()
    private var hasSnapshot: Bool = false
    private var shouldRun: Bool = true
    private var visible: Bool = false
    private var visibilityContext = VisibilityContext(menuVisible: false, stripVisible: false, appIsActive: false)
    private var visibilityMode: VisibilityMode { visibilityContext.mode }
    private var autoPollingAllowed: Bool {
        switch visibilityMode {
        case .active:
            // Active mode includes strip-visible state while app is foregrounded.
            return visible
        case .menuBackground:
            // Background mode is valid only when the menu tracker for Claude is shown.
            return visible && visibilityContext.menuVisible
        case .hidden:
            return false
        }
    }
    private var refresherTask: Task<Void, Never>?
    private var deferredTmuxCleanupTask: Task<Void, Never>?
    private var tmuxAvailable: Bool = false
    private var claudeAvailable: Bool = false
    private var cachedScriptURL: URL? = nil
    private var unchangedAutoProbeStreak: Int = 0
    private let maxBackoffSeconds: UInt64 = 60 * 60
    private let hiddenIdleIntervalNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000
    private let batteryRecheckIntervalNanoseconds: UInt64 = 30 * 60 * 1_000_000_000
    private var lastOrphanCleanupAt: Date? = nil
    private let orphanCleanupMinInterval: TimeInterval = 3600 // 1 hour
    private var didRunMenuBarOrphanCleanup: Bool = false
    private var tmuxCleanupInProgress: Bool = false
    private var tmuxCleanupFollowUpTask: Task<Void, Never>?
    private var tmuxCleanupPendingLabels: [String] = []
    private var tmuxCleanupPendingProtectedLabels: Set<String> = []
    private var tmuxCleanupNextIndex: Int = 0
    private var tmuxCleanupRetryCounts: [String: Int] = [:]
    private var refresherLoopGeneration: UInt64 = 0
    private var tmuxPathCache: ClaudeTmuxPathCache
    private var terminalPathCache: ClaudeTerminalPathCache
    private var claudeUsageEnabledPreference: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ClaudeUsageEnabled") == nil {
            return defaults.bool(forKey: "ShowClaudeUsageStrip")
        }
        return defaults.bool(forKey: "ClaudeUsageEnabled")
    }

    init(updateHandler: @escaping @Sendable (ClaudeUsageSnapshot) -> Void,
         availabilityHandler: @escaping @Sendable (ClaudeServiceAvailability) -> Void) {
        self.updateHandler = updateHandler
        self.availabilityHandler = availabilityHandler
        self.tmuxPathCache = ClaudeTmuxPathCache(ttlSeconds: Self.tmuxPathCacheTTLSeconds)
        self.terminalPathCache = ClaudeTerminalPathCache(ttlSeconds: Self.terminalPathCacheTTLSeconds)
    }

    static func cleanupOrphansOnLaunch() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.cleanupOrphanedProbeProcesses()
    }

    func start() async {
        guard claudeUsageEnabledPreference else {
            shouldRun = false
            return
        }
        shouldRun = true

        // Check dependencies once at startup
        tmuxAvailable = checkTmuxAvailable()
        claudeAvailable = checkClaudeAvailable()

        let availability = ClaudeServiceAvailability(
            cliUnavailable: !claudeAvailable,
            tmuxUnavailable: !tmuxAvailable
        )
        availabilityHandler(availability)

        guard tmuxAvailable && claudeAvailable else {
            // Don't start refresh loop if dependencies missing
            return
        }

        restartRefresherLoopIfNeeded()
    }

    func stop() async {
        shouldRun = false
        refresherTask?.cancel()
        refresherTask = nil
        refresherLoopGeneration &+= 1
        tmuxCleanupFollowUpTask?.cancel()
        tmuxCleanupFollowUpTask = nil
        if let label = activeProbeLabel {
            await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            activeProbeLabel = nil
        }
        await cleanupOrphanedProbeProcesses()
        await cleanupOrphanedTmuxLabels()
        lastOrphanCleanupAt = nil
        didRunMenuBarOrphanCleanup = false
        if state == .running {
            state = .idle
        }
    }

    func setVisible(_ isVisible: Bool) {
        // Back-compat shim: treat this as in-app visibility while active.
        setVisibility(menuVisible: false, stripVisible: isVisible, appIsActive: true)
    }

    func setVisibility(menuVisible: Bool, stripVisible: Bool, appIsActive: Bool) {
        guard claudeUsageEnabledPreference else {
            visibilityContext = VisibilityContext(menuVisible: false, stripVisible: false, appIsActive: appIsActive)
            visible = false
            restartRefresherLoopIfNeeded()
            return
        }
        let previousContext = visibilityContext
        let previousMode = visibilityMode
        let wasVisible = visible

        visibilityContext = VisibilityContext(menuVisible: menuVisible, stripVisible: stripVisible, appIsActive: appIsActive)
        visible = visibilityContext.effectiveVisible
        let mode = visibilityMode
        let becameActive = (previousMode != .active && mode == .active)
        let becameMenuBackground = (previousMode == .hidden && mode == .menuBackground)
        let menuVisibilityChanged = (previousContext.menuVisible != visibilityContext.menuVisible)

        // Visibility-triggered refreshes are automatic, not user-initiated.
        if becameActive {
            Task { [weak self] in
                guard let self else { return }
                await self.ensureOrphanCleanupIfNeeded()
                await self.refreshTick(userInitiated: false)
            }
        } else if becameMenuBackground {
            Task { [weak self] in
                guard let self else { return }
                await self.ensureMenuBarOrphanCleanupIfNeeded()
                await self.refreshTick(userInitiated: false)
            }
        }
        if wasVisible != visible || previousMode != mode || menuVisibilityChanged {
            restartRefresherLoopIfNeeded()
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            await self.ensureOrphanCleanupIfNeeded()
            await self.refreshTick(userInitiated: true)
        }
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

        let labels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        guard !labels.isEmpty else { return }
        await cleanupOrphanedTmuxLabels()
    }

    // MARK: - Core refresh logic

    private func refreshTick(userInitiated: Bool = false) async {
        guard tmuxAvailable && claudeAvailable else { return }
        if !userInitiated {
            // Auto-probe when a valid Claude usage surface is visible:
            // - active app with strip/menu visibility, or
            // - inactive app with Claude menu tracker visible.
            guard autoPollingAllowed else { return }
            guard Self.onACPower() else { return }
        }
        guard beginProbe() else { return }
        defer { endProbe() }
        defer { _ = ClaudeProbeProject.cleanupNowIfAuto() }
        defer { ClaudeProbeProject.noteProbeRun() }
        do {
            let previousSnapshot: ClaudeUsageSnapshot? = hasSnapshot ? snapshot : nil
            let json = try await executeScript()
            if let parsed = parseUsageJSON(json) {
                snapshot = parsed
                hasSnapshot = true
                if userInitiated {
                    unchangedAutoProbeStreak = 0
                } else {
                    updateBackoffStreak(previous: previousSnapshot, current: parsed)
                }
                updateHandler(snapshot)
            } else {
                #if DEBUG
                print("ClaudeStatusService: Failed to parse JSON: \(json)")
                #endif
            }
        } catch {
            #if DEBUG
            print("ClaudeStatusService: Script execution failed: \(error)")
            #endif
            // Silent failure - keep last known good data
        }
    }

    private func beginProbe() -> Bool {
        if state == .running { return false }
        state = .running
        return true
    }

    private func endProbe() {
        if state == .running { state = .idle }
    }

    private func publishAvailability(loginRequired: Bool,
                                     setupRequired: Bool,
                                     setupHint: String?) {
        let availability = ClaudeServiceAvailability(
            cliUnavailable: !claudeAvailable,
            tmuxUnavailable: !tmuxAvailable,
            loginRequired: loginRequired,
            setupRequired: setupRequired,
            setupHint: setupHint
        )
        availabilityHandler(availability)
    }

    // Hard-probe entry point: force a single /usage probe and return diagnostics.
    func forceProbeNow() async -> ClaudeProbeDiagnostics {
        tmuxAvailable = tmuxAvailable || checkTmuxAvailable()
        guard tmuxAvailable else {
            return ClaudeProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(not run)", workdir: ClaudeProbeConfig.probeWorkingDirectory(), claudeBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "tmux not found")
        }
        claudeAvailable = claudeAvailable || checkClaudeAvailable()
        guard claudeAvailable else {
            return ClaudeProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(not run)", workdir: ClaudeProbeConfig.probeWorkingDirectory(), claudeBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Claude CLI not available")
        }
        let workDir = ClaudeProbeConfig.probeWorkingDirectory()
        guard beginProbe() else {
            return ClaudeProbeDiagnostics(success: false, exitCode: 125, scriptPath: "(not run)", workdir: workDir, claudeBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Probe already running")
        }
        defer { endProbe() }
        defer { _ = ClaudeProbeProject.cleanupNowIfAuto() }
        defer { ClaudeProbeProject.noteProbeRun() }
        guard let scriptURL = prepareScript() else {
            return ClaudeProbeDiagnostics(success: false, exitCode: 127, scriptPath: "(missing)", workdir: workDir, claudeBin: nil, tmuxBin: nil, timeoutSecs: nil, stdout: "", stderr: "Script not found in bundle")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        // Replace minimal GUI PATH with the user's login shell PATH.
        if let terminalPATH = resolveTerminalPATHCached() { env["PATH"] = terminalPATH }
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["MODEL"] = "sonnet"
        env["TIMEOUT_SECS"] = env["TIMEOUT_SECS"] ?? String(Self.defaultScriptBootTimeoutSeconds)
        env["SLEEP_BOOT"] = "0.4"
        env["SLEEP_AFTER_USAGE"] = "2.0"

        let claudeEnv = ClaudeCLIEnvironment()
        let claudeOverride = UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath)
        let claudeBin = claudeEnv.resolveBinary(customPath: claudeOverride)?.path
        if let claudeBin { env["CLAUDE_BIN"] = claudeBin }
        let tmuxBin = resolveTmuxPathCached()
        if let tmuxBin { env["TMUX_BIN"] = tmuxBin }
        let probeLabel = makeProbeLabel()
        env["TMUX_LABEL"] = probeLabel
        activeProbeLabel = probeLabel
        defer { activeProbeLabel = nil }

        process.environment = env
        let timeoutValue = Int(env["TIMEOUT_SECS"] ?? "") ?? Self.defaultScriptBootTimeoutSeconds
        let scriptTimeoutSeconds = max(Self.minimumScriptRuntimeTimeoutSeconds, timeoutValue + Self.scriptRuntimeBufferSeconds)
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do {
            try process.run()
        } catch {
            return ClaudeProbeDiagnostics(success: false, exitCode: 127, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: "", stderr: error.localizedDescription)
        }
        let didExit = await waitForProcessExit(process, timeoutSeconds: scriptTimeoutSeconds, label: probeLabel, session: Self.probeSessionName)
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !didExit {
            return ClaudeProbeDiagnostics(success: false, exitCode: 124, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr.isEmpty ? "Script timed out" : stderr)
        }
        deferredTmuxCleanupTask?.cancel()
        deferredTmuxCleanupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return } // 2s grace for shell trap
            await self?.cleanupOrphanedTmuxLabels()
        }
	        if process.terminationStatus == 0 {
	            if let parsed = parseUsageJSON(stdout) {
	                snapshot = parsed
	                hasSnapshot = true
	                updateHandler(snapshot)
	            }
	            publishAvailability(loginRequired: false, setupRequired: false, setupHint: nil)
	            return ClaudeProbeDiagnostics(success: true, exitCode: 0, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
	        } else {
            if process.terminationStatus == 13 {
                publishAvailability(loginRequired: true, setupRequired: false, setupHint: nil)
            } else if let hint = detectSetupRequiredHint(stdout: stdout, stderr: stderr) {
                publishAvailability(loginRequired: false, setupRequired: true, setupHint: hint)
            }
            return ClaudeProbeDiagnostics(success: false, exitCode: process.terminationStatus, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr)
        }
    }

    private func executeScript() async throws -> String {
        guard let scriptURL = prepareScript() else {
            throw ClaudeServiceError.scriptNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        // Set environment for script
        var env = ProcessInfo.processInfo.environment
        // Replace minimal GUI PATH with the user's login shell PATH.
        if let terminalPATH = resolveTerminalPATHCached() { env["PATH"] = terminalPATH }
        // Use stable probe working directory so Claude maps all probes to one project
        let workDir = ClaudeProbeConfig.probeWorkingDirectory()
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["MODEL"] = "sonnet"
        env["TIMEOUT_SECS"] = env["TIMEOUT_SECS"] ?? String(Self.defaultScriptBootTimeoutSeconds)
        env["SLEEP_BOOT"] = "0.4"
        env["SLEEP_AFTER_USAGE"] = "2.0"

        // Use real HOME for auth credentials (temp WORKDIR prevents file access prompts)
        // No CLAUDE_HOME override - let it use real ~/.claude/ with credentials

        // Pass resolved Claude binary path (same logic as resume)
        let claudeEnv = ClaudeCLIEnvironment()
        let claudeOverride = UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath)
        if let claudeBin = claudeEnv.resolveBinary(customPath: claudeOverride) {
            env["CLAUDE_BIN"] = claudeBin.path
        }

        // Pass resolved tmux path
        if let tmuxPath = resolveTmuxPathCached() {
            env["TMUX_BIN"] = tmuxPath
        }
        let probeLabel = makeProbeLabel()
        env["TMUX_LABEL"] = probeLabel
        activeProbeLabel = probeLabel
        defer { activeProbeLabel = nil }

        #if DEBUG
        print("ClaudeStatusService: Executing script with WORKDIR=\(workDir), CLAUDE_BIN=\(env["CLAUDE_BIN"] ?? "not set"), TMUX_BIN=\(env["TMUX_BIN"] ?? "not set")")
        #endif

        process.environment = env
        let timeoutValue = Int(env["TIMEOUT_SECS"] ?? "") ?? Self.defaultScriptBootTimeoutSeconds
        let scriptTimeoutSeconds = max(Self.minimumScriptRuntimeTimeoutSeconds, timeoutValue + Self.scriptRuntimeBufferSeconds)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let didExit = await waitForProcessExit(process, timeoutSeconds: scriptTimeoutSeconds, label: probeLabel, session: Self.probeSessionName)
        if !didExit {
            #if DEBUG
            print("ClaudeStatusService: Script timed out after \(scriptTimeoutSeconds)s, terminating")
            #endif
            throw ClaudeServiceError.scriptFailed(exitCode: 124, output: "Script timed out")
        }
        deferredTmuxCleanupTask?.cancel()
        deferredTmuxCleanupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return } // 2s grace for shell trap
            await self?.cleanupOrphanedTmuxLabels()
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        #if DEBUG
        if !errorOutput.isEmpty {
            print("ClaudeStatusService: Script stderr: \(errorOutput)")
        }
        #endif

        // Check exit code
        let exitCode = process.terminationStatus
        if exitCode == 0 {
            // Clear transient availability warnings on success.
            publishAvailability(loginRequired: false, setupRequired: false, setupHint: nil)
            return output
        } else if exitCode == 13 {
            // Auth/login required - notify UI
            publishAvailability(loginRequired: true, setupRequired: false, setupHint: nil)
            throw ClaudeServiceError.loginRequired
        } else if let hint = detectSetupRequiredHint(stdout: output, stderr: errorOutput) {
            publishAvailability(loginRequired: false, setupRequired: true, setupHint: hint)
            throw ClaudeServiceError.setupRequired
        } else {
            // Script returned error JSON
            throw ClaudeServiceError.scriptFailed(exitCode: Int(exitCode), output: output)
        }
    }

    private func waitForProcessExit(_ process: Process,
                                    timeoutSeconds: Int,
                                    label: String,
                                    session: String) async -> Bool {
        let maxIterations = max(1, timeoutSeconds * 2) // 0.5s ticks
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
        let workDir = ClaudeProbeConfig.probeWorkingDirectory()
        let markers = workDirMarkers(workDir)
        let snapshot = await runProcess(executable: "/bin/ps",
                                        arguments: ["-A", "-o", "pid=", "-o", "command="],
                                        timeoutSeconds: 2)
        guard !snapshot.stdout.isEmpty else {
            await cleanupOrphanedTmuxLabels()
            return
        }
        var protectedLabels = Set<String>()
        var pids: [pid_t] = []
        for line in snapshot.stdout.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let splitIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidString = String(trimmed[..<splitIndex])
            let command = String(trimmed[splitIndex...]).trimmingCharacters(in: .whitespaces)
            guard let pidValue = Int32(pidString) else { continue }
            let lowerCommand = command.lowercased()
            guard lowerCommand.contains("claude") else { continue }
            if lowerCommand.contains("claude_usage_") { continue }
            let envSnapshot = await runProcess(executable: "/bin/ps",
                                               arguments: ["eww", "-p", pidString],
                                               timeoutSeconds: 2)
            let envLine = envSnapshot.stdout
            guard !envLine.isEmpty else { continue }
            guard envLine.contains("__CFBundleIdentifier=com.triada.AgentSessions") else { continue }
            guard markers.contains(where: { envLine.contains($0) }) else { continue }
            pids.append(pid_t(pidValue))
            if let label = extractTmuxLabel(from: envLine, expectedPrefix: Self.probeLabelPrefix) {
                protectedLabels.insert(label)
            }
        }
        // Secondary: find claude processes whose CWD matches the probe working directory.
        // The ps-eww check above misses processes inside tmux (no inherited env markers).
        // "-c claude" is a prefix match and may capture unrelated processes (e.g. claude-something),
        // but the CWD equality check below provides a sufficient safety filter.
        let lsofResult = await runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["-w", "-a", "-c", "claude", "-d", "cwd", "-nP", "-F", "pn"],
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
        let scannedLabels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        enqueueTmuxCleanup(labels: scannedLabels.union(protectedLabels), protectedLabels: protectedLabels)
        if tmuxCleanupInProgress {
            scheduleDeferredTmuxCleanupPass()
        } else {
            tmuxCleanupInProgress = true
            let hasMoreLabels = await runQueuedTmuxCleanupPass()
            tmuxCleanupInProgress = false
            if hasMoreLabels {
                scheduleDeferredTmuxCleanupPass()
            } else {
                tmuxCleanupFollowUpTask?.cancel()
                tmuxCleanupFollowUpTask = nil
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

        // Labels discovered on live orphan processes are protected during PID shutdown.
        // After termination, unprotect and requeue so kill-server runs in this cycle.
        guard !protectedLabels.isEmpty else { return }
        tmuxCleanupPendingProtectedLabels.subtract(protectedLabels)
        let rescannedLabels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        enqueueTmuxCleanup(labels: rescannedLabels.union(protectedLabels), protectedLabels: [])
        if tmuxCleanupInProgress {
            scheduleDeferredTmuxCleanupPass()
        } else {
            tmuxCleanupInProgress = true
            let hasMoreLabels = await runQueuedTmuxCleanupPass()
            tmuxCleanupInProgress = false
            if hasMoreLabels {
                scheduleDeferredTmuxCleanupPass()
            } else {
                tmuxCleanupFollowUpTask?.cancel()
                tmuxCleanupFollowUpTask = nil
            }
        }
    }

    private func cleanupOrphanedTmuxLabels() async {
        guard !tmuxCleanupInProgress else { return }
        if tmuxCleanupQueueNeedsRefill {
            enqueueTmuxCleanup(labels: scanTmuxLabels(prefix: Self.probeLabelPrefix), protectedLabels: [])
        }
        guard !tmuxCleanupPendingLabels.isEmpty else {
            clearTmuxCleanupQueue()
            return
        }
        tmuxCleanupInProgress = true
        let hasMoreLabels = await runQueuedTmuxCleanupPass()
        tmuxCleanupInProgress = false
        if hasMoreLabels {
            scheduleDeferredTmuxCleanupPass()
        } else {
            tmuxCleanupFollowUpTask?.cancel()
            tmuxCleanupFollowUpTask = nil
        }
    }

    private func extractTmuxLabel(from command: String, expectedPrefix: String) -> String? {
        guard let range = command.range(of: "TMUX=") else { return nil }
        let after = command[range.upperBound...]
        let end = after.firstIndex(where: { $0.isWhitespace }) ?? after.endIndex
        let value = String(after[..<end])
        let socketPath = value.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first
        guard let socketPath else { return nil }
        let label = (String(socketPath) as NSString).lastPathComponent
        guard label.hasPrefix(expectedPrefix) else { return nil }
        return Self.tmuxCleanupPlanner.isManagedProbeLabel(label) ? label : nil
    }

    private func scheduleDeferredTmuxCleanupPass() {
        tmuxCleanupFollowUpTask?.cancel()
        tmuxCleanupFollowUpTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.tmuxCleanupFollowUpDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.cleanupOrphanedTmuxLabels()
        }
    }

    private var tmuxCleanupQueueNeedsRefill: Bool {
        tmuxCleanupPendingLabels.isEmpty || tmuxCleanupNextIndex >= tmuxCleanupPendingLabels.count
    }

    private func enqueueTmuxCleanup(labels: Set<String>, protectedLabels: Set<String>) {
        let validProtected = Set(protectedLabels.filter { Self.tmuxCleanupPlanner.isManagedProbeLabel($0) })
        tmuxCleanupPendingProtectedLabels.formUnion(validProtected)

        let candidateQueue = Self.tmuxCleanupPlanner.plannedQueue(
            allLabels: labels,
            protectedLabels: tmuxCleanupPendingProtectedLabels,
            activeLabel: activeProbeLabel
        )
        guard !candidateQueue.isEmpty else {
            if tmuxCleanupQueueNeedsRefill {
                clearTmuxCleanupQueue()
            }
            return
        }

        if tmuxCleanupQueueNeedsRefill {
            tmuxCleanupPendingLabels = candidateQueue
            tmuxCleanupNextIndex = 0
            tmuxCleanupRetryCounts = tmuxCleanupRetryCounts.filter { tmuxCleanupPendingLabels.contains($0.key) }
            return
        }

        let existing = Set(tmuxCleanupPendingLabels[tmuxCleanupNextIndex...])
        let merged = Self.tmuxCleanupPlanner.plannedQueue(
            allLabels: existing.union(candidateQueue),
            protectedLabels: tmuxCleanupPendingProtectedLabels,
            activeLabel: activeProbeLabel
        )
        tmuxCleanupPendingLabels = merged
        tmuxCleanupNextIndex = 0
        tmuxCleanupRetryCounts = tmuxCleanupRetryCounts.filter { tmuxCleanupPendingLabels.contains($0.key) }
    }

    private func clearTmuxCleanupQueue() {
        tmuxCleanupPendingLabels.removeAll(keepingCapacity: false)
        tmuxCleanupPendingProtectedLabels.removeAll(keepingCapacity: false)
        tmuxCleanupNextIndex = 0
        tmuxCleanupRetryCounts.removeAll(keepingCapacity: false)
    }

    private func runQueuedTmuxCleanupPass() async -> Bool {
        guard tmuxCleanupNextIndex < tmuxCleanupPendingLabels.count else {
            clearTmuxCleanupQueue()
            return false
        }

        let start = tmuxCleanupNextIndex
        let end = min(start + Self.tmuxCleanupMaxLabelsPerPass, tmuxCleanupPendingLabels.count)
        let batch = tmuxCleanupPendingLabels[start..<end]
        var removed = 0
        var staleRemoved = 0
        var skipped = 0
        var liveCandidates: [String] = []
        liveCandidates.reserveCapacity(batch.count)

        for label in batch {
            if label == activeProbeLabel || tmuxCleanupPendingProtectedLabels.contains(label) {
                skipped += 1
                continue
            }
            if (tmuxCleanupRetryCounts[label] ?? 0) >= Self.tmuxCleanupMaxKillAttemptsPerLabel {
                skipped += 1
                continue
            }
            let socketState = tmuxSocketState(for: label)
            switch socketState {
            case .stale:
                removeTmuxSocketFiles(label: label)
                tmuxCleanupRetryCounts.removeValue(forKey: label)
                staleRemoved += 1
            case .live, .unknown:
                liveCandidates.append(label)
            }
        }

        var invalidPath = false

        if !liveCandidates.isEmpty {
            guard let tmuxPath = resolveTmuxPathCached() else {
                #if DEBUG
                print("ClaudeStatusService: tmux cleanup skipped; tmux path unavailable")
                #endif
                clearTmuxCleanupQueue()
                return false
            }
            for label in liveCandidates {
                let result = await runProcess(executable: tmuxPath,
                                              arguments: ["-L", label, "kill-server"],
                                              timeoutSeconds: 1)
                if result.status == 127 {
                    invalidPath = true
                    break
                }
                if result.status == 0 {
                    removeTmuxSocketFiles(label: label)
                    tmuxCleanupRetryCounts.removeValue(forKey: label)
                    removed += 1
                    continue
                }
                if tmuxSocketState(for: label) == .stale {
                    removeTmuxSocketFiles(label: label)
                    tmuxCleanupRetryCounts.removeValue(forKey: label)
                    staleRemoved += 1
                    continue
                }
                let fallbackPIDs = managedProbePIDs(for: label)
                if !fallbackPIDs.isEmpty {
                    for pid in fallbackPIDs {
                        await terminateProcessGroup(pid: pid)
                    }
                    if tmuxSocketState(for: label) != .live {
                        removeTmuxSocketFiles(label: label)
                        tmuxCleanupRetryCounts.removeValue(forKey: label)
                        staleRemoved += 1
                        continue
                    }
                }
                tmuxCleanupRetryCounts[label, default: 0] += 1
                skipped += 1
            }
        }

        if invalidPath {
            invalidateTmuxPathCache()
            #if DEBUG
            print("ClaudeStatusService: tmux cleanup invalidated cached tmux path after status=127")
            #endif
            clearTmuxCleanupQueue()
            return false
        }

        tmuxCleanupNextIndex = end
        let remaining = max(0, tmuxCleanupPendingLabels.count - tmuxCleanupNextIndex)
        #if DEBUG
        print("ClaudeStatusService: tmux cleanup pass processed=\(batch.count) liveCandidates=\(liveCandidates.count) removed=\(removed) staleRemoved=\(staleRemoved) skipped=\(skipped) remaining=\(remaining)")
        #endif
        if remaining == 0 {
            clearTmuxCleanupQueue()
            return false
        }
        return true
    }

    private func managedProbePIDs(for label: String) -> [pid_t] {
        let snapshot = scanProcessSnapshot()
        return Self.parseManagedProbePIDs(
            from: snapshot,
            label: label,
            uid: getuid()
        )
    }

    nonisolated static func parseManagedProbePIDs(from processSnapshot: String,
                                                  label: String,
                                                  uid: uid_t) -> [pid_t] {
        guard tmuxCleanupPlanner.isManagedProbeLabel(label) else { return [] }
        guard !processSnapshot.isEmpty else { return [] }
        var pids: [pid_t] = []
        let socketMarkers = tmuxCleanupPlanner.socketPaths(uid: uid, label: label)
        for line in processSnapshot.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let splitIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidString = String(trimmed[..<splitIndex])
            let command = String(trimmed[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pidValue = Int32(pidString) else { continue }
            let commandTokens = command.split(separator: " ").map(String.init)
            let isManagedTmux =
                commandTokens.contains(where: { ($0 as NSString).lastPathComponent == "tmux" }) &&
                command.contains(" -L \(label) ")
            let isManagedClaudeProbe =
                command.contains("claude --model sonnet") &&
                socketMarkers.contains(where: { command.contains($0) })
            if isManagedTmux || isManagedClaudeProbe {
                pids.append(pid_t(pidValue))
            }
        }
        return Array(Set(pids)).sorted()
    }

    private func scanProcessSnapshot() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid=", "-o", "command="]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return ""
        }
        task.waitForExit()
        guard task.terminationStatus == 0 else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func workDirMarkers(_ workDir: String) -> [String] {
        let escaped = workDir.replacingOccurrences(of: " ", with: "\\ ")
        if escaped == workDir {
            return ["WORKDIR=\(workDir)"]
        }
        return ["WORKDIR=\(workDir)", "WORKDIR=\(escaped)"]
    }

    private func scanTmuxLabels(prefix: String) -> Set<String> {
        let roots = Self.tmuxSocketRoots(uid: getuid())
        var labels = Set<String>()
        let fm = FileManager.default
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let contents = try? fm.contentsOfDirectory(at: rootURL,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for entry in contents {
                let name = entry.lastPathComponent
                if name.hasPrefix(prefix), Self.tmuxCleanupPlanner.isManagedProbeLabel(name) {
                    labels.insert(name)
                }
            }
        }
        return labels
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
        removeTmuxSocketFiles(label: label)
    }

    private func removeTmuxSocketFiles(label: String) {
        guard Self.tmuxCleanupPlanner.isManagedProbeLabel(label) else { return }
        let fm = FileManager.default
        for path in Self.tmuxCleanupPlanner.socketPaths(uid: getuid(), label: label) {
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private static func tmuxSocketRoots(uid: uid_t) -> [String] {
        ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
    }

    private func tmuxSocketState(for label: String) -> TmuxSocketState {
        let paths = Self.tmuxCleanupPlanner.socketPaths(uid: getuid(), label: label)
        guard !paths.isEmpty else { return .unknown }
        var foundSocketPath = false
        var sawUnknown = false

        for path in paths {
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else { continue }
            foundSocketPath = true
            if (metadata.st_mode & S_IFMT) != S_IFSOCK {
                return .stale
            }
            switch tmuxSocketConnectionState(path: path) {
            case .live:
                return .live
            case .stale:
                continue
            case .unknown:
                sawUnknown = true
            }
        }

        // If no socket exists in the default roots, the tmux server may still be alive
        // under a nonstandard TMUX_TMPDIR. Treat as unknown so cleanup attempts kill-server.
        guard foundSocketPath else { return .unknown }
        return sawUnknown ? .unknown : .stale
    }

    private func tmuxSocketConnectionState(path: String) -> TmuxSocketState {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { _ = Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif

        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .unknown
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            guard let cBuffer = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            for (index, value) in bytes.enumerated() {
                cBuffer[index] = value
            }
        }

        var mutableAddress = address
        let result = withUnsafePointer(to: &mutableAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result == 0 {
            return .live
        }
        switch errno {
        case ECONNREFUSED, ENOENT, ENOTSOCK:
            return .stale
        default:
            return .unknown
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

    private struct ScriptErrorPayload {
        let error: String
        let hint: String?
    }

    private func parseScriptErrorPayload(_ stdout: String) -> ScriptErrorPayload? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["ok"] as? Bool) == false, let error = obj["error"] as? String else { return nil }
        let hint = obj["hint"] as? String
        return ScriptErrorPayload(error: error, hint: hint)
    }

    private func detectSetupRequiredHint(stdout: String, stderr: String) -> String? {
        if let payload = parseScriptErrorPayload(stdout), payload.error == "manual_setup_required" {
            return payload.hint ?? "Claude Code needs one-time setup. Open Terminal and run: claude"
        }
        // Backstop for older scripts: the terms prompt can cause a boot timeout.
        let stderrLower = stderr.lowercased()
        if stderrLower.contains("please select how you'd like to continue") || stderrLower.contains("help improve claude") {
            return "Claude Code needs one-time setup. Open Terminal and run: claude"
        }
        return nil
    }

    private func prepareScript() -> URL? {
        guard let bundledScript = Bundle.main.url(forResource: "claude_usage_capture", withExtension: "sh") else {
            return nil
        }

        if let cachedScriptURL, FileManager.default.fileExists(atPath: cachedScriptURL.path) {
            return cachedScriptURL
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
        let tempScript = tempDir.appendingPathComponent("claude_usage_capture.sh")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: tempScript)
            try FileManager.default.copyItem(at: bundledScript, to: tempScript)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempScript.path
            )
            cachedScriptURL = tempScript
            return tempScript
        } catch {
            return nil
        }
    }

    private func parseUsageJSON(_ json: String) -> ClaudeUsageSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }

        do {
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let obj else { return nil }

            // Check if error response
            if let ok = obj["ok"] as? Bool, !ok {
                return nil
            }

            // Parse successful response
            var snapshot = ClaudeUsageSnapshot()

            if let session = obj["session_5h"] as? [String: Any] {
                snapshot.sessionRemainingPercent = session["pct_left"] as? Int ?? 0
                snapshot.sessionResetText = formatResetTime(session["resets"] as? String ?? "", isWeekly: false)
            }

            if let weekAll = obj["week_all_models"] as? [String: Any] {
                snapshot.weekAllModelsRemainingPercent = weekAll["pct_left"] as? Int ?? 0
                snapshot.weekAllModelsResetText = formatResetTime(weekAll["resets"] as? String ?? "", isWeekly: true)
            }

            if let weekOpus = obj["week_opus"] as? [String: Any] {
                snapshot.weekOpusRemainingPercent = weekOpus["pct_left"] as? Int
                snapshot.weekOpusResetText = (weekOpus["resets"] as? String).map { formatResetTime($0, isWeekly: true) }
            }

            return snapshot
        } catch {
            return nil
        }
    }

    private func formatResetTime(_ text: String, isWeekly: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let kind = isWeekly ? "Wk" : "5h"
        return UsageResetText.displayTextWithPrefix(kind: kind, source: .claude, raw: text)
    }

    private func nextInterval() -> UInt64 {
        // Read Claude-specific polling interval (defaults to 900s = 15 min)
        let userInterval = UInt64(UserDefaults.standard.object(forKey: "ClaudePollingInterval") as? Int ?? 900)

        // Strict policy: auto polling is idle when no valid usage surface is visible.
        if !autoPollingAllowed {
            return hiddenIdleIntervalNanoseconds
        }

        // Automatic background probing is AC-only.
        if !Self.onACPower() {
            return batteryRecheckIntervalNanoseconds
        }

        let clampedBase = max(UInt64(60), userInterval)
        let multiplier: UInt64
        switch unchangedAutoProbeStreak {
        case 0:
            multiplier = 1
        case 1:
            multiplier = 2
        default:
            multiplier = 4
        }
        let backedOffSeconds = min(maxBackoffSeconds, clampedBase * multiplier)
        return jitteredIntervalNanoseconds(baseSeconds: backedOffSeconds)
    }

    private func updateBackoffStreak(previous: ClaudeUsageSnapshot?, current: ClaudeUsageSnapshot) {
        guard let previous else {
            unchangedAutoProbeStreak = 0
            return
        }

        let unchanged =
            previous.sessionRemainingPercent == current.sessionRemainingPercent &&
            previous.sessionResetText == current.sessionResetText &&
            previous.weekAllModelsRemainingPercent == current.weekAllModelsRemainingPercent &&
            previous.weekAllModelsResetText == current.weekAllModelsResetText &&
            previous.weekOpusRemainingPercent == current.weekOpusRemainingPercent &&
            previous.weekOpusResetText == current.weekOpusResetText

        if unchanged {
            unchangedAutoProbeStreak = min(unchangedAutoProbeStreak + 1, 6)
        } else {
            unchangedAutoProbeStreak = 0
        }
    }

    private func jitteredIntervalNanoseconds(baseSeconds: UInt64) -> UInt64 {
        let maxJitterByRatio = UInt64(Double(baseSeconds) * 0.15)
        let maxJitterSeconds = min(UInt64(120), maxJitterByRatio)
        guard maxJitterSeconds > 0 else {
            return baseSeconds * 1_000_000_000
        }
        let jitter = Int64.random(in: -Int64(maxJitterSeconds)...Int64(maxJitterSeconds))
        let jitteredSeconds = max(1, Int64(baseSeconds) + jitter)
        return UInt64(jitteredSeconds) * 1_000_000_000
    }

    private func restartRefresherLoopIfNeeded() {
        refresherTask?.cancel()
        refresherTask = nil
        refresherLoopGeneration &+= 1
        let generation = refresherLoopGeneration

        // Auto probes run only when polling is allowed for the current visibility state.
        guard shouldRun, tmuxAvailable, claudeAvailable, autoPollingAllowed else {
            return
        }

        refresherTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if await self.refresherLoopGeneration != generation { break }
                if !(await self.shouldRun) { break }
                await self.refreshTick()
                if Task.isCancelled { break }
                if await self.refresherLoopGeneration != generation { break }
                let interval = await self.nextInterval()
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - Dependency checks

    private func checkTmuxAvailable() -> Bool {
        // Check via login shell to get user's full PATH (mirrors Terminal)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v tmux || true"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitForExit()
            var output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Strip OSC escapes injected by terminal shell integrations.
            output = output.replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func checkClaudeAvailable() -> Bool {
        // Use same resolution logic as resume functionality
        let env = ClaudeCLIEnvironment()
        let claudeOverride = UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath)
        return env.resolveBinary(customPath: claudeOverride) != nil
    }

    private func resolveTmuxPathCached(forceRefresh: Bool = false) -> String? {
        tmuxPathCache.resolve(at: Date(), forceRefresh: forceRefresh) { [self] in
            resolveTmuxPathViaLoginShell()
        }
    }

    private func invalidateTmuxPathCache() {
        tmuxPathCache.invalidate()
    }

    private func resolveTmuxPathViaLoginShell() -> String? {
        // Check via login shell to get full PATH
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v tmux || true"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitForExit()
            var output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Strip OSC escapes injected by terminal shell integrations.
            output = output.replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private func resolveTerminalPATHCached(forceRefresh: Bool = false) -> String? {
        terminalPathCache.resolve(at: Date(), forceRefresh: forceRefresh) { [self] in
            resolveTerminalPATHViaLoginShell()
        }
    }

    private func resolveTerminalPATHViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let startMarker = "__AS_PATH_BEGIN__"
        let endMarker = "__AS_PATH_END__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Use markers so startup noise on stdout cannot corrupt extracted PATH.
        process.arguments = ["-lic", "printf '\(startMarker)%s\(endMarker)' \"$PATH\""]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitForExit()
            guard process.terminationStatus == 0 else { return nil }
            var output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Strip OSC escapes injected by terminal shell integrations.
            output = output.replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            guard let startRange = output.range(of: startMarker),
                  let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
            else {
                return nil
            }
            let path = output[startRange.upperBound..<endRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
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
}

struct ClaudeTmuxPathCache {
    let ttlSeconds: TimeInterval
    private(set) var cachedPath: String?
    private(set) var resolvedAt: Date?

    init(ttlSeconds: TimeInterval) {
        self.ttlSeconds = ttlSeconds
    }

    mutating func resolve(at now: Date,
                          forceRefresh: Bool = false,
                          resolver: () -> String?) -> String? {
        if !forceRefresh,
           let cachedPath,
           let resolvedAt,
           now.timeIntervalSince(resolvedAt) < ttlSeconds {
            return cachedPath
        }
        guard let resolved = resolver() else {
            return cachedPath
        }
        cachedPath = resolved
        resolvedAt = now
        return resolved
    }

    mutating func invalidate() {
        cachedPath = nil
        resolvedAt = nil
    }
}

struct ClaudeTerminalPathCache {
    let ttlSeconds: TimeInterval
    private(set) var cachedPath: String?
    private(set) var resolvedAt: Date?

    init(ttlSeconds: TimeInterval) {
        self.ttlSeconds = ttlSeconds
    }

    mutating func resolve(at now: Date,
                          forceRefresh: Bool = false,
                          resolver: () -> String?) -> String? {
        if !forceRefresh,
           let cachedPath,
           let resolvedAt,
           now.timeIntervalSince(resolvedAt) < ttlSeconds {
            return cachedPath
        }
        guard let resolved = resolver() else {
            return cachedPath
        }
        cachedPath = resolved
        resolvedAt = now
        return resolved
    }

    mutating func invalidate() {
        cachedPath = nil
        resolvedAt = nil
    }
}

struct ClaudeTmuxCleanupPlanner {
    let prefix: String
    let tokenLength: Int

    func isManagedProbeLabel(_ label: String) -> Bool {
        guard label.hasPrefix(prefix) else { return false }
        let suffix = String(label.dropFirst(prefix.count))
        guard suffix.count == tokenLength else { return false }
        guard let first = suffix.first, first.isASCIIAlpha else { return false }
        guard let last = suffix.last, last.isASCIIDigit else { return false }
        return suffix.allSatisfy { $0.isASCIIAlphaNumeric }
    }

    func plannedQueue(allLabels: Set<String>,
                      protectedLabels: Set<String>,
                      activeLabel: String?) -> [String] {
        allLabels
            .filter { isManagedProbeLabel($0) }
            .filter { !protectedLabels.contains($0) }
            .filter { $0 != activeLabel }
            .sorted()
    }

    func socketPaths(uid: uid_t, label: String) -> [String] {
        guard isManagedProbeLabel(label) else { return [] }
        return ["/private/tmp/tmux-\(uid)/\(label)", "/tmp/tmux-\(uid)/\(label)"]
    }
}

private extension Character {
    var isASCIIAlpha: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { scalar in
            (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
        } == true
    }

    var isASCIIDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { scalar in
            scalar.value >= 48 && scalar.value <= 57
        } == true
    }

    var isASCIIAlphaNumeric: Bool {
        isASCIIAlpha || isASCIIDigit
    }
}

struct ClaudeProbeDiagnostics {
    let success: Bool
    let exitCode: Int32
    let scriptPath: String
    let workdir: String
    let claudeBin: String?
    let tmuxBin: String?
    let timeoutSecs: String?
    let stdout: String
    let stderr: String
}

enum ClaudeServiceError: Error {
    case scriptNotFound
    case scriptFailed(exitCode: Int, output: String)
    case loginRequired
    case setupRequired
}
