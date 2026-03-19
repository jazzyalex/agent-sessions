import Foundation
import CryptoKit

// MARK: - Credential Fingerprint
//
// Captures a lightweight fingerprint of Claude credentials so that
// ClaudeUsageSourceManager can detect a credential change without
// polling the OAuth endpoint. Used to gate retries after failure:
// only retry when credentials actually changed, not on a blind timer.
//
// Two signals:
//   1. Keychain mod time: mtime of ~/Library/Keychains/login.keychain-db.
//      Fast (no subprocess), coarser than per-entry but sufficient as a
//      trigger — any keychain write sets a new mtime.
//   2. Credentials file hash: SHA256 prefix of ~/.claude/.credentials.json.
//      Covers Linux/older installs where credentials live in a file.
//
// Changed if either component differs or was nil → non-nil.

actor ClaudeCredentialFingerprint {
    struct Fingerprint: Equatable, Sendable {
        let keychainModDate: Date?   // mtime of login.keychain-db
        let credFileHash: String?   // 8-hex SHA256 prefix of .credentials.json
        let capturedAt: Date
    }

    func capture() async -> Fingerprint {
        Fingerprint(
            keychainModDate: keychainModificationDate(),
            credFileHash: credentialsFileHash(),
            capturedAt: Date()
        )
    }

    func hasChanged(since prior: Fingerprint) async -> Bool {
        let current = await capture()
        return current.keychainModDate != prior.keychainModDate
            || current.credFileHash != prior.credFileHash
    }

    // MARK: - Private

    private func keychainModificationDate() -> Date? {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Keychains/login.keychain-db")
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func credentialsFileHash() -> String? {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
