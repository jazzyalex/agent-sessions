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

extension SessionFileStat {
    /// Stat a single session file, returning nil for non-regular files.
    static func from(_ url: URL) -> SessionFileStat? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        let mtime = Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        let size = Int64(values?.fileSize ?? 0)
        return SessionFileStat(mtime: mtime, size: size)
    }

    /// Build a stat map from a list of files, returning changed files and the full map.
    static func diff(_ files: [URL], against previousByPath: [String: SessionFileStat]) -> (currentByPath: [String: SessionFileStat], changedFiles: [URL]) {
        var currentByPath: [String: SessionFileStat] = [:]
        currentByPath.reserveCapacity(files.count)
        var changedFiles: [URL] = []
        changedFiles.reserveCapacity(files.count)
        for file in files {
            guard let stat = SessionFileStat.from(file) else { continue }
            currentByPath[file.path] = stat
            if previousByPath[file.path] != stat {
                changedFiles.append(file)
            }
        }
        return (currentByPath, changedFiles)
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
        let roots = scanRoots(for: root)
        let fm = FileManager.default

        var found: [URL] = []
        for scanRoot in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: scanRoot.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if let enumerator = fm.enumerator(at: scanRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    // Codex format: rollout-YYYY-MM-DDThh-mm-ss-UUID.jsonl
                    if url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl" {
                        found.append(url)
                    }
                }
            }
        }

        // Sort by filename descending (newest first)
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func scanRoots(for root: URL) -> [URL] {
        var roots = [root]
        roots.append(contentsOf: archivedScanRoots(for: root).filter { !roots.contains($0) })
        return roots
    }

    private func archivedScanRoots(for root: URL) -> [URL] {
        guard root.lastPathComponent == "sessions" else { return [] }
        return [
            root.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }

    func discoverDelta(previousByPath: [String: SessionFileStat], scope: SessionDeltaScope = .recent) -> SessionDiscoveryDelta {
        let files: [URL]
        switch scope {
        case .full:
            files = discoverSessionFiles()
        case .recent:
            files = discoverRecentSessionFiles(dayWindow: 3, previousByPath: previousByPath)
        }

        let (currentByPath, changedFiles) = SessionFileStat.diff(files, against: previousByPath)

        let removedPaths: [String]
        switch scope {
        case .full:
            removedPaths = Array(Set(previousByPath.keys).subtracting(currentByPath.keys))
        case .recent:
            let prefixes = recentDayFolders(dayWindow: 3).map { $0.path }
            let archivedPrefixes = archivedScanRoots(for: sessionsRoot()).map { $0.path }
            let currentArchivedFilenames = Set(currentByPath.keys
                .filter { path in archivedPrefixes.contains { Self.path(path, isWithin: $0) } }
                .map { URL(fileURLWithPath: $0).lastPathComponent })
            removedPaths = previousByPath.keys.filter { oldPath in
                guard currentByPath[oldPath] == nil else { return false }
                let isArchivedPath = archivedPrefixes.contains { Self.path(oldPath, isWithin: $0) }
                if isArchivedPath {
                    return true
                }
                if prefixes.contains(where: { Self.path(oldPath, isWithin: $0) }) {
                    return true
                }
                let filename = URL(fileURLWithPath: oldPath).lastPathComponent
                let rootPath = sessionsRoot().path
                if Self.path(oldPath, isWithin: rootPath),
                   currentArchivedFilenames.contains(filename),
                   !FileManager.default.fileExists(atPath: oldPath) {
                    return true
                }
                return false
            }
        }

        return SessionDiscoveryDelta(
            changedFiles: changedFiles.sorted { $0.lastPathComponent > $1.lastPathComponent },
            removedPaths: removedPaths,
            currentByPath: currentByPath,
            driftDetected: false
        )
    }

    private func discoverRecentSessionFiles(dayWindow: Int, previousByPath: [String: SessionFileStat]) -> [URL] {
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
        found.append(contentsOf: discoverRecentArchivedSessionFiles(dayWindow: dayWindow, previousByPath: previousByPath))
        return found.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func discoverRecentArchivedSessionFiles(dayWindow: Int, previousByPath: [String: SessionFileStat]) -> [URL] {
        let fm = FileManager.default
        let prefixes = recentRolloutFilenamePrefixes(dayWindow: dayWindow)
        guard !prefixes.isEmpty else { return [] }
        let sessionsRootPath = sessionsRoot().path
        let previouslyKnownSessionFilenames = Set(previousByPath.keys
            .filter { Self.path($0, isWithin: sessionsRootPath) }
            .map { URL(fileURLWithPath: $0).lastPathComponent })

        var found: [URL] = []
        for root in archivedScanRoots(for: sessionsRoot()) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("rollout-"),
                      url.pathExtension.lowercased() == "jsonl" else {
                    continue
                }
                let filenameIsRecent = prefixes.contains { url.lastPathComponent.hasPrefix($0) }
                if filenameIsRecent || previousByPath[url.path] != nil {
                    found.append(url)
                    continue
                }
                if previouslyKnownSessionFilenames.contains(url.lastPathComponent) {
                    found.append(url)
                }
            }
        }
        return found
    }

    private static func path(_ path: String, isWithin rootPath: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let normalizedRootPath = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        return normalizedPath == normalizedRootPath || normalizedPath.hasPrefix(normalizedRootPath + "/")
    }

    private func recentRolloutFilenamePrefixes(dayWindow: Int) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let days = max(1, dayWindow)
        var prefixes: [String] = []
        prefixes.reserveCapacity(days)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            prefixes.append(String(format: "rollout-%04d-%02d-%02dT", y, m, d))
        }
        return prefixes
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
}

