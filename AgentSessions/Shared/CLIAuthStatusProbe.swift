import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CLIAuthStatusProbe")

// MARK: - CLI Auth Status Probe
//
// Authoritative auth-status probe for the `claude` and `codex` CLIs. Feeds
// the `cliStatus` input of ClaudeAuthClassifier / CodexAuthClassifier — the
// only status source those classifiers treat as a definite `.signedIn`
// verdict without needing debounce.
//
// Pure parsers (testable, no I/O) + async Process-based runners. Runners are
// deliberately conservative: any ambiguity (unresolvable binary, launch
// failure, timeout, unparseable output) must never be reported as a
// confident `.signedOut` — that's exactly the false-alarm the classifiers
// are built to avoid. Only an explicit "not logged in" style answer counts.
enum CLIAuthStatusProbe {

    private static let subprocessTimeoutSeconds: TimeInterval = 5

    // MARK: Pure parsers

    /// Parse `claude auth status` JSON. `loggedIn: true` → signedIn;
    /// `loggedIn: false` → signedOut; anything unparseable → unknown
    /// (never guess signed-out from garbage/empty output).
    static func parseClaudeAuthStatus(stdout: String, exitCode: Int32) -> CLIAuthStatus {
        if let data = stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loggedIn = obj["loggedIn"] as? Bool {
            return loggedIn ? .signedIn : .signedOut
        }
        return .unknown
    }

    /// Parse `codex login status` text. Explicit "not logged in"/"logged out"
    /// → signedOut; otherwise "logged in" → signedIn; unrecognized → unknown.
    static func parseCodexLoginStatus(stdout: String, exitCode: Int32) -> CLIAuthStatus {
        let s = stdout.lowercased()
        if s.contains("not logged in") || s.contains("logged out") { return .signedOut }
        if s.contains("logged in") { return .signedIn }
        return .unknown
    }

    // MARK: Async runners (not unit-tested — subprocess)

    /// Runs `claude auth status` and classifies the result. Resolves the
    /// binary the same way the rest of the app does (explicit override in
    /// `ClaudeResumeSettings`, then PATH/login-shell/common-install
    /// fallbacks via `ClaudeCLIEnvironment`).
    static func probeClaudeAuthStatus() async -> CLIAuthStatus {
        guard !AppRuntime.isRunningTests else { return .unknown }

        let override = UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath)
        guard let binaryURL = ClaudeCLIEnvironment().resolveBinary(customPath: override) else {
            os_log("CLIAuthStatusProbe: claude binary not found", log: log, type: .info)
            return .cliMissing
        }

        let result = await runProcess(executableURL: binaryURL, arguments: ["auth", "status"])
        switch result {
        case .launchFailed, .timedOut:
            return .unknown
        case .completed(let stdout, let exitCode):
            return parseClaudeAuthStatus(stdout: stdout, exitCode: exitCode)
        }
    }

    /// Runs `codex login status` and classifies the result. Resolves the
    /// binary via `CodexCLIEnvironment` (explicit override in
    /// `CodexResumeSettings`, then PATH/login-shell/common-install
    /// fallbacks) — the same resolver used by the tmux/RPC codex probes.
    static func probeCodexLoginStatus() async -> CLIAuthStatus {
        guard !AppRuntime.isRunningTests else { return .unknown }

        let override = UserDefaults.standard.string(forKey: CodexResumeSettings.Keys.binaryOverride)
        guard let binaryURL = CodexCLIEnvironment().resolveBinary(customPath: override) else {
            os_log("CLIAuthStatusProbe: codex binary not found", log: log, type: .info)
            return .cliMissing
        }

        let result = await runProcess(executableURL: binaryURL, arguments: ["login", "status"])
        switch result {
        case .launchFailed, .timedOut:
            return .unknown
        case .completed(let stdout, let exitCode):
            return parseCodexLoginStatus(stdout: stdout, exitCode: exitCode)
        }
    }

    // MARK: - Process helper

    private enum ProcessOutcome {
        case completed(stdout: String, exitCode: Int32)
        case launchFailed
        case timedOut
    }

    /// Runs a binary with a short timeout, mirroring the polling pattern in
    /// `ClaudeOAuthTokenResolver.runSecurityCommand` (poll `isRunning` in
    /// 100ms increments up to the timeout, `terminate()` on timeout, never
    /// block the calling thread).
    private static func runProcess(executableURL: URL, arguments: [String]) async -> ProcessOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            os_log("CLIAuthStatusProbe: process launch failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return .launchFailed
        }

        let maxIterations = Int(subprocessTimeoutSeconds * 10)  // 100ms increments
        var iterations = 0
        while process.isRunning && iterations < maxIterations {
            try? await Task.sleep(nanoseconds: 100_000_000)
            iterations += 1
        }

        if process.isRunning {
            process.terminate()
            os_log("CLIAuthStatusProbe: process timed out", log: log, type: .info)
            return .timedOut
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        return .completed(stdout: stdout, exitCode: process.terminationStatus)
    }
}
