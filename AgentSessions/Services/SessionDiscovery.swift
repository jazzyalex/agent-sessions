import Foundation

/// Protocol for discovering session files from different sources
protocol SessionDiscovery {
    /// Root directory to scan for sessions
    func sessionsRoot() -> URL

    /// Find all session files in the root directory
    func discoverSessionFiles() -> [URL]
}

struct SessionFileStat: Equatable {
    let mtime: Int64
    let size: Int64
}

enum SessionDeltaScope {
    case recent
    case full
}

struct SessionDiscoveryDelta {
    let changedFiles: [URL]
    let removedPaths: [String]
    let currentByPath: [String: SessionFileStat]
    let driftDetected: Bool

    var isEmpty: Bool {
        changedFiles.isEmpty && removedPaths.isEmpty
    }
}

// MARK: - Codex Session Discovery

final class CodexSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                // Codex format: rollout-YYYY-MM-DDThh-mm-ss-UUID.jsonl
                if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl" {
                    found.append(url)
                }
            }
        }

        // Sort by filename descending (newest first)
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func discoverDelta(previousByPath: [String: SessionFileStat], scope: SessionDeltaScope = .recent) -> SessionDiscoveryDelta {
        let files: [URL]
        switch scope {
        case .full:
            files = discoverSessionFiles()
        case .recent:
            files = discoverRecentSessionFiles(dayWindow: 3)
        }

        var currentByPath: [String: SessionFileStat] = [:]
        currentByPath.reserveCapacity(files.count)
        var changedFiles: [URL] = []
        changedFiles.reserveCapacity(files.count)

        for file in files {
            guard let stat = Self.fileStat(for: file) else { continue }
            currentByPath[file.path] = stat
            if previousByPath[file.path] != stat {
                changedFiles.append(file)
            }
        }

        let removedPaths: [String]
        switch scope {
        case .full:
            removedPaths = Array(Set(previousByPath.keys).subtracting(currentByPath.keys))
        case .recent:
            let prefixes = recentDayFolders(dayWindow: 3).map { $0.path }
            removedPaths = previousByPath.keys.filter { oldPath in
                guard currentByPath[oldPath] == nil else { return false }
                return prefixes.contains(where: { oldPath.hasPrefix($0 + "/") || oldPath == $0 })
            }
        }

        return SessionDiscoveryDelta(
            changedFiles: changedFiles.sorted { $0.lastPathComponent > $1.lastPathComponent },
            removedPaths: removedPaths,
            currentByPath: currentByPath,
            driftDetected: false
        )
    }

    private func discoverRecentSessionFiles(dayWindow: Int) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for folder in recentDayFolders(dayWindow: dayWindow) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let items = try? fm.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else {
                continue
            }
            for file in items {
                guard file.lastPathComponent.hasPrefix("rollout-"),
                      file.pathExtension.lowercased() == "jsonl" else { continue }
                found.append(file)
            }
        }
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func recentDayFolders(dayWindow: Int) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let root = sessionsRoot()
        let now = Date()
        let days = max(1, dayWindow)
        var out: [URL] = []
        out.reserveCapacity(days)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            out.append(
                root
                    .appendingPathComponent(String(format: "%04d", y))
                    .appendingPathComponent(String(format: "%02d", m))
                    .appendingPathComponent(String(format: "%02d", d))
            )
        }
        return out
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let mtime = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let size = Int64(values?.fileSize ?? 0)
        return SessionFileStat(mtime: mtime, size: size)
    }
}

// MARK: - Claude Code Session Discovery