// MARK: - Claude Code Session Discovery

struct ClaudeDesktopSessionMetadata: Equatable {
    let sessionID: String
    let cliSessionID: String?
    let cwd: String?
    let originCwd: String?
    let worktreePath: String?
    let worktreeName: String?
    let createdAt: Date?
    let lastActivityAt: Date?
    let model: String?
    let title: String?
    let isArchived: Bool
    let source: String
}

struct ClaudeDesktopSessionMetadataReader {
    static let desktopOriginator = "Claude Desktop"

    static func metadata(forTranscript url: URL, transcriptSessionID: String? = nil) -> ClaudeDesktopSessionMetadata? {
        for metadataFile in metadataFileCandidates(forTranscript: url) {
            guard let metadata = readMetadata(at: metadataFile, source: "local-agent-mode"),
                  metadataMatchesTranscript(metadata, transcriptURL: url, transcriptSessionID: transcriptSessionID) else {
                continue
            }
            return metadata
        }
        return nil
    }

    static func metadataFile(forTranscript url: URL, transcriptSessionID: String? = nil) -> URL? {
        for metadataFile in metadataFileCandidates(forTranscript: url) {
            guard let metadata = readMetadata(at: metadataFile, source: "local-agent-mode"),
                  metadataMatchesTranscript(metadata, transcriptURL: url, transcriptSessionID: transcriptSessionID) else {
                continue
            }
            return metadataFile
        }
        return nil
    }

    static func hasMetadataCandidates(forTranscript url: URL) -> Bool {
        !metadataFileCandidates(forTranscript: url).isEmpty
    }

    static func readMetadata(at url: URL, source: String) -> ClaudeDesktopSessionMetadata? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = nonEmptyString(obj["sessionId"] as? String) else {
            return nil
        }

        return ClaudeDesktopSessionMetadata(
            sessionID: sessionID,
            cliSessionID: nonEmptyString(obj["cliSessionId"] as? String),
            cwd: nonEmptyString(obj["cwd"] as? String),
            originCwd: nonEmptyString(obj["originCwd"] as? String),
            worktreePath: nonEmptyString(obj["worktreePath"] as? String),
            worktreeName: nonEmptyString(obj["worktreeName"] as? String),
            createdAt: dateFromMilliseconds(obj["createdAt"]),
            lastActivityAt: dateFromMilliseconds(obj["lastActivityAt"]),
            model: nonEmptyString(obj["model"] as? String),
            title: nonEmptyString(obj["title"] as? String),
            isArchived: (obj["isArchived"] as? Bool) ?? false,
            source: source
        )
    }

    private static func dateFromMilliseconds(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000.0)
        }
        if let string = raw as? String, let value = Double(string) {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        return nil
    }

    private static func nonEmptyString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func metadataFileCandidates(forTranscript url: URL) -> [URL] {
        let components = url.standardizedFileURL.pathComponents
        guard let localIndex = components.lastIndex(where: { $0.hasPrefix("local_") }) else { return [] }

        let localDirPath = NSString.path(withComponents: Array(components[0...localIndex]))
        let localDir = URL(fileURLWithPath: localDirPath, isDirectory: true)
        let localName = localDir.lastPathComponent
        return [
            localDir.deletingPathExtension().appendingPathExtension("json"),
            localDir.deletingLastPathComponent().appendingPathComponent("\(localName).json")
        ]
    }

    private static func metadataMatchesTranscript(_ metadata: ClaudeDesktopSessionMetadata,
                                                  transcriptURL: URL,
                                                  transcriptSessionID: String?) -> Bool {
        guard let cliSessionID = metadata.cliSessionID else { return false }
        if transcriptURL.deletingPathExtension().lastPathComponent == cliSessionID {
            return true
        }
        return transcriptSessionID == cliSessionID
    }
}

