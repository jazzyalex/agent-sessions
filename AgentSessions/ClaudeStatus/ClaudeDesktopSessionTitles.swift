import Foundation

/// Reads the session titles shown in the Claude Desktop app.
///
/// Desktop keeps conversation metadata outside the CLI transcript, in
/// `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`,
/// linked to the transcript by `cliSessionId`. That `title` is what the user
/// actually sees in the app (whether they renamed it or Claude generated it),
/// so the runway prefers it over anything derivable from the transcript.
enum ClaudeDesktopSessionTitles {
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Map of CLI transcript session id -> Desktop title (trimmed, non-empty).
    static func map(root: URL? = nil, fileManager: FileManager = .default) -> [String: String] {
        let rootURL = root ?? defaultRoot()
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return [:]
        }

        // Last-writer-wins per cliSessionId, preferring the most recently
        // modified record if Desktop ever leaves duplicates behind.
        var titles: [String: (title: String, modifiedAt: Date)] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = (obj["cliSessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cli.isEmpty,
                  let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let existing = titles[cli], existing.modifiedAt >= modifiedAt { continue }
            titles[cli] = (title, modifiedAt)
        }
        return titles.mapValues { $0.title }
    }
}
