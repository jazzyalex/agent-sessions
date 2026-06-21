import Foundation
import CryptoKit

/// Parser for Antigravity markdown artifacts.
final class GeminiSessionParser {
    /// Preview-only parse for list indexing. Builds a lightweight session with empty events.
    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        guard url.pathExtension.lowercased() == "md" else { return nil }
        return parseAntigravityMarkdown(at: url, forcedID: forcedID, includeEvents: false)
    }

    /// Full parse that normalizes an Antigravity markdown artifact into a single transcript event.
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        guard url.pathExtension.lowercased() == "md" else { return nil }
        return parseAntigravityMarkdown(at: url, forcedID: forcedID, includeEvents: true)
    }

    private static func parseAntigravityMarkdown(at url: URL, forcedID: String?, includeEvents: Bool) -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime
        let sid = forcedID ?? antigravityConversationID(from: url) ?? sha256(path: url.path)
        let title = firstMarkdownHeading(in: trimmed)
            ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").capitalized

        let events: [SessionEvent]
        if includeEvents {
            events = [
                SessionEvent(
                    id: sid + "-0001",
                    timestamp: mtime,
                    kind: .assistant,
                    role: "assistant",
                    text: trimmed,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: ""
                )
            ]
        } else {
            events = []
        }

        return Session(id: sid,
                       source: .antigravity,
                       startTime: ctime,
                       endTime: mtime,
                       model: nil,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: 1,
                       events: events,
                       cwd: nil,
                       repoName: nil,
                       lightweightTitle: title)
    }

    private static func antigravityConversationID(from url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty else { return nil }
        return parent
    }

    private static func firstMarkdownHeading(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func sha256(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }
}
