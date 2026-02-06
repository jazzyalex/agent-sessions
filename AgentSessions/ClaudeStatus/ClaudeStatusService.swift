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
// TODO (Future Work - Quota Tracking):
// - Add absolute quota tracking (e.g., "42 of 200 messages remaining")
// - Implement quota-based feature gating if needed
// - Support mobile/team subscription quota display
// - See original plan step 7 for detailed requirements
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
    private enum State { case idle, running, stopping }
    private static let probeSessionName = "usage"
    private static let probeLabelPrefix = "as-cc-"
    private static let probeLabelLength = 12

    private nonisolated let updateHandler: @Sendable (ClaudeUsageSnapshot) -> Void
    private nonisolated let availabilityHandler: @Sendable (ClaudeServiceAvailability) -> Void

    private var state: State = .idle
    private var activeProbeLabel: String? = nil
    private var snapshot = ClaudeUsageSnapshot()
    private var hasSnapshot: Bool = false
    private var shouldRun: Bool = true
    private var visible: Bool = false
    private var refresherTask: Task<Void, Never>?
    private var tmuxAvailable: Bool = false
    private var claudeAvailable: Bool = false
    private var cachedScriptURL: URL? = nil

    init(updateHandler: @escaping @Sendable (ClaudeUsageSnapshot) -> Void,
         availabilityHandler: @escaping @Sendable (ClaudeServiceAvailability) -> Void) {
        self.updateHandler = updateHandler
        self.availabilityHandler = availabilityHandler
    }

    static func cleanupOrphansOnLaunch() async {
        let service = ClaudeStatusService(updateHandler: { _ in }, availabilityHandler: { _ in })
        await service.cleanupOrphanedProbeProcesses()
    }

    func start() async {
        shouldRun = true

        // Check dependencies once at startup
        tmuxAvailable = checkTmuxAvailable()
        claudeAvailable = checkClaudeAvailable()

        let availability = ClaudeServiceAvailability(
            cliUnavailable: !claudeAvailable,
            tmuxUnavailable: !tmuxAvailable
        )
        availabilityHandler(availability)

        await cleanupOrphanedProbeProcesses()

        guard tmuxAvailable && claudeAvailable else {
            // Don't start refresh loop if dependencies missing
            return
        }

        refresherTask?.cancel()
        refresherTask = Task { [weak self] in
            guard let self else { return }
            while await self.shouldRun {
                await self.refreshTick()
                let interval = await self.nextInterval()
                try? await Task.sleep(nanoseconds: interval)
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
        if state == .running {
            state = .idle
        }
    }

    func setVisible(_ isVisible: Bool) {
        let wasVisible = visible
        visible = isVisible

        // Visibility-triggered refreshes are automatic, not user-initiated.
        if !wasVisible && isVisible {
            Task { await self.refreshTick(userInitiated: false) }
        }
    }

    func refreshNow() {
        Task { await self.refreshTick(userInitiated: true) }
    }

    // MARK: - Core refresh logic

    private func refreshTick(userInitiated: Bool = false) async {
        guard tmuxAvailable && claudeAvailable else { return }
        if !userInitiated {
            guard Self.onACPower() else { return }
            let urgent = hasSnapshot && snapshot.sessionPercentUsed() >= 80
            guard visible || urgent else { return }
        }
        guard beginProbe() else { return }
        defer { endProbe() }
        defer { _ = ClaudeProbeProject.cleanupNowIfAuto() }
        defer { ClaudeProbeProject.noteProbeRun() }
        do {
            let json = try await executeScript()
            if let parsed = parseUsageJSON(json) {
                snapshot = parsed
                hasSnapshot = true
                updateHandler(snapshot)
            } else {
                print("ClaudeStatusService: Failed to parse JSON: \(json)")
            }
        } catch {
            print("ClaudeStatusService: Script execution failed: \(error)")
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
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["MODEL"] = "sonnet"
        env["TIMEOUT_SECS"] = "10"
        env["SLEEP_BOOT"] = "0.4"
        env["SLEEP_AFTER_USAGE"] = "2.0"

        let claudeEnv = ClaudeCLIEnvironment()
        let claudeBin = claudeEnv.resolveBinary(customPath: nil)?.path
        if let claudeBin { env["CLAUDE_BIN"] = claudeBin }
        let tmuxBin = resolveTmuxPath()
        if let tmuxBin { env["TMUX_BIN"] = tmuxBin }
        let probeLabel = makeProbeLabel()
        env["TMUX_LABEL"] = probeLabel
        activeProbeLabel = probeLabel
        defer { activeProbeLabel = nil }

        process.environment = env
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        do {
            try process.run()
        } catch {
            return ClaudeProbeDiagnostics(success: false, exitCode: 127, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: "", stderr: error.localizedDescription)
        }
        let didExit = await waitForProcessExit(process, timeoutSeconds: 20, label: probeLabel, session: Self.probeSessionName)
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !didExit {
            return ClaudeProbeDiagnostics(success: false, exitCode: 124, scriptPath: scriptURL.path, workdir: workDir, claudeBin: claudeBin, tmuxBin: tmuxBin, timeoutSecs: env["TIMEOUT_SECS"], stdout: stdout, stderr: stderr.isEmpty ? "Script timed out" : stderr)
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
        // Use stable probe working directory so Claude maps all probes to one project
        let workDir = ClaudeProbeConfig.probeWorkingDirectory()
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        env["WORKDIR"] = workDir
        env["MODEL"] = "sonnet"
        env["TIMEOUT_SECS"] = "10"
        env["SLEEP_BOOT"] = "0.4"
        env["SLEEP_AFTER_USAGE"] = "2.0"

        // Use real HOME for auth credentials (temp WORKDIR prevents file access prompts)
        // No CLAUDE_HOME override - let it use real ~/.claude/ with credentials

        // Pass resolved Claude binary path (same logic as resume)
        let claudeEnv = ClaudeCLIEnvironment()
        if let claudeBin = claudeEnv.resolveBinary(customPath: nil) {
            env["CLAUDE_BIN"] = claudeBin.path
        }

        // Pass resolved tmux path
        if let tmuxPath = resolveTmuxPath() {
            env["TMUX_BIN"] = tmuxPath
        }
        let probeLabel = makeProbeLabel()
        env["TMUX_LABEL"] = probeLabel
        activeProbeLabel = probeLabel
        defer { activeProbeLabel = nil }

        print("ClaudeStatusService: Executing script with WORKDIR=\(workDir), CLAUDE_BIN=\(env["CLAUDE_BIN"] ?? "not set"), TMUX_BIN=\(env["TMUX_BIN"] ?? "not set")")

        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let didExit = await waitForProcessExit(process, timeoutSeconds: 20, label: probeLabel, session: Self.probeSessionName)
        if !didExit {
            print("ClaudeStatusService: Script timed out after 20s, terminating")
            throw ClaudeServiceError.scriptFailed(exitCode: 124, output: "Script timed out")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if !errorOutput.isEmpty {
            print("ClaudeStatusService: Script stderr: \(errorOutput)")
        }

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
        var labels = Set<String>()
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
                labels.insert(label)
            }
        }
        labels.formUnion(scanTmuxLabels(prefix: Self.probeLabelPrefix))
        for label in labels {
            if await tmuxServerLooksLikeProbe(label: label,
                                              session: Self.probeSessionName,
                                              expectedCommandToken: "claude") {
                await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            }
        }
        for pid in pids {
            await terminateProcessGroup(pid: pid)
        }
    }

    private func cleanupOrphanedTmuxLabels() async {
        let labels = scanTmuxLabels(prefix: Self.probeLabelPrefix)
        for label in labels {
            if await tmuxServerLooksLikeProbe(label: label,
                                              session: Self.probeSessionName,
                                              expectedCommandToken: "claude") {
                await cleanupTmuxProbe(label: label, session: Self.probeSessionName)
            }
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
        guard let tmuxPath = resolveTmuxPath() else { return false }
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
            guard env.stdout.contains("AS_PROBE_KIND=claude") else { return false }
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
        guard let tmuxPath = resolveTmuxPath() else { return }
        if let panePid = await tmuxPanePID(tmuxPath: tmuxPath, label: label, session: session) {
            await terminateProcessGroup(pid: panePid)
        }
        _ = await runProcess(executable: tmuxPath,
                             arguments: ["-L", label, "kill-session", "-t", session],
                             timeoutSeconds: 2)
        _ = await runProcess(executable: tmuxPath,
                             arguments: ["-L", label, "kill-server"],
                             timeoutSeconds: 2)
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

        // Energy optimization: stop polling entirely when nothing is visible.
        let urgent = hasSnapshot && snapshot.sessionPercentUsed() >= 80
        if !visible && !urgent {
            return 3600 * 1_000_000_000
        }

        // Automatic background probing is AC-only.
        if !Self.onACPower() {
            return 3600 * 1_000_000_000
        }
        return userInterval * 1_000_000_000
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
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func checkClaudeAvailable() -> Bool {
        // Use same resolution logic as resume functionality
        let env = ClaudeCLIEnvironment()
        return env.resolveBinary(customPath: nil) != nil
    }

    private func resolveTmuxPath() -> String? {
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
            process.waitUntilExit()
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
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
