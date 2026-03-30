import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Delegated Token Refresh
//
// On 401, spawns `claude /status` which triggers the CLI's internal token
// refresh logic (re-exchanges for a new access token). If the credentials
// file or keychain changes afterwards, the new token is ready to use.
//
// Called at most once per failure cycle via `didAttemptDelegatedRefresh`
// guard in ClaudeUsageSourceManager. Polling is short (5 × 2s) since the
// CLI refresh is typically fast.

actor ClaudeDelegatedTokenRefresh {
    enum RefreshResult: Sendable {
        case refreshed        // Credential change detected after CLI ran
        case noChange         // CLI ran but no credential change observed
        case cliUnavailable   // claude binary not found or failed to launch
        case timeout          // Process didn't exit within 15s
    }

    private let fingerprint = ClaudeCredentialFingerprint()

    func attemptRefresh() async -> RefreshResult {
        guard !AppRuntime.isRunningTests else {
            os_log("ClaudeOAuth: delegated refresh — skipped in test mode", log: log, type: .info)
            return .cliUnavailable
        }
        guard let binaryURL = ClaudeCLIEnvironment().resolveBinary(customPath: nil) else {
            os_log("ClaudeOAuth: delegated refresh — claude binary not found", log: log, type: .info)
            return .cliUnavailable
        }

        let prior = await fingerprint.capture()

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["/status"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do { try process.run() } catch {
            os_log("ClaudeOAuth: delegated refresh — process launch failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return .cliUnavailable
        }

        // Wait up to 15s for the process to exit (0.2s polling)
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            os_log("ClaudeOAuth: delegated refresh — process timed out", log: log, type: .info)
            return .timeout
        }

        // Poll for fingerprint change — 5 attempts × 2s = 10s window
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await fingerprint.hasChanged(since: prior) {
                os_log("ClaudeOAuth: delegated refresh — credential change detected", log: log, type: .info)
                return .refreshed
            }
        }

        os_log("ClaudeOAuth: delegated refresh — no credential change after CLI exit", log: log, type: .info)
        return .noChange
    }
}
