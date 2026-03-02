import Foundation

// MARK: - Gemini Session Discovery

/// Discovery for Google Gemini CLI session checkpoints (ephemeral)
/// Expected layout: ~/.gemini/tmp/<project>/chats/session-*.json
/// Also handle fallback: ~/.gemini/tmp/<project>/session-*.json
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
        // Shallow scan: iterate per-project directories in ~/.gemini/tmp.
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for proj in projects {
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = proj.lastPathComponent
            // Skip known non-project entries.
            if name == "bin" || name == ".DS_Store" || name.hasSuffix(".txt") { continue }

            // Prefer chats/ subdir when present.
            let chats = proj.appendingPathComponent("chats", isDirectory: true)
            let chatFiles = sessionJSONFiles(in: chats, fileManager: fm)

            // Fallback: look directly in project dir for session-*.json
            let rootFiles = sessionJSONFiles(in: proj, fileManager: fm)

            // Only accept directories that actually contain session files.
            if chatFiles.isEmpty && rootFiles.isEmpty {
                continue
            }
            out.append(contentsOf: chatFiles)
            out.append(contentsOf: rootFiles)
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

    private func sessionJSONFiles(in dir: URL, fileManager fm: FileManager) -> [URL] {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return []
        }

        var found: [URL] = []
        guard let it = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }
        for case let f as URL in it {
            if f.pathExtension.lowercased() == "json" && f.lastPathComponent.hasPrefix("session-") {
                found.append(f)
            }
        }
        return found
    }
}
