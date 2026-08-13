import Foundation

/// Discovery for Grok CLI session stores under `~/.grok/sessions`.
///
/// Layout: `sessions/<percent-encoded workdir>/<sessionId>/`, where the session
/// directory holds `summary.json` (the sidecar) alongside `chat_history.jsonl`
/// (the transcript) and a much larger `updates.jsonl` event journal.
///
/// The transcript, not the journal, is the discovery unit. `updates.jsonl`
/// carries the same conversation re-encoded as streaming ACP updates and runs
/// three orders of magnitude larger — 2.3 GB against 1.2 MB in the largest
/// session measured — because each `tool_call_update` repeats the whole
/// accumulated tool output rather than a delta. Reading `chat_history.jsonl`
/// yields the identical transcript at a fraction of the cost.
final class GrokSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session id is the directory holding `chat_history.jsonl`.
    static func sessionID(forTranscript url: URL) -> String? {
        let id = url.deletingLastPathComponent().lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// `summary.json` sits beside the transcript.
    static func summaryFile(forTranscript url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("summary.json", isDirectory: false)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // Two fixed levels (workdir bucket, then session id) rather than a deep
        // enumeration: a session directory can contain `subagents/`, `terminal/`
        // and `compaction/` subtrees, and recursing them would surface nested
        // transcripts as if they were top-level sessions.
        var files: [URL] = []
        let buckets = (try? fm.contentsOfDirectory(at: root,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for bucket in buckets {
            guard (try? bucket.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sessions = (try? fm.contentsOfDirectory(at: bucket,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for session in sessions {
                guard (try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let transcript = session.appendingPathComponent("chat_history.jsonl", isDirectory: false)
                guard fm.fileExists(atPath: transcript.path) else { continue }
                guard fm.fileExists(atPath: Self.summaryFile(forTranscript: transcript).path) else { continue }
                guard Self.sessionID(forTranscript: transcript) != nil else { continue }
                files.append(transcript)
            }
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }

    private func normalizedSessionsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [root.appendingPathComponent("sessions", isDirectory: true), root]
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return root
    }
}
