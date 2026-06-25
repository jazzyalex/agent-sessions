import Foundation

/// Discovers currently-active Claude sessions by scanning `~/.claude/projects`,
/// mirroring `CodexRunwayRecentSessionScanner` for the Codex side. This lets the
/// runway surface sessions that the HUD presence tracker may not have resolved
/// into rows yet.
///
/// Claude keeps one JSONL file per session and nests subagents in-file
/// (`isSidechain`), so there is no cross-file parent/child merging like Codex.
enum ClaudeRunwayRecentSessionScanner {
    static let maximumFileAge: TimeInterval = 30 * 60
    /// A session row disappears this long after its last logged line. Matches
    /// the token parser's window so the whole row (not just the burn) clears
    /// promptly once a session stops.
    static let maximumActiveSampleAge: TimeInterval = 15
    static let maximumFiles = 12
    static let maximumMetadataFiles = 80

    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func identities(root: URL? = nil,
                           now: Date = Date(),
                           fileManager: FileManager = .default) -> [RunwaySessionIdentity] {
        let rootURL = root ?? defaultRoot()
        let cutoff = now.addingTimeInterval(-maximumFileAge)
        var candidates: [(url: URL, modifiedAt: Date)] = []

        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }
            candidates.append((url, modifiedAt))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumMetadataFiles)
            .compactMap { candidate(for: $0.url, now: now) }
            .prefix(maximumFiles)
            .map { $0 }
    }

    private static func candidate(for url: URL, now: Date) -> RunwaySessionIdentity? {
        let metadata = metadata(from: url)
        if ClaudeProbeConfig.isProbeWorkingDirectory(metadata.cwd) {
            return nil
        }
        guard hasActiveTail(url: url, now: now) else { return nil }
        let fallbackID = url.deletingPathExtension().lastPathComponent
        return RunwaySessionIdentity(
            id: metadata.sessionID ?? fallbackID,
            displayName: displayName(metadata: metadata, fallbackID: fallbackID),
            isGoal: false,
            logPaths: [url.path]
        )
    }

    private static func hasActiveTail(url: URL, now: Date) -> Bool {
        guard let data = tailData(path: url.path, maxBytes: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(200)
        for line in lines.reversed() {
            guard let obj = jsonObject(String(line)),
                  let capturedAt = flexibleDate(obj["timestamp"]) else {
                continue
            }
            return now.timeIntervalSince(capturedAt) <= maximumActiveSampleAge
        }
        return false
    }

    private static func metadata(from url: URL) -> SessionMetadata {
        guard let data = headData(path: url.path, maxBytes: 96 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return SessionMetadata()
        }
        var metadata = SessionMetadata()
        // Scan a healthy slice of the head: ai-title/custom-title records are
        // usually written a few turns in, after the first user message.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(160) {
            guard let obj = jsonObject(String(line)) else { continue }
            if metadata.sessionID == nil { metadata.sessionID = string(obj["sessionId"]) }
            if metadata.cwd == nil { metadata.cwd = string(obj["cwd"]) }
            switch string(obj["type"]) {
            case "custom-title":
                // From /rename — authoritative, matches the app's title logic.
                if let title = string(obj["customTitle"]), !title.isEmpty { metadata.customTitle = title }
            case "ai-title":
                // Generated title; this is what Claude usually shows as the name.
                if metadata.aiTitle == nil, let title = string(obj["aiTitle"]), !title.isEmpty {
                    metadata.aiTitle = title
                }
            case "user":
                if metadata.firstUserText == nil,
                   let message = obj["message"] as? [String: Any],
                   string(message["role"]) == "user",
                   let text = userText(from: message["content"]),
                   !isSetupContextText(text) {
                    metadata.firstUserText = text
                }
            default:
                break
            }
        }
        return metadata
    }

    private static func displayName(metadata: SessionMetadata, fallbackID: String) -> String {
        // Mirror ClaudeSessionParser's preference: custom-title > ai-title >
        // first prompt > project folder. (Desktop-only titles that never land
        // in the transcript can't be recovered here.)
        for candidate in [metadata.customTitle, metadata.aiTitle, metadata.firstUserText] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return compact(text)
            }
        }
        if let cwd = metadata.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            return compact(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        return compact(fallbackID)
    }

    private static func userText(from content: Any?) -> String? {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if string(block["type"]) == "text", let text = string(block["text"]) {
                    return text
                }
            }
        }
        return nil
    }

    private static func isSetupContextText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let prefixes = ["<system-reminder>", "<command-", "<local-command", "Caveat:",
                        "# CLAUDE.md", "# AGENTS.md", "<environment_context>"]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func compact(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > 28 else { return collapsed }
        return String(collapsed.prefix(27)) + "…"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func flexibleDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private static func headData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    private static func tailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private struct SessionMetadata {
        var sessionID: String?
        var cwd: String?
        var firstUserText: String?
        var customTitle: String?
        var aiTitle: String?
    }
}
