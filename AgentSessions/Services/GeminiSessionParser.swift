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
        let sid = forcedID ?? GeminiSessionIDHelper.artifactID(fromArtifactURL: url) ?? sha256(path: url.path)
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

        let cwd = inferredWorkingDirectory(for: url, markdownText: trimmed)

        return Session(id: sid,
                       source: .antigravity,
                       startTime: ctime,
                       endTime: mtime,
                       model: nil,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: 1,
                       events: events,
                       cwd: cwd,
                       repoName: nil,
                       lightweightTitle: title)
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

    private static func inferredWorkingDirectory(for artifactURL: URL, markdownText: String) -> String? {
        if let cwd = inferredWorkingDirectory(fromMarkdown: markdownText) {
            return cwd
        }

        let directory = artifactURL.deletingLastPathComponent()
        guard let siblings = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                                          options: [.skipsHiddenFiles]) else {
            return nil
        }

        for sibling in siblings.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard sibling != artifactURL,
                  sibling.pathExtension.lowercased() == "md",
                  (try? sibling.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: sibling, encoding: .utf8),
                  let cwd = inferredWorkingDirectory(fromMarkdown: text) else {
                continue
            }
            return cwd
        }

        return nil
    }

    private static func inferredWorkingDirectory(fromMarkdown text: String) -> String? {
        for path in localPaths(in: text) {
            if let root = nearestGitRoot(forLocalPath: path) {
                return root
            }
        }
        return nil
    }

    private static func localPaths(in text: String) -> [String] {
        var out: [String] = []
        out.append(contentsOf: localFileURLPaths(in: text))
        out.append(contentsOf: absoluteMarkdownLinkPaths(in: text))
        return out
    }

    private static func localFileURLPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"file://[^\s\)\]>"]+"#) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            let raw = ns.substring(with: match.range)
            return URL(string: raw)?.path
        }
    }

    private static func absoluteMarkdownLinkPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\]\((/[^)\n]+)\)"#) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private static func nearestGitRoot(forLocalPath path: String, maxLevels: Int = 10) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            url = url.deletingLastPathComponent()
        } else if !fm.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent()
        }

        for _ in 0..<maxLevels {
            let dotGit = url.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private static func sha256(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }
}
