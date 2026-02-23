import Foundation

struct TranscriptLinkifier {
    struct FileLinkMatch: Equatable, Sendable {
        let range: NSRange
        let path: String
        let line: Int?
        let column: Int?
    }

    private static let allowedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "java", "kt", "kts", "rb", "php", "cs", "json", "yaml", "yml", "toml", "xml", "md", "txt", "sh", "zsh", "bash", "sql"
    ]

    private static let allowedExtensionlessBasenames: Set<String> = [
        "readme", "license", "dockerfile", "makefile", "gemfile", "podfile", "rakefile", "procfile", "justfile", "brewfile"
    ]

    private static let leadingNoiseTokens: Set<String> = [
        "see", "at", "in", "on", "from", "path", "file", "the", "a", "an", "and"
    ]

    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./\-\(\)])([A-Za-z0-9_./\-\(\) +]+) \(line (\d+)\)"#),
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./\-\(\)])([A-Za-z0-9_./\-\(\) +]+):(\d+):(\d+)\b"#),
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./\-\(\)])([A-Za-z0-9_./\-\(\) +]+):(\d+)(?!:\d)\b"#),
        try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./\-\(\)])([A-Za-z0-9_./\-\(\) +]+)#L(\d+)(?:-L?(\d+))?\b"#)
    ]

    static func matches(in text: String) -> [FileLinkMatch] {
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var out: [FileLinkMatch] = []
        out.reserveCapacity(8)

        for (patternIndex, regex) in patterns.enumerated() {
            for match in regex.matches(in: text, options: [], range: full) {
                guard match.numberOfRanges >= 2 else { continue }
                let pathRange = match.range(at: 1)
                guard pathRange.location != NSNotFound else { continue }
                let rawPath = nsText.substring(with: pathRange)
                guard let normalized = normalizePathCandidate(rawPath) else { continue }
                let adjustedLength = pathRange.length - normalized.leadingTrimUTF16 - normalized.trailingTrimUTF16
                guard adjustedLength > 0 else { continue }
                let adjustedPathRange = NSRange(location: pathRange.location + normalized.leadingTrimUTF16,
                                                length: adjustedLength)
                let path = normalized.path
                guard isAllowedPath(path) else { continue }

                let line: Int? = {
                    guard match.numberOfRanges >= 3 else { return nil }
                    let r = match.range(at: 2)
                    guard r.location != NSNotFound else { return nil }
                    return Int(nsText.substring(with: r))
                }()

                // Only `path:line:column` carries a real column capture.
                let column: Int? = {
                    guard patternIndex == 1, match.numberOfRanges >= 4 else { return nil }
                    let r = match.range(at: 3)
                    guard r.location != NSNotFound else { return nil }
                    return Int(nsText.substring(with: r))
                }()

                out.append(FileLinkMatch(range: adjustedPathRange,
                                         path: path,
                                         line: line,
                                         column: column))
            }
        }

        return dedupe(matches: out)
    }

    static func resolve(path: String, sessionCwd: String?, repoRoot: String?) -> String? {
        let fm = FileManager.default
        let isAbsolute = path.hasPrefix("/")

        if isAbsolute {
            return fm.fileExists(atPath: path) ? path : nil
        }

        if let cwd = sessionCwd, !cwd.isEmpty {
            let candidate = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        if let root = repoRoot, !root.isEmpty {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent(path).path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static func linkPayload(path: String, line: Int?, column: Int?) -> String {
        var comps = URLComponents()
        comps.scheme = "asfile"
        comps.host = "open"
        comps.path = path
        var items: [URLQueryItem] = []
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.string ?? "asfile://open\(path)"
    }

    static func decodePayload(_ payload: String) -> (path: String, line: Int?, column: Int?)? {
        guard let comps = URLComponents(string: payload), comps.scheme == "asfile" else { return nil }
        let path = comps.path
        guard !path.isEmpty else { return nil }
        let line = comps.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
        let column = comps.queryItems?.first(where: { $0.name == "column" })?.value.flatMap(Int.init)
        return (path: path, line: line, column: column)
    }

    private static func isAllowedPath(_ path: String) -> Bool {
        guard !path.contains("://") else { return false }
        guard !path.hasPrefix("~") else { return false }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        guard !basename.isEmpty else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if !ext.isEmpty {
            return allowedExtensions.contains(ext)
        }
        return allowedExtensionlessBasenames.contains(basename.lowercased())
    }

    private static func normalizePathCandidate(_ rawPath: String) -> (path: String, leadingTrimUTF16: Int, trailingTrimUTF16: Int)? {
        let leadingTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`([{<"))
        let trailingTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.,;:!?)]}>"))
        var path = rawPath
        var leading = 0
        var trailing = 0

        while let scalar = path.unicodeScalars.first, leadingTrimSet.contains(scalar) {
            let char = String(path[path.startIndex])
            leading += char.utf16.count
            path.removeFirst()
        }

        while let scalar = path.unicodeScalars.last, trailingTrimSet.contains(scalar) {
            let char = String(path[path.index(before: path.endIndex)])
            trailing += char.utf16.count
            path.removeLast()
        }

        while true {
            let parts = path.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { break }
            let token = parts[0].lowercased()
            guard leadingNoiseTokens.contains(token) else { break }
            let dropped = String(parts[0]) + " "
            leading += dropped.utf16.count
            path = String(parts[1])
        }

        guard !path.isEmpty else { return nil }
        return (path: path, leadingTrimUTF16: leading, trailingTrimUTF16: trailing)
    }

    private static func dedupe(matches: [FileLinkMatch]) -> [FileLinkMatch] {
        var seen: Set<String> = []
        var out: [FileLinkMatch] = []
        for item in matches.sorted(by: { $0.range.location < $1.range.location }) {
            let key = "\(item.range.location):\(item.range.length):\(item.path):\(item.line ?? -1):\(item.column ?? -1)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }
}
