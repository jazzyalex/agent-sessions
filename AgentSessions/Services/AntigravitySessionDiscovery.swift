import Foundation

// MARK: - Antigravity Session Discovery

/// Discovery for Antigravity local brain stores.
/// Desktop/IDE: ~/.gemini/antigravity/brain/<conversation-id>/ holds either
/// `.system_generated/logs/transcript.jsonl` (desktop app) or legacy `*.md` artifacts.
/// CLI: ~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl.
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
        let desktop = scanDesktopSnapshot(root: markdownRoot, fm: fm)
        let cli = scanCLISnapshot(root: cliRootURL, fm: fm)
        var files = Self.dedupedByConversation(desktop.files + cli.files, mtime: mtime)
        files.sort { mtime($0) > mtime($1) }
        var roots: [URL] = []
        if desktop.authoritative { roots.append(markdownRoot) }
        if cli.authoritative { roots.append(cliRootURL) }
        return DiscoverySnapshot(files: files, authoritativeRoots: roots)
    }

    /// One session per conversation id. A transcript is the whole conversation, so it
    /// replaces the markdown artifacts of the same conversation (their ids are
    /// `<conversation>#<artifact>`, never the bare id). Transcripts share the bare
    /// conversation id as their session id, so when both brain roots hold one for the
    /// same conversation only the newer file is kept.
    static func dedupedByConversation(_ files: [URL], mtime: (URL) -> Date) -> [URL] {
        var transcriptByConversation: [String: URL] = [:]
        for url in files where url.pathExtension.lowercased() == "jsonl" {
            guard let id = AntigravityTranscriptParser.conversationID(for: url) else { continue }
            if let existing = transcriptByConversation[id], mtime(existing) >= mtime(url) { continue }
            transcriptByConversation[id] = url
        }
        return files.filter { url in
            if url.pathExtension.lowercased() == "jsonl" {
                guard let id = AntigravityTranscriptParser.conversationID(for: url) else { return true }
                return transcriptByConversation[id] == url
            }
            guard let id = AntigravitySessionIDHelper.conversationID(fromArtifactURL: url) else { return true }
            return transcriptByConversation[id] == nil
        }
    }

    func discoverSessionFiles() -> [URL] {
        discoverSnapshot().files
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The desktop brain root holds two generations of one layout. Older IDE builds
    /// left only `*.md` artifacts per conversation; the desktop app (2.25.0+) writes
    /// the same `.system_generated/logs/transcript.jsonl` as the CLI. A conversation
    /// with a transcript is listed by its transcript, so its artifacts do not show as
    /// separate sessions; one without a transcript keeps its markdown artifacts.
    private func scanDesktopSnapshot(root: URL, fm: FileManager) -> (files: [URL], authoritative: Bool) {
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
                    if try cliTranscriptProbe(t) {
                        out.append(t)
                        continue
                    }
                } catch {
                    // Unknown whether a transcript exists: keep the artifacts so the
                    // conversation stays listed, and stop claiming the root is complete.
                    authoritative = false
                }
                let files = try fm.contentsOfDirectory(at: conversation, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                out.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "md" })
            }
            return (out, authoritative)
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
