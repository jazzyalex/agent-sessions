import Foundation

/// Discovers CodeBuddy / WorkBuddy session JSONL files under each product's `projects/` tree.
///
/// Observed layouts (2026-04):
/// - `~/.codebuddy/projects/<path-encoding>/<uuid>.jsonl` (+ optional `<uuid>/subagents/*.jsonl`)
/// - `~/.workbuddy/projects/<path-encoding>/<session>.jsonl`
///
/// Tool artifact directories such as `tool-results/` are skipped — they are not conversation transcripts.
final class BuddySessionDiscovery {
    private let codebuddyProjectsOverride: String?
    private let workbuddyProjectsOverride: String?
    private let scanCodebuddy: Bool
    private let scanWorkbuddy: Bool

    /// - Parameters:
    ///   - scanCodebuddy: When false, no CodeBuddy roots are scanned (used by the WorkBuddy-only indexer).
    ///   - scanWorkbuddy: When false, no WorkBuddy roots are scanned (used by the CodeBuddy-only indexer).
    init(
        codebuddyProjectsRoot: String? = nil,
        workbuddyProjectsRoot: String? = nil,
        scanCodebuddy: Bool = true,
        scanWorkbuddy: Bool = true
    ) {
        self.codebuddyProjectsOverride = codebuddyProjectsRoot
        self.workbuddyProjectsOverride = workbuddyProjectsRoot
        self.scanCodebuddy = scanCodebuddy
        self.scanWorkbuddy = scanWorkbuddy
    }

    static func defaultCodebuddyProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codebuddy/projects")
    }

    static func defaultWorkbuddyProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/projects")
    }

    func projectRoots() -> [URL] {
        var roots: [URL] = []
        if scanCodebuddy {
            if let o = codebuddyProjectsOverride, !o.isEmpty {
                roots.append(URL(fileURLWithPath: o))
            } else {
                roots.append(Self.defaultCodebuddyProjectsRoot())
            }
        }
        if scanWorkbuddy {
            if let o = workbuddyProjectsOverride, !o.isEmpty {
                roots.append(URL(fileURLWithPath: o))
            } else {
                roots.append(Self.defaultWorkbuddyProjectsRoot())
            }
        }
        return roots
    }

    func discoverSessionFiles() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        found.reserveCapacity(256)
        for root in projectRoots() {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                let path = url.path
                if path.contains("/tool-results/") { continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "jsonl" else { continue }
                let rv = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard rv?.isRegularFile == true else { continue }
                found.append(url)
            }
        }
        var seen = Set<String>()
        var unique: [URL] = []
        unique.reserveCapacity(found.count)
        for u in found {
            let key = u.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { continue }
            unique.append(u)
        }
        return unique.sorted { Self.mtime($0) > Self.mtime($1) }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
