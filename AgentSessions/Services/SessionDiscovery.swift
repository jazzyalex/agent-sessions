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

        // Claude Code stores sessions under ~/.claude/projects/<project>/... by default.
        // Prefer that subtree to avoid picking up unrelated JSONL (e.g., history.jsonl).
        let projectsRoot = root.appendingPathComponent("projects")
        let scanRoot: URL = {
            var isProjectsDir: ObjCBool = false
            if fm.fileExists(atPath: projectsRoot.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue {
                return projectsRoot
            }
            return root
        }()

        var found: [URL] = []

        // Scan for .jsonl and .ndjson files (sessions) under scan root
        if let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
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

// MARK: - Copilot CLI Session Discovery

/// Discovery for GitHub Copilot CLI agent sessions.
/// Default layout: ~/.copilot/session-state/<sessionId>.jsonl
final class CopilotSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        let fm = FileManager.default
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)

            // Allow users to pick either:
            // - ~/.copilot                      (config root)
            // - ~/.copilot/session-state         (sessions root)
            // - any folder that directly contains *.jsonl session-state files
            if url.lastPathComponent == "session-state" { return url }
            let child = url.appendingPathComponent("session-state", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                return child
            }
            return url
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                found.append(url)
            }
        }

        // Sort by file modification time descending (newest first)
        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}