private struct ClaudeDiscoveryRoot: Hashable {
    enum Kind: Hashable {
        case standardConfig
        case desktopLocalAgent
    }

    let configRoot: URL
    let scanRoot: URL
    let kind: Kind
}

final class ClaudeSessionDiscovery: SessionDiscovery {
    private let customRoot: String?
    private let includeDesktopRoots: Bool
    private let desktopLocalAgentRoot: URL?

    init(customRoot: String? = nil,
         includeDesktopRoots: Bool = true,
         desktopLocalAgentRoot: URL? = nil) {
        self.customRoot = customRoot
        self.includeDesktopRoots = includeDesktopRoots
        self.desktopLocalAgentRoot = desktopLocalAgentRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    func discoverSessionFiles() -> [URL] {
        var found: [URL] = []
        for root in candidateRoots() {
            found.append(contentsOf: collectSessionFiles(in: root.scanRoot, fileCap: .max).files)
        }

        return dedupe(files: found).sorted { Self.mtime($0) > Self.mtime($1) }
    }

    func hasDiscoverableSessionsRoot() -> Bool {
        !candidateRoots().isEmpty
    }

    func discoverDelta(previousByPath: [String: SessionFileStat], scope: SessionDeltaScope = .recent) -> SessionDiscoveryDelta {
        switch scope {
        case .full:
            let files = discoverSessionFiles()
            let (currentByPath, changedFiles) = diffSessionFiles(files, against: previousByPath)
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
        var selectedRoots: [URL] = []
        for root in candidateRoots() {
            if root.kind == .desktopLocalAgent {
                selectedRoots.append(root.scanRoot)
                continue
            }
            let selectedProjects = topProjectDirectories(under: root.scanRoot, limit: topProjectLimit)
            if selectedProjects.isEmpty {
                selectedRoots.append(root.scanRoot)
            } else {
                selectedRoots.append(contentsOf: selectedProjects)
            }
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
        files = dedupe(files: files)

        let (currentByPath, changedFiles) = diffSessionFiles(files, against: previousByPath)

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

    private func candidateRoots() -> [ClaudeDiscoveryRoot] {
        let fm = FileManager.default
        var roots: [ClaudeDiscoveryRoot] = []

        for configRoot in standardConfigRootCandidates() {
            guard directoryExists(configRoot) else { continue }
            guard customRoot != nil || isValidClaudeRoot(configRoot) else { continue }
            let projectsRoot = configRoot.appendingPathComponent("projects", isDirectory: true)
            let scanRoot = directoryExists(projectsRoot) ? projectsRoot : configRoot
            roots.append(ClaudeDiscoveryRoot(configRoot: configRoot, scanRoot: scanRoot, kind: .standardConfig))
        }

        let defaultDesktopRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        if includeDesktopRoots,
           let desktopRoot = desktopLocalAgentRoot ?? defaultDesktopRoot,
           directoryExists(desktopRoot) {
            roots.append(contentsOf: desktopLocalAgentRoots(under: desktopRoot))
        }

        return dedupe(roots: roots)
    }

    private func standardConfigRootCandidates() -> [URL] {
        if let custom = customRoot, !custom.isEmpty {
            return [expandPath(custom)]
        }

        var roots: [URL] = []
        let env = ProcessInfo.processInfo.environment
        if let multi = env["CLAUDE_CONFIG_DIRS"], !multi.isEmpty {
            roots.append(contentsOf: multi.split(separator: ":").map { expandPath(String($0)) })
        }
        if let single = env["CLAUDE_CONFIG_DIR"], !single.isEmpty {
            roots.append(expandPath(single))
        }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        roots.append(home.appendingPathComponent(".claude", isDirectory: true))

        if let siblings = try? FileManager.default.contentsOfDirectory(at: home,
                                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: []) {
            roots.append(contentsOf: siblings.filter { $0.lastPathComponent.hasPrefix(".claude") })
        }

        return roots
    }

    private func desktopLocalAgentRoots(under root: URL) -> [ClaudeDiscoveryRoot] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: []) else {
            return []
        }

        var roots: [ClaudeDiscoveryRoot] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "uploads" || name == "outputs" || name == "cowork_plugins" || name == "skills-plugin" {
                enumerator.skipDescendants()
                continue
            }
            guard name == "projects",
                  url.deletingLastPathComponent().lastPathComponent == ".claude",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.hasPrefix("local_") else {
                continue
            }
            let configRoot = url.deletingLastPathComponent()
            roots.append(ClaudeDiscoveryRoot(configRoot: configRoot, scanRoot: url, kind: .desktopLocalAgent))
            enumerator.skipDescendants()
        }
        return roots
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

    private func diffSessionFiles(_ files: [URL],
                                  against previousByPath: [String: SessionFileStat]) -> (currentByPath: [String: SessionFileStat], changedFiles: [URL]) {
        var currentByPath: [String: SessionFileStat] = [:]
        currentByPath.reserveCapacity(files.count)
        var changedFiles: [URL] = []
        changedFiles.reserveCapacity(files.count)
        for file in files {
            guard let stat = discoveryStat(for: file) else { continue }
            currentByPath[file.path] = stat
            if previousByPath[file.path] != stat {
                changedFiles.append(file)
            }
        }
        return (currentByPath, changedFiles)
    }

    private func discoveryStat(for file: URL) -> SessionFileStat? {
        guard let transcriptStat = SessionFileStat.from(file) else { return nil }
        guard let metadataFile = desktopMetadataFile(forTranscript: file),
              let metadataStat = SessionFileStat.from(metadataFile) else {
            return transcriptStat
        }
        return SessionFileStat(
            mtime: max(transcriptStat.mtime, metadataStat.mtime),
            size: transcriptStat.size + metadataStat.size
        )
    }

    private func desktopMetadataFile(forTranscript file: URL) -> URL? {
        if let metadataFile = ClaudeDesktopSessionMetadataReader.metadataFile(forTranscript: file) {
            return metadataFile
        }
        guard ClaudeDesktopSessionMetadataReader.hasMetadataCandidates(forTranscript: file),
              let sessionID = transcriptSessionID(in: file) else {
            return nil
        }
        return ClaudeDesktopSessionMetadataReader.metadataFile(forTranscript: file, transcriptSessionID: sessionID)
    }

    private func transcriptSessionID(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let readLimit = 64 * 1024
        guard let data = try? handle.read(upToCount: readLimit),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(64) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = obj["sessionId"] as? String,
                  !sessionID.isEmpty else {
                continue
            }
            return sessionID
        }
        return nil
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func effectiveScanRoot() -> URL {
        let root = sessionsRoot()
        let projectsRoot = root.appendingPathComponent("projects")
        var isProjectsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsRoot.path, isDirectory: &isProjectsDir), isProjectsDir.boolValue {
            return projectsRoot
        }
        return root
    }

    private func dedupe(roots: [ClaudeDiscoveryRoot]) -> [ClaudeDiscoveryRoot] {
        var seen = Set<String>()
        var out: [ClaudeDiscoveryRoot] = []
        for root in roots {
            let key = root.scanRoot.resolvingSymlinksInPath().path
            if seen.insert(key).inserted {
                out.append(root)
            }
        }
        return out
    }

    private func dedupe(files: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for file in files {
            let key = file.resolvingSymlinksInPath().path
            if seen.insert(key).inserted {
                out.append(file)
            }
        }
        return out
    }

    private func isValidClaudeRoot(_ root: URL) -> Bool {
        directoryExists(root.appendingPathComponent("projects", isDirectory: true)) ||
        FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path) ||
        FileManager.default.fileExists(atPath: root.appendingPathComponent("history.jsonl").path) ||
        directoryExists(root.appendingPathComponent("todos", isDirectory: true))
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func expandPath(_ raw: String) -> URL {
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
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

        // Legacy layout: flat *.jsonl files at the root
        // Current layout (v1.0.11+): <uuid>/events.jsonl subdirectories
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "jsonl" {
                    found.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let eventsFile = url.appendingPathComponent("events.jsonl")
                    if fm.fileExists(atPath: eventsFile.path) {
                        found.append(eventsFile)
                    }
                }
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
