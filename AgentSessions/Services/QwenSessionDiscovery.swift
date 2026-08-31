import Foundation

/// Discovers Qwen Code chat transcripts under `~/.qwen/projects`.
///
/// The writer read from the installed Qwen Code 0.21.13 package stores one
/// `<session-id>.jsonl` file in each project's
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
        Self.resolvedSessionsRoot(
            customRoot: customRoot,
            homeDirectory: homeDirectory,
            environment: environment,
            directoryExists: { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        )
    }

    /// The single root resolution shared by discovery, `SessionSourceDescriptor.qwen`'s
    /// availability closure, and `QwenResumeEligibility`. All three must agree: if
    /// discovery falls back and the others do not, the list fills from one root while
    /// availability and resume eligibility are computed against another.
    ///
    /// `QWEN_HOME` is read by 0.22.3 through `getGlobalQwenDir()`; 0.14.3 ignores it and
    /// goes straight to `~/.qwen`. A 0.14.x user with `QWEN_HOME` exported for an
    /// unrelated reason therefore has sessions under `~/.qwen/projects` that we would
    /// otherwise never look at, and sees zero rows. Provenance for the version split:
    /// discussion QwenLM/qwen-code#10579, recorded in
    /// `docs/superpowers/plans/2026-08-31-qwen-0.22-format-brief.md`. No 0.22.x
    /// transcript has been captured.
    ///
    /// The fallback triggers on `$QWEN_HOME/projects` not being a directory, deliberately
    /// not on "the root yields no sessions": the descriptor applies this same rule inside
    /// `isAvailable` and must not enumerate. The cost is that a `QWEN_HOME` whose
    /// `projects` directory exists but is empty keeps winning — pinned by
    /// `testEmptyQwenHomeProjectsRootDoesNotFallBackToDefaultRoot`.
    ///
    /// `QWEN_HOME` requires a `projects` child; an explicit `customRoot` still accepts
    /// either `<root>/projects` or `<root>` itself. That split is intentional. Requiring
    /// `projects` matches the CLI's own layout under `getGlobalQwenDir()`, while a
    /// hand-set path is a direct instruction and may point straight at a copied projects
    /// root. Without it the fallback would never fire for the user it targets, whose
    /// `$QWEN_HOME/projects` is absent and whose `$QWEN_HOME` therefore resolves to
    /// itself and exists.
    static func resolvedSessionsRoot(
        customRoot: String?,
        homeDirectory: URL,
        environment: [String: String],
        directoryExists: (URL) -> Bool
    ) -> URL {
        func expand(_ path: String) -> URL {
            URL(
                fileURLWithPath: UserPathExpansion.expand(path, relativeTo: homeDirectory),
                isDirectory: true
            )
        }

        let defaultRoot = homeDirectory
            .appendingPathComponent(".qwen", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        if let customRoot, !customRoot.isEmpty {
            let root = expand(customRoot)
            let projects = root.appendingPathComponent("projects", isDirectory: true)
            return directoryExists(projects) ? projects : root
        }

        if let qwenHome = environment["QWEN_HOME"], !qwenHome.isEmpty {
            let projects = expand(qwenHome).appendingPathComponent("projects", isDirectory: true)
            return directoryExists(projects) ? projects : defaultRoot
        }

        return defaultRoot
    }

    static func sessionID(forTranscript url: URL) -> String? {
        guard url.pathExtension.lowercased() == "jsonl" else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        // Matches the SESSION_FILE_PATTERN read from the installed 0.21.13 package
        // source (no 0.21.13 transcript was captured; the matrix pins 0.14.3): compact legacy IDs
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
