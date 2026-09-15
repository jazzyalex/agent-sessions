import Foundation

// MARK: - Antigravity Session Discovery

/// Discovery for Antigravity local brain artifacts.
/// Expected layout: ~/.gemini/antigravity/brain/<conversation-id>/*.md.
final class AntigravitySessionDiscovery: SessionDiscovery {
    struct DiscoverySnapshot {
        var files: [URL]
        var authoritativeRoots: [URL]

        func isAuthoritative(path: String) -> Bool {
            let needle = AntigravitySessionDiscovery.normalizedPath(path)
            for root in authoritativeRoots {
                let base = AntigravitySessionDiscovery.normalizedPath(root.path)
                if needle == base || needle.hasPrefix(base + "/") { return true }
            }
            return false
        }
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private let customRoot: String?
    private let cliRoot: String?
    private let cliTranscriptProbe: (URL) throws -> Bool

    init(
        customRoot: String? = nil,
        cliRoot: String? = nil,
        cliTranscriptProbe: ((URL) throws -> Bool)? = nil
    ) {
        self.customRoot = customRoot
        self.cliRoot = cliRoot
        self.cliTranscriptProbe = cliTranscriptProbe ?? Self.defaultCLITranscriptProbe
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity/brain")
    }

    private func cliSessionsRoot() -> URL {
        if let c = cliRoot, !c.isEmpty { return URL(fileURLWithPath: c) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli/brain")
    }

    func discoverSnapshot() -> DiscoverySnapshot {
        let fm = FileManager.default
        let markdownRoot = sessionsRoot()
        let cliRootURL = cliSessionsRoot()
        let md = scanMarkdownSnapshot(root: markdownRoot, fm: fm)
        let cli = scanCLISnapshot(root: cliRootURL, fm: fm)
        var files = md.files + cli.files
        files.sort { mtime($0) > mtime($1) }
        var roots: [URL] = []
        if md.authoritative { roots.append(markdownRoot) }
        if cli.authoritative { roots.append(cliRootURL) }
        return DiscoverySnapshot(files: files, authoritativeRoots: roots)
    }

    func discoverSessionFiles() -> [URL] {
        discoverSnapshot().files
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func scanMarkdownSnapshot(root: URL, fm: FileManager) -> (files: [URL], authoritative: Bool) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return ([], false) }
        do {
            let conversations = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var out: [URL] = []
            for conversation in conversations {
                let values = try conversation.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                let files = try fm.contentsOfDirectory(at: conversation, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                out.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "md" })
            }
            return (out, true)
        } catch {
            return ([], false)
        }
    }

    private func scanCLISnapshot(root: URL, fm: FileManager) -> (files: [URL], authoritative: Bool) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return ([], false) }
        do {
            let conversations = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var out: [URL] = []
            var authoritative = true
            for conversation in conversations {
                let values = try conversation.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                let t = conversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                do {
                    if try cliTranscriptProbe(t) { out.append(t) }
                } catch {
                    authoritative = false
                }
            }
            return (out, authoritative)
        } catch {
            return ([], false)
        }
    }

    private static func defaultCLITranscriptProbe(_ url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true
        } catch {
            if isConfirmedMissing(error) { return false }
            throw error
        }
    }

    private static func isConfirmedMissing(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let candidate = current {
            if candidate.domain == NSCocoaErrorDomain,
               candidate.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
                return true
            }
            if candidate.domain == NSPOSIXErrorDomain,
               candidate.code == Int(POSIXErrorCode.ENOENT.rawValue) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