final class ClaudeSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // Claude Code stores sessions under ~/.claude/projects/<project>/... by default.
        // Prefer that subtree to avoid picking up unrelated JSONL (e.g., history.jsonl).
        let projectsRoot = root.appendingPathComponent("projects")
        let scanRoot: URL = {
            var isProjectsDir: ObjCBool = false
            if fm.fileExists(atPath: projectsRoot.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue {
                return projectsRoot
            }
            return root
        }()

        var found: [URL] = []

        // Scan for .jsonl and .ndjson files (sessions) under scan root
        if let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "jsonl" || ext == "ndjson" {
                    found.append(url)
                }
            }
        }

        // Sort by modification time descending (newest first)
        return found.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
                             (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
    }

    func discoverDelta(previousByPath: [String: SessionFileStat], scope: SessionDeltaScope = .recent) -> SessionDiscoveryDelta {
        switch scope {
        case .full:
            let files = discoverSessionFiles()
            var currentByPath: [String: SessionFileStat] = [:]
            currentByPath.reserveCapacity(files.count)
            var changedFiles: [URL] = []
            changedFiles.reserveCapacity(files.count)
            for file in files {
                guard let stat = Self.fileStat(for: file) else { continue }
                currentByPath[file.path] = stat
                if previousByPath[file.path] != stat {
                    changedFiles.append(file)
                }
            }
            let removed = Array(Set(previousByPath.keys).subtracting(currentByPath.keys))
            return SessionDiscoveryDelta(
                changedFiles: changedFiles.sorted { Self.mtime($0) > Self.mtime($1) },
                removedPaths: removed,
                currentByPath: currentByPath,
                driftDetected: false
            )
        case .recent:
            return discoverRecentDelta(previousByPath: previousByPath, topProjectLimit: 8, fileCapPerProject: 800)
        }
    }

    private func discoverRecentDelta(previousByPath: [String: SessionFileStat],
                                     topProjectLimit: Int,
                                     fileCapPerProject: Int) -> SessionDiscoveryDelta {
        let root = sessionsRoot()
        let fm = FileManager.default
        let projectsRoot = root.appendingPathComponent("projects")
        let scanRoot: URL = {
            var isProjectsDir: ObjCBool = false
            if fm.fileExists(atPath: projectsRoot.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue {
                return projectsRoot
            }
            return root
        }()

        let selectedProjects = topProjectDirectories(under: scanRoot, limit: topProjectLimit)
        var selectedRoots = selectedProjects
        if selectedRoots.isEmpty {
            selectedRoots = [scanRoot]
        }

        var files: [URL] = []
        var driftDetected = false
        for dir in selectedRoots {
            let collected = collectSessionFiles(in: dir, fileCap: fileCapPerProject)
            files.append(contentsOf: collected.files)
            if collected.hitCap {
                driftDetected = true
            }
        }

        var currentByPath: [String: SessionFileStat] = [:]
        currentByPath.reserveCapacity(files.count)
        var changedFiles: [URL] = []
        changedFiles.reserveCapacity(files.count)
        for file in files {
            guard let stat = Self.fileStat(for: file) else { continue }
            currentByPath[file.path] = stat
            if previousByPath[file.path] != stat {
                changedFiles.append(file)
            }
        }

        let removed = previousByPath.keys.filter { oldPath in
            guard currentByPath[oldPath] == nil else { return false }
            return selectedRoots.contains(where: { oldPath.hasPrefix($0.path + "/") || oldPath == $0.path })
        }

        return SessionDiscoveryDelta(
            changedFiles: changedFiles.sorted { Self.mtime($0) > Self.mtime($1) },
            removedPaths: removed,
            currentByPath: currentByPath,
            driftDetected: driftDetected
        )
    }

    private func topProjectDirectories(under root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        let dirs = children.filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        let sorted = dirs.sorted { Self.mtime($0) > Self.mtime($1) }
        return Array(sorted.prefix(max(1, limit)))
    }

    private func collectSessionFiles(in root: URL, fileCap: Int) -> (files: [URL], hitCap: Bool) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return ([], false)
        }
        var out: [URL] = []
        var visited = 0
        var hitCap = false
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            visited += 1
            if visited > fileCap {
                hitCap = true
                break
            }
            let ext = file.pathExtension.lowercased()
            if ext == "jsonl" || ext == "ndjson" {
                out.append(file)
            }
        }
        return (out, hitCap)
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func fileStat(for url: URL) -> SessionFileStat? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let mtime = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let size = Int64(values?.fileSize ?? 0)
        return SessionFileStat(mtime: mtime, size: size)
    }
}

// MARK: - Copilot CLI Session Discovery

/// Discovery for GitHub Copilot CLI agent sessions.
/// Default layout: ~/.copilot/session-state/<sessionId>.jsonl
final class CopilotSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        let fm = FileManager.default
        if let custom = customRoot, !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)

            // Allow users to pick either:
            // - ~/.copilot                      (config root)
            // - ~/.copilot/session-state         (sessions root)
            // - any folder that directly contains *.jsonl session-state files
            if url.lastPathComponent == "session-state" { return url }
            let child = url.appendingPathComponent("session-state", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                return child
            }
            return url
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var found: [URL] = []
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                found.append(url)
            }
        }

        // Sort by file modification time descending (newest first)
        return found.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}
