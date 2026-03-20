import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexOAuth")

// MARK: - Codex OAuth Credentials
//
// Reads access tokens from ~/.codex/auth.json (written by `codex login`).
// Cached in memory for 10 minutes. No token refresh in this layer —
// callers fall through to CLI RPC or tmux probe on 401.

struct CodexTokenSet: Sendable {
    let accessToken: String
    let refreshToken: String?
    let accountId: String?
}

actor CodexOAuthCredentials {
    private var cached: CodexTokenSet?
    private var cacheExpiresAt: Date = .distantPast
    private let cacheTTL: TimeInterval = 10 * 60  // 10 minutes

    private static let authFilePath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }()

    func resolve() -> CodexTokenSet? {
        if let cached, Date() < cacheExpiresAt {
            return cached
        }

        let resolved = readFromFile()
        if let resolved {
            cached = resolved
            cacheExpiresAt = Date().addingTimeInterval(cacheTTL)
            os_log("CodexOAuth: resolved token from auth.json", log: log, type: .debug)
        } else {
            os_log("CodexOAuth: no valid token in auth.json", log: log, type: .info)
        }
        return resolved
    }

    func invalidateCache() {
        cached = nil
        cacheExpiresAt = .distantPast
    }

    // MARK: - Private

    private func readFromFile() -> CodexTokenSet? {
        guard let data = FileManager.default.contents(atPath: Self.authFilePath) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Primary path: tokens.access_token
        if let tokens = json["tokens"] as? [String: Any] {
            guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else { return nil }
            return CodexTokenSet(
                accessToken: accessToken,
                refreshToken: tokens["refresh_token"] as? String,
                accountId: tokens["account_id"] as? String
            )
        }

        // Legacy path: top-level OPENAI_API_KEY
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexTokenSet(accessToken: apiKey, refreshToken: nil, accountId: nil)
        }

        return nil
    }
}
