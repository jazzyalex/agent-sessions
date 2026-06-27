import Foundation

/// Reads the session titles shown in the Claude Desktop app.
///
/// Desktop keeps conversation metadata outside the CLI transcript, in
/// `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`,
/// linked to the transcript by `cliSessionId`. That `title` is what the user
/// actually sees in the app (whether they renamed it or Claude generated it),
/// so the runway prefers it over anything derivable from the transcript.

struct ClaudeDesktopSidecarRecord: Equatable {
    let cliSessionID: String
    let title: String?
    let isArchived: Bool
    let autoArchiveExempt: Bool
    let sidecarPath: String
    let modifiedAt: Date
}

enum ClaudeDesktopSessionTitles {
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Map of CLI transcript session id -> full sidecar record. Last-writer-wins by mtime.
    static func records(root: URL? = nil, fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord] {
        let rootURL = root ?? defaultRoot()
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return [:]
        }

        var out: [String: ClaudeDesktopSidecarRecord] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = (obj["cliSessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cli.isEmpty else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let existing = out[cli], existing.modifiedAt >= modifiedAt { continue }
            let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out[cli] = ClaudeDesktopSidecarRecord(
                cliSessionID: cli,
                title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
                isArchived: (obj["isArchived"] as? Bool) ?? false,
                autoArchiveExempt: (obj["autoArchiveExempt"] as? Bool) ?? false,
                sidecarPath: url.path,
                modifiedAt: modifiedAt
            )
        }
        return out
    }

    /// Map of CLI transcript session id -> Desktop title (trimmed, non-empty).
    static func map(root: URL? = nil, fileManager: FileManager = .default) -> [String: String] {
        var titles: [String: String] = [:]
        for (cli, rec) in records(root: root, fileManager: fileManager) {
            if let t = rec.title, !t.isEmpty { titles[cli] = t }
        }
        return titles
    }
}
