import Foundation

// MARK: - Gemini Session Discovery

/// Discovery for Google Gemini CLI session checkpoints (ephemeral)
/// Expected layout: ~/.gemini/tmp/<projectHash>/chats/session-*.json
/// Also handle fallback: ~/.gemini/tmp/<projectHash>/session-*.json
final class GeminiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/tmp")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var out: [URL] = []
        // Shallow scan: iterate hashed project directories
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for proj in projects {
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            // Prefer chats/ subdir
            let chats = proj.appendingPathComponent("chats", isDirectory: true)
            if (try? chats.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               let it = fm.enumerator(at: chats, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                for case let f as URL in it {
                    if f.pathExtension.lowercased() == "json" && f.lastPathComponent.hasPrefix("session-") {
                        out.append(f)
                    }
                }
            }

            // Fallback: look directly in project dir for session-*.json
            if let it2 = fm.enumerator(at: proj, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                for case let f as URL in it2 {
                    if f.pathExtension.lowercased() == "json" && f.lastPathComponent.hasPrefix("session-") {
                        out.append(f)
                    }
                }
            }
        }

        // Sort by modification time (desc)
        out.sort { (lhs, rhs) in
            let lm: Date = {
                if let rv = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]),
                   let d = rv.contentModificationDate { return d }
                return .distantPast
            }()
            let rm: Date = {
                if let rv = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]),
                   let d = rv.contentModificationDate { return d }
                return .distantPast
            }()
            return lm > rm
        }
        return out
    }
}
