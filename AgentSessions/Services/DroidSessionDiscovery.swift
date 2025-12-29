import Foundation

/// Session discovery for Droid (Factory) sessions.
///
/// Droid data can appear in two places:
/// - Interactive session store: `~/.factory/sessions/**/<sessionId>.jsonl`
/// - Exported/redirected stream-json logs: `~/.factory/projects/**/*.jsonl` (best-effort)
final class DroidSessionDiscovery: SessionDiscovery {
    private let customSessionsRoot: String?
    private let customProjectsRoot: String?

    init(customSessionsRoot: String? = nil, customProjectsRoot: String? = nil) {
        self.customSessionsRoot = customSessionsRoot
        self.customProjectsRoot = customProjectsRoot
    }

    func sessionsRoot() -> URL {
        let fm = FileManager.default
        if let customSessionsRoot, !customSessionsRoot.isEmpty {
            let expanded = (customSessionsRoot as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if url.lastPathComponent == "sessions" { return url }
            let child = url.appendingPathComponent("sessions", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                return child
            }
            return url
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func projectsRoot() -> URL {
        let fm = FileManager.default
        if let customProjectsRoot, !customProjectsRoot.isEmpty {
            let expanded = (customProjectsRoot as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if url.lastPathComponent == "projects" { return url }
            let child = url.appendingPathComponent("projects", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                return child
            }
            return url
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []

        // A) Interactive session store: include all JSONL under sessions root (parser will validate).
        let sessions = sessionsRoot()
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: sessions.path, isDirectory: &isDir), isDir.boolValue {
            if let enumerator = fm.enumerator(at: sessions, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "jsonl" else { continue }
                    out.append(url)
                }
            }
        }

        // B) Best-effort stream-json logs: only include likely candidates to avoid false positives.
        let projects = projectsRoot()
        var isProjectsDir: ObjCBool = false
        if fm.fileExists(atPath: projects.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue {
            if let enumerator = fm.enumerator(at: projects, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "jsonl" else { continue }
                    guard DroidSessionParser.looksLikeStreamJSONFile(url: url) else { continue }
                    out.append(url)
                }
            }
        }

        return out.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}

