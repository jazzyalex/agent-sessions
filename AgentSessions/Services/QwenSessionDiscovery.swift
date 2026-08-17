import Foundation

/// Discovers Qwen Code chat transcripts under `~/.qwen/projects`.
///
/// Qwen 0.21.13's installed writer stores one `<session-id>.jsonl` file in each project's
/// `chats` directory. CLI-archived transcripts live one level deeper in
/// `chats/archive`; unrelated JSONL files elsewhere below `projects` are not
/// sessions and are deliberately excluded.
final class QwenSessionDiscovery: SessionDiscovery {
    enum TranscriptLocation: Equatable {
        case active
        case archived
    }

    private let customRoot: String?
    private let homeDirectory: URL
    private let environment: [String: String]

    init(customRoot: String? = nil,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.customRoot = customRoot
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            return normalizedProjectsRoot(expand(customRoot))
        }
        if let qwenHome = environment["QWEN_HOME"], !qwenHome.isEmpty {
            return normalizedProjectsRoot(expand(qwenHome))
        }
        return homeDirectory
            .appendingPathComponent(".qwen", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func sessionID(forTranscript url: URL) -> String? {
        guard url.pathExtension.lowercased() == "jsonl" else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        // Match Qwen 0.21.13's SESSION_FILE_PATTERN exactly: compact legacy IDs
        // and canonical UUIDs are both accepted, while arbitrary JSONL names are not.
        let bytes = id.utf8
        guard (32...36).contains(bytes.count),
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...70).contains(byte)
                      || (97...102).contains(byte)
                      || byte == 45
              }) else { return nil }
        return id
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard Self.transcriptLocation(for: url, projectsRoot: root) != nil,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let sessionID = Self.sessionID(forTranscript: url),
                  hasValidHead(url, expectedSessionID: sessionID) else {
                continue
            }
            files.append(url)
        }

        return files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.path > $1.path
        }
    }

    private func expand(_ path: String) -> URL {
        let expanded = UserPathExpansion.expand(path, relativeTo: homeDirectory)
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func normalizedProjectsRoot(_ root: URL) -> URL {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return projects
        }
        return root
    }

    /// Matches the installed reader's exact storage layout. Recursive
    /// enumeration is still useful, but a nested lookalike such as
    /// `<project>/backup/chats/<id>.jsonl` is not a Qwen session and cannot be
    /// resolved by `qwen --resume`.
    static func transcriptLocation(for url: URL, projectsRoot: URL) -> TranscriptLocation? {
        guard sessionID(forTranscript: url) != nil else { return nil }

        let rootComponents = projectsRoot.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        let relative = Array(fileComponents.dropFirst(rootComponents.count))
        if relative.count == 3, relative[1] == "chats" {
            return .active
        }
        if relative.count == 4, relative[1] == "chats", relative[2] == "archive" {
            return .archived
        }
        return nil
    }

    /// Qwen identifies a session by both its session-ID filename and `sessionId`
    /// in every record. Validate the first complete line so an unrelated JSONL
    /// file with a plausible name cannot become a session.
    private func hasValidHead(_ url: URL, expectedSessionID: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        var data = Data()
        let newline = Data([0x0A])
        while data.count < 1_048_576 {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if let range = data.range(of: newline) {
                data = data.subdata(in: data.startIndex..<range.lowerBound)
                break
            }
        }

        guard !data.isEmpty, let line = String(data: data, encoding: .utf8),
              let object = QwenJSONL.objects(inPhysicalLine: line).first else { return false }
        return QwenSessionParser.isValidHeadObject(object, expectedSessionID: expectedSessionID)
    }
}
