import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - OAuth Token Resolver
//
// Resolves a Claude OAuth access token from three sources, in priority order:
//   1. CLAUDE_CODE_OAUTH_TOKEN environment variable
//   2. macOS Keychain via `security` CLI (same approach as ClaudeCodeStatusLine)
//   3. ~/.claude/.credentials.json (common on Linux / older Claude Code versions)
//
// The `security` subprocess approach mirrors the community script pattern:
// - Attribution goes to the `security` tool, not to AgentSessions
// - First access may show a one-time Keychain prompt; "Always Allow" makes it silent
// - After approval, access is completely silent
//
// The resolved token is cached in memory for 10 minutes.
// The token value is never logged.

actor ClaudeOAuthTokenResolver {
    enum TokenSource: String, CustomStringConvertible {
        case env             = "environment variable"
        case keychain        = "Keychain"
        case credentialsFile = "credentials file"

        var description: String { rawValue }
    }

    struct ResolvedToken: Sendable {
        let token: String
        let source: TokenSource
    }

    private var cachedToken: ResolvedToken?
    private var cacheExpiresAt: Date = .distantPast
    private let cacheTTL: TimeInterval = 10 * 60  // 10 minutes

    // MARK: - Public

    func resolve() async -> ResolvedToken? {
        if let cached = cachedToken, Date() < cacheExpiresAt {
            return cached
        }

        let resolved = await resolveUncached()
        if let resolved {
            cachedToken = resolved
            cacheExpiresAt = Date().addingTimeInterval(cacheTTL)
            os_log("ClaudeOAuth: resolved token from %{public}@", log: log, type: .info, resolved.source.rawValue)
        } else {
            os_log("ClaudeOAuth: no OAuth token found", log: log, type: .info)
        }
        return resolved
    }

    func invalidateCache() {
        cachedToken = nil
        cacheExpiresAt = .distantPast
    }

    // MARK: - Private

    private func resolveUncached() async -> ResolvedToken? {
        // 1. Environment variable
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !envToken.isEmpty {
            return ResolvedToken(token: envToken, source: .env)
        }

        // 2. Keychain via `security` CLI (same pattern as ClaudeCodeStatusLine)
        if let keychainToken = await resolveFromKeychainCLI() {
            return ResolvedToken(token: keychainToken, source: .keychain)
        }

        // 3. ~/.claude/.credentials.json (Linux / older Claude Code)
        if let fileToken = resolveFromCredentialsFile() {
            return ResolvedToken(token: fileToken, source: .credentialsFile)
        }

        return nil
    }

    /// Shell out to `security find-generic-password` — the same approach used by
    /// community scripts like ClaudeCodeStatusLine. Attribution goes to the
    /// `security` tool rather than AgentSessions, which is more expected for
    /// power users. After "Always Allow", access is completely silent.
    private func resolveFromKeychainCLI() async -> String? {
        let result = await runSecurityCommand(service: "Claude Code-credentials")
        return result.flatMap { extractToken(fromJSON: $0) }
    }

    private func runSecurityCommand(service: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch {
            os_log("ClaudeOAuth: security command failed to launch: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            return nil
        }

        // Poll without blocking — process runs fast
        let maxWait = 50  // 5 seconds max
        var iterations = 0
        while process.isRunning && iterations < maxWait {
            try? await Task.sleep(nanoseconds: 100_000_000)
            iterations += 1
        }
        if process.isRunning { process.terminate(); return nil }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract OAuth access token from a string that is either:
    ///   - A bare token ("sk-ant-oat01-...")
    ///   - A JSON blob: {"claudeAiOauth": {"accessToken": "..."}}
    private func extractToken(fromJSON raw: String) -> String? {
        guard !raw.isEmpty else { return nil }

        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Top-level keys
            for key in ["accessToken", "access_token", "oauthToken", "oauth_token", "token"] {
                if let token = json[key] as? String, !token.isEmpty { return token }
            }
            // Nested under "claudeAiOauth" (Claude Code macOS format)
            if let nested = json["claudeAiOauth"] as? [String: Any] {
                for key in ["accessToken", "access_token", "token"] {
                    if let token = nested[key] as? String, !token.isEmpty { return token }
                }
            }
        }

        // Bare token string (starts with "sk-")
        if raw.hasPrefix("sk-") { return raw }

        return nil
    }

    private func resolveFromCredentialsFile() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        for key in ["accessToken", "access_token", "oauthToken", "oauth_token", "token"] {
            if let token = json[key] as? String, !token.isEmpty { return token }
        }
        if let nested = json["claudeAiOauth"] as? [String: Any] {
            for key in ["accessToken", "access_token", "token"] {
                if let token = nested[key] as? String, !token.isEmpty { return token }
            }
        }
        return nil
    }
}
