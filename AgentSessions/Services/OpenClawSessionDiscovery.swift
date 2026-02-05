import Foundation

/// Discovery for OpenClaw (and legacy Clawdbot) JSONL session transcripts.
///
/// Expected layouts:
/// - ~/.openclaw/agents/<agentId>/sessions/*.jsonl
/// - ~/.clawdbot/agents/<agentId>/sessions/*.jsonl   (legacy)
/// - $OPENCLAW_STATE_DIR/agents/<agentId>/sessions/*.jsonl
final class OpenClawSessionDiscovery: SessionDiscovery {
    private let customRoot: String?
    private let includeDeleted: Bool

    init(customRoot: String? = nil, includeDeleted: Bool = false) {
        self.customRoot = customRoot
        self.includeDeleted = includeDeleted
    }

    func sessionsRoot() -> URL {
        let fm = FileManager.default

        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            return url
        }

        if let env = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }

        let home = fm.homeDirectoryForCurrentUser
        let openclaw = home.appendingPathComponent(".openclaw", isDirectory: true)
        if isValidStateRoot(openclaw) { return openclaw }

        let clawdbot = home.appendingPathComponent(".clawdbot", isDirectory: true)
        if isValidStateRoot(clawdbot) { return clawdbot }

        // Default to the canonical OpenClaw location even if it doesn't exist yet.
        return openclaw
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        let agentsRoot: URL = {
            if root.lastPathComponent == "agents" { return root }
            return root.appendingPathComponent("agents", isDirectory: true)
        }()

        var isAgentsDir: ObjCBool = false
        guard fm.fileExists(atPath: agentsRoot.path, isDirectory: &isAgentsDir), isAgentsDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: agentsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "sessions" else { continue }

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }

                if let sessionEnum = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
                    for case let file as URL in sessionEnum {
                        let name = file.lastPathComponent
                        if name.hasSuffix(".jsonl.lock") { continue }
                        if name.hasSuffix(".jsonl") {
                            found.append(file)
                            continue
                        }
                        if includeDeleted, name.contains(".jsonl.deleted.") {
                            found.append(file)
                        }
                    }
                }
            }
        }

        // Newest first (mtime)
        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.lastPathComponent > $1.lastPathComponent
        }
    }

    private func isValidStateRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let agents = url.appendingPathComponent("agents", isDirectory: true)
        var isAgents: ObjCBool = false
        return fm.fileExists(atPath: agents.path, isDirectory: &isAgents) && isAgents.boolValue
    }
}

