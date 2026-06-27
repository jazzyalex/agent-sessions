import Foundation

// MARK: - Antigravity Session Discovery

/// Discovery for Antigravity local brain artifacts.
/// Expected layout: ~/.gemini/antigravity/brain/<conversation-id>/*.md.
final class AntigravitySessionDiscovery: SessionDiscovery {
    private let customRoot: String?
    private let cliRoot: String?

    init(customRoot: String? = nil, cliRoot: String? = nil) {
        self.customRoot = customRoot
        self.cliRoot = cliRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity/brain")
    }

    private func cliSessionsRoot() -> URL {
        if let c = cliRoot, !c.isEmpty { return URL(fileURLWithPath: c) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli/brain")
    }

    func discoverSessionFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        out.append(contentsOf: scanMarkdown(root: sessionsRoot(), fm: fm))
        out.append(contentsOf: scanCLITranscripts(root: cliSessionsRoot(), fm: fm))
        out.sort { mtime($0) > mtime($1) }
        return out
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func scanMarkdown(root: URL, fm: FileManager) -> [URL] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let conversations = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for conversation in conversations {
            guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: conversation, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            out.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "md" })
        }
        return out
    }

    private func scanCLITranscripts(root: URL, fm: FileManager) -> [URL] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let conversations = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for conversation in conversations {
            guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let t = conversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if fm.fileExists(atPath: t.path) { out.append(t) }
        }
        return out
    }
}
