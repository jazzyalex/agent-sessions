import Foundation

/// Discovery for Kimi Code main-agent journals under ~/.kimi-code/sessions.
///
/// Layout: sessions/<wd_slug_hash>/<sessionId>/agents/<agentId>/wire.jsonl.
/// Only `agents/main` is a top-level session; sibling agent directories are
/// subagent journals and are excluded from the session list.
final class KimiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        if let home = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session id is the directory two levels above `agents/<id>/wire.jsonl`.
    static func sessionID(forWireFile url: URL) -> String? {
        let agentDir = url.deletingLastPathComponent()          // agents/<agentId>
        let agentsDir = agentDir.deletingLastPathComponent()    // agents
        guard agentsDir.lastPathComponent == "agents" else { return nil }
        let sessionDir = agentsDir.deletingLastPathComponent()  // <sessionId>
        let id = sessionDir.lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// `state.json` sits beside the `agents/` directory.
    static func stateFile(forWireFile url: URL) -> URL {
        url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "wire.jsonl" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent == "main" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard Self.sessionID(forWireFile: url) != nil else { continue }
            guard hasMetadataEnvelope(url) else { continue }
            files.append(url)
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

    private func hasMetadataEnvelope(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 64 * 1024)
        guard let prefix = String(data: data, encoding: .utf8),
              let line = prefix.split(separator: "\n", omittingEmptySubsequences: true).first,
              let lineData = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "metadata" && object["protocol_version"] is String
    }
}
