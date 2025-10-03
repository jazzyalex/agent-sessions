import Foundation

/// Protocol for discovering session files from different sources
protocol SessionDiscovery {
    /// Root directory to scan for sessions
    func sessionsRoot() -> URL

    /// Find all session files in the root directory
    func discoverSessionFiles() -> [URL]
}

// MARK: - Codex Session Discovery

final class CodexSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                // Codex format: rollout-YYYY-MM-DDThh-mm-ss-UUID.jsonl
                if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl" {
                    found.append(url)
                }
            }
        }

        // Sort by filename descending (newest first)
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// MARK: - Claude Code Session Discovery

final class ClaudeSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []

        // Scan for .jsonl and .ndjson files in ~/.claude/
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "jsonl" || ext == "ndjson" {
                    found.append(url)
                }
            }
        }

        // Sort by modification time descending (newest first)
        return found.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
                             (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
    }
}
