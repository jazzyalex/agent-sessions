import Foundation
import Security
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Manual claude.ai session cookie (primary web source)
//
// On macOS 14/15 Safari no longer exposes the live claude.ai `sessionKey` to apps
// (see ClaudeWebCookieResolver), so scraping is a dead end for signed-in Safari
// users. The safe, durable web-usage source is a cookie the USER pastes once:
// they copy their claude.ai `sessionKey` from their browser and paste it into
// Settings. The app never handles the user's credentials — sign-in stays entirely
// in the user's browser; we only receive the resulting session token they choose
// to hand us, and we store it in the Keychain (a bearer token, never plaintext
// UserDefaults). This mirrors how CodexBar exposes a Claude web fallback.

enum ClaudeManualWebCookie {
    /// Extract a bare claude.ai `sessionKey` from whatever the user pasted. Accepts:
    /// - a lone token (`sk-ant-sid01-…`),
    /// - a `sessionKey=…` pair,
    /// - a full `Cookie:` header containing a `sessionKey=…` pair among others.
    ///
    /// Returns nil for empty input or a cookie header that lacks `sessionKey`.
    /// NEVER logs the value.
    static func extractSessionKey(fromPasted raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Strip a leading "Cookie:" request-header label if the user copied it.
        if let r = s.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // Preferred: find the cookie pair NAMED exactly `sessionKey`. Split on ';'
        // and match on the trimmed name so the match is name-anchored — a
        // different cookie whose name merely ends in "sessionKey" (e.g.
        // `anon_sessionKey=`), or an earlier value that happens to contain the
        // literal `sessionKey=`, must NOT be mistaken for the real pair.
        for pair in s.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, String(kv[0]).trimmingCharacters(in: .whitespaces) == "sessionKey" else { continue }
            let value = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
            return value.isEmpty ? nil : value
        }

        // No sessionKey pair. Accept a lone pasted token, but reject a cookie
        // header that simply lacks sessionKey (it contains ';' or '=' separators).
        if s.contains(";") || s.contains("=") { return nil }
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Secret storage

/// Abstraction over the secret store so the persistence layer is unit-testable
/// with an in-memory double (the real store is the login Keychain).
protocol ClaudeSecretStore {
    func read() -> String?
    func write(_ value: String) -> Bool
    func delete()
    func readSecret() throws -> String?
    func writeSecret(_ value: String) throws
    func deleteSecret() throws
}

enum ClaudeSecretStoreError: Error, Equatable {
    case securityStatus(Int32)
    case invalidData
    case writeFailed
}

extension ClaudeSecretStore {
    func readSecret() throws -> String? { read() }
    func writeSecret(_ value: String) throws {
        guard write(value) else { throw ClaudeSecretStoreError.writeFailed }
    }
    func deleteSecret() throws { delete() }
}

/// Persists (and validates) the user's pasted claude.ai session cookie.
struct ClaudeManualWebCookieStore {
    let secretStore: ClaudeSecretStore

    /// App-wide instance backed by the Keychain.
    static let shared = ClaudeManualWebCookieStore(secretStore: KeychainSecretStore(
        service: "com.triada.AgentSessions.claude-web",
        account: "claude-web-sessionKey"))

    /// Extract + persist the sessionKey from pasted text. Returns false (and stores
    /// nothing) if the paste holds no usable sessionKey.
    @discardableResult
    func save(pasted: String) -> Bool {
        guard let key = ClaudeManualWebCookie.extractSessionKey(fromPasted: pasted) else { return false }
        let ok = secretStore.write(key)
        os_log("ClaudeOAuth: manual web cookie saved (ok=%{public}@)", log: log, type: .info, ok ? "yes" : "no")
        return ok
    }

    func currentSessionKey() -> String? {
        guard let value = secretStore.read(), !value.isEmpty else { return nil }
        return value
    }

    var hasStoredCookie: Bool { currentSessionKey() != nil }

    func clear() {
        secretStore.delete()
        os_log("ClaudeOAuth: manual web cookie cleared", log: log, type: .info)
    }
}

/// Keychain-backed `ClaudeSecretStore`. Reads/writes ONLY the app's own generic
/// password item, so it never triggers a cross-app TCC/Keychain prompt.
struct KeychainSecretStore: ClaudeSecretStore {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        try? readSecret()
    }

    func readSecret() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClaudeSecretStoreError.securityStatus(status) }
        guard let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { throw ClaudeSecretStoreError.invalidData }
        return value
    }

    func write(_ value: String) -> Bool {
        do { try writeSecret(value); return true } catch { return false }
    }

    func writeSecret(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw ClaudeSecretStoreError.securityStatus(added) }
            return
        }
        throw ClaudeSecretStoreError.securityStatus(status)
    }

    func delete() {
        try? deleteSecret()
    }

    func deleteSecret() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeSecretStoreError.securityStatus(status)
        }
    }
}
