import Foundation

/// Restores an archived Claude Code Desktop session by editing its metadata sidecar.
/// This is the ONLY write Agent Sessions performs into Claude's data, and only when the
/// user has explicitly enabled it (off by default) — see `allowWritesDefaultsKey`.
enum ClaudeArchiveRestore {
    /// UserDefaults key gating all writes. Mirrored by `PreferencesKey.Advanced.allowClaudeArchiveRestore`.
    static let allowWritesDefaultsKey = "AllowClaudeArchiveRestore"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: allowWritesDefaultsKey)
    }

    enum RestoreError: Error, Equatable {
        case disabled
        case sidecarMissing
        case malformed
    }

    /// Set `isArchived=false` + `autoArchiveExempt=true` in the sidecar, preserving all other keys.
    static func restore(sidecarPath: String, enabled: Bool, fileManager: FileManager = .default) throws {
        guard enabled else { throw RestoreError.disabled }
        guard fileManager.fileExists(atPath: sidecarPath) else { throw RestoreError.sidecarMissing }
        let url = URL(fileURLWithPath: sidecarPath)
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.malformed
        }
        obj["isArchived"] = false
        obj["autoArchiveExempt"] = true
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    static func restore(sidecarPath: String, fileManager: FileManager = .default) throws {
        try restore(sidecarPath: sidecarPath, enabled: isEnabled, fileManager: fileManager)
    }
}
