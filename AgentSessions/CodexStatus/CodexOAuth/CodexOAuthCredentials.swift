import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexOAuth")

// MARK: - Codex OAuth Credentials
//
// Reads access tokens from ~/.codex/auth.json (written by `codex login`).
// Read on every resolution so an in-process account switch cannot keep using
// the prior account's token. No token refresh in this layer — callers fall
// through to CLI RPC or tmux probe on 401.

struct CodexTokenSet: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let accountId: String?
}

/// Result-typed read of the on-disk auth file, distinguishing missing-file
/// from present-but-unparseable/no-usable-token, so callers (e.g. the auth
/// health classifier) can surface the actual cause instead of a bare `nil`.
enum CodexCredentialRead: Equatable {
    case present(CodexTokenSet)
    case absent
    case malformed
}

actor CodexOAuthCredentials {
    private static let authFilePath: String = {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    }()

    func resolve() -> CodexTokenSet? {
        if case .present(let resolved) = resolveRead() {
            os_log("CodexOAuth: resolved token from auth.json", log: log, type: .debug)
            return resolved
        }
        os_log("CodexOAuth: no valid token in auth.json", log: log, type: .info)
        return nil
    }

    func invalidateCache() {}

    /// Result-typed variant of `readFromFile()` that distinguishes an absent
    /// auth file from one that is present but malformed / has no usable
    /// token. Honors `AS_TEST_CODEX_AUTH_PATH` to allow tests to point at a
    /// fixture file instead of the real `~/.codex/auth.json`. Does not read
    /// or write the in-memory cache — this is a diagnostic read, not the
    /// hot path used by `resolve()`. Declared `nonisolated` (it touches no
    /// actor-isolated state) so callers — including synchronous test code —
    /// can invoke it without `await`.
    nonisolated func resolveRead() -> CodexCredentialRead {
        let path = ProcessInfo.processInfo.environment["AS_TEST_CODEX_AUTH_PATH"] ?? Self.authFilePath
        guard let data = FileManager.default.contents(atPath: path) else { return .absent }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .malformed }

        if let tokens = json["tokens"] as? [String: Any],
           let access = tokens["access_token"] as? String, !access.isEmpty {
            return .present(CodexTokenSet(
                accessToken: access,
                refreshToken: tokens["refresh_token"] as? String,
                accountId: (json["account_id"] as? String) ?? (tokens["account_id"] as? String)
            ))
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .present(CodexTokenSet(accessToken: apiKey, refreshToken: nil, accountId: nil))
        }

        return .malformed   // file present, no usable token
    }

}
