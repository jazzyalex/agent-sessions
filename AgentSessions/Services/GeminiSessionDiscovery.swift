import Foundation

// MARK: - Antigravity Session Discovery

/// Discovery for Antigravity local brain artifacts.
/// Expected layout: ~/.gemini/antigravity/brain/<conversation-id>/*.md.
final class GeminiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity/brain")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var out: [URL] = []
        // Shallow scan: iterate per-conversation directories in ~/.gemini/antigravity/brain.
        guard let conversations = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for conversation in conversations {
            guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            out.append(contentsOf: sessionFiles(in: conversation, fileManager: fm))
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

    private func sessionFiles(in dir: URL, fileManager fm: FileManager) -> [URL] {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return []
        }

        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return files.filter { url in
            guard url.pathExtension.lowercased() == "md" else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
