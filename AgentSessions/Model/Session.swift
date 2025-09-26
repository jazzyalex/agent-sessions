import Foundation

public struct Session: Identifiable, Equatable, Codable {
    public let id: String
    public let startTime: Date?
    public let endTime: Date?
    public let model: String?
    public let filePath: String
    public let eventCount: Int
    public let events: [SessionEvent]

    public var shortID: String { String(id.prefix(6)) }
    public var firstUserPreview: String? {
        events.first(where: { $0.kind == .user })?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Derived human-friendly title for the session row.
    // Use improved Codex-style filtering with fallbacks for robustness
    public var title: String {
        // 1) Use Codex-style filtered title (best quality)
        if let codexTitle = codexPreviewTitle {
            return codexTitle
        }

        // 2) Fallback: first non-empty user line (less filtering)
        if let t = events.first(where: { $0.kind == .user })?.text?.collapsedWhitespace(), !t.isEmpty {
            return t
        }

        // 3) Fallback: first non-empty assistant line
        if let t = events.first(where: { $0.kind == .assistant })?.text?.collapsedWhitespace(), !t.isEmpty {
            return t
        }

        // 4) Final fallback: first tool call name
        if let name = events.first(where: { $0.kind == .tool_call && ($0.toolName?.isEmpty == false) })?.toolName {
            return name
        }

        return "No prompt"
    }

    // MARK: - Codex picker parity helpers
    // Title used by Codex's --resume picker: first plain user message found in the
    // head of the file (first 10 records). If none found, the session is not shown.
    public var codexPreviewTitle: String? {
        let head = events.prefix(10)

        // Find first meaningful user message, filtering out IDE scaffolding
        for event in head where event.kind == .user {
            guard let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }

            // Filter out common IDE scaffolding patterns
            let lowerText = text.lowercased()
            let scaffoldingPatterns = [
                "you are an expert",
                "you are a helpful",
                "act as a",
                "your role is",
                "system:",
                "assistant:",
                "<instructions>",
                "# instructions",
                "## instructions",
                "please follow",
                "make sure to"
            ]

            // Skip if it looks like scaffolding
            if scaffoldingPatterns.contains(where: { lowerText.hasPrefix($0) }) {
                continue
            }

            // Skip if it's very long (likely instructions)
            if text.count > 200 {
                continue
            }

            return text.collapsedWhitespace()
        }

        // Fallback: first shell/tool command in head as a one-liner
        if let call = head.first(where: { event in
            guard event.kind == .tool_call else { return false }
            guard let name = event.toolName?.lowercased() else { return false }
            return name.contains("shell") || name.contains("bash") || name.contains("sh")
        }) {
            if let cmd = Self.firstCommandLine(from: call.toolInput) {
                return cmd
            }
        }
        return nil
    }

    // Extract timestamp and UUID from rollout filename for Codex sort order.
    // rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl
    public var codexFilenameTimestamp: Date? {
        let filename = (filePath as NSString).lastPathComponent

        guard let match = Self.rolloutRegex.firstMatch(in: filename) else {
            return nil
        }

        let ts = match.ts
        let formatter = Self.rolloutDateFormatter
        return formatter.date(from: ts)
    }

    public var codexFilenameUUID: String? {
        guard let match = Self.rolloutRegex.firstMatch(in: (filePath as NSString).lastPathComponent) else { return nil }
        return match.uuid
    }

    // Prefer the internal session_id embedded in JSONL (more authoritative than filename UUID for some builds)
    public var codexInternalSessionID: String? {
        // Scan a larger head slice to improve hit rate on older logs
        let limit = min(events.count, 2000)
        for e in events.prefix(limit) {
            let raw = e.rawJSON
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = obj["session_id"] as? String, !v.isEmpty { return v }
                if let payload = obj["payload"] as? [String: Any], let v = payload["session_id"] as? String, !v.isEmpty { return v }
            }
            // Lightweight regex fallback when JSON parsing fails
            if let r = raw.range(of: #"\"session_id\"\s*:\s*\"([^"]+)\""#, options: .regularExpression) {
                let match = String(raw[r])
                if let idRange = match.range(of: #"\"([^"]+)\""#, options: .regularExpression) {
                    let quoted = String(match[idRange])
                    return String(quoted.dropFirst().dropLast())
                }
            }
        }
        return nil
    }

    // When showing Match Codex view, prefer the preview title, else fall back
    // to our general-purpose title so the table always has text.
    public var codexDisplayTitle: String { codexPreviewTitle ?? title }

    // MARK: - Repo/CWD helpers
    public var cwd: String? {
        // 1) Look for XML-ish environment_context blocks in text
        let pattern = #"<cwd>(.*?)</cwd>"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            for e in events {
                if let t = e.text {
                    let ns = t as NSString
                    let range = NSRange(location: 0, length: ns.length)
                    if let m = re.firstMatch(in: t, range: range), m.numberOfRanges >= 2 {
                        let r = m.range(at: 1)
                        let str = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !str.isEmpty { return str }
                    }
                }
            }
        }
        // 2) Look for JSON field "cwd" in raw JSON
        for e in events {
            if let data = e.rawJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let c = obj["cwd"] as? String, !c.isEmpty {
                return c
            }
        }
        return nil
    }
    public var repoName: String? {
        guard let cwd else { return nil }

        // 1. Try git repository detection first
        if let info = Self.gitInfo(from: cwd) {
            return URL(fileURLWithPath: info.root).lastPathComponent
        }

        // 2. Fallback: use directory name if it looks like a project
        let url = URL(fileURLWithPath: cwd)
        let dirName = url.lastPathComponent

        // Skip generic directory names that aren't useful
        let genericNames = ["Documents", "Desktop", "Downloads", "tmp", "temp", "src", "code"]
        if !genericNames.contains(dirName) && !dirName.isEmpty && dirName != "." {
            return dirName
        }

        // 3. Final fallback: try parent directory name
        let parent = url.deletingLastPathComponent()
        let parentName = parent.lastPathComponent
        if !genericNames.contains(parentName) && !parentName.isEmpty && parentName != "." {
            return parentName
        }

        return nil
    }

    public var repoDisplay: String {
        repoName ?? (cwd != nil ? "Other" : "—")
    }
    public var isWorktree: Bool { (cwd.flatMap { Self.gitInfo(from: $0)?.isWorktree }) ?? false }
    public var isSubmodule: Bool { (cwd.flatMap { Self.gitInfo(from: $0)?.isSubmodule }) ?? false }

    public var nonMetaCount: Int { events.filter { $0.kind != .meta }.count }

    public var modifiedRelative: String {
        // Use modifiedAt which correctly uses filename timestamp
        let ref = modifiedAt
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: ref, relativeTo: Date())
    }

    public var modifiedAt: Date {
        // Use filename timestamp (session creation) like Codex CLI, fallback to session end/start
        let filenameDate = codexFilenameTimestamp
        let endDate = endTime
        let startDate = startTime

        if let filenameDate = filenameDate {
            return filenameDate
        } else if let endDate = endDate {
            return endDate
        } else if let startDate = startDate {
            return startDate
        } else {
            return .distantPast
        }
    }

    // Best-effort git branch detection
    public var gitBranch: String? {
        // 1) explicit metadata in any event json
        for e in events {
            if let branch = extractBranch(fromRawJSON: e.rawJSON) { return branch }
        }
        // 2) regex over tool_result/shell outputs (use text/toolOutput)
        let texts = events.compactMap { $0.toolOutput ?? $0.text }
        for t in texts {
            if let b = extractBranch(fromOutput: t) { return b }
        }
        return nil
    }
}

enum SessionDateSection: Hashable, Identifiable {
    var id: Self { self }
    case today
    case yesterday
    case day(String)
    case older

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .day(let s): return s
        case .older: return "Older"
        }
    }
}

struct Filters: Equatable {
    var query: String = ""
    var dateFrom: Date?
    var dateTo: Date?
    var model: String?
    var kinds: Set<SessionEventKind> = Set(SessionEventKind.allCases)
    var repoName: String? = nil
    var pathContains: String? = nil
}

enum FilterEngine {
    static func sessionMatches(_ session: Session, filters: Filters) -> Bool {
        // Parse query operators repo: and path:
        let parsed = parseOperators(filters.query)
        let effectiveRepo = filters.repoName ?? parsed.repo
        let pathSubstr = filters.pathContains ?? parsed.path

        // Date range: compare session endTime first (modified), fallback to startTime
        let ref = session.endTime ?? session.startTime
        if let from = filters.dateFrom, let t = ref, t < from { return false }
        if let to = filters.dateTo, let t = ref, t > to { return false }

        if let m = filters.model, !m.isEmpty, session.model != m { return false }

        if let repo = effectiveRepo, !repo.isEmpty {
            guard let r = session.repoName?.lowercased() else { return false }
            if !r.contains(repo.lowercased()) { return false }
        }

        if let p = pathSubstr, !p.isEmpty {
            guard let path = session.cwd?.lowercased() else { return false }
            if !path.contains(p.lowercased()) { return false }
        }

        // Kinds: session must have any event in selected kinds
        if !session.events.contains(where: { filters.kinds.contains($0.kind) }) { return false }

        let q = parsed.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        // Full-text across rendered transcript fields only (not raw JSON) to reduce noise
        for e in session.events {
            if let t = e.text, !t.isEmpty, t.localizedCaseInsensitiveContains(q) { return true }
            if let ti = e.toolInput, !ti.isEmpty, ti.localizedCaseInsensitiveContains(q) { return true }
            if let to = e.toolOutput, !to.isEmpty, to.localizedCaseInsensitiveContains(q) { return true }
        }
        return false
    }

    static func filterSessions(_ sessions: [Session], filters: Filters) -> [Session] {
        // Preserve the original sort order from allSessions instead of re-sorting
        sessions.filter { sessionMatches($0, filters: filters) }
    }

    private struct ParsedQuery { let freeText: String; let repo: String?; let path: String? }
    private static func parseOperators(_ q: String) -> ParsedQuery {
        guard !q.isEmpty else { return ParsedQuery(freeText: "", repo: nil, path: nil) }
        var repo: String? = nil
        var path: String? = nil
        var remaining: [String] = []
        for raw in q.split(separator: " ") {
            let token = String(raw)
            if token.hasPrefix("repo:") {
                let v = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { repo = v; continue }
            }
            if token.hasPrefix("path:") {
                let v = String(token.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { path = v; continue }
            }
            remaining.append(token)
        }
        return ParsedQuery(freeText: remaining.joined(separator: " "), repo: repo, path: path)
    }
}

extension Array where Element == Session {
    func groupedBySection(now: Date = Date(), calendar: Calendar = .current) -> [(SessionDateSection, [Session])] {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        var buckets: [SessionDateSection: [Session]] = [:]
        for s in self {
            guard let start = s.startTime else {
                buckets[.older, default: []].append(s)
                continue
            }
            if cal.isDate(start, inSameDayAs: today) {
                buckets[.today, default: []].append(s)
            } else if cal.isDate(start, inSameDayAs: yesterday) {
                buckets[.yesterday, default: []].append(s)
            } else {
                let dayStr = ISO8601DateFormatter.cachedDayString(from: start)
                buckets[.day(dayStr), default: []].append(s)
            }
        }
        // Section order
        var result: [(SessionDateSection, [Session])] = []
        if let v = buckets[.today] { result.append((.today, v)) }
        if let v = buckets[.yesterday] { result.append((.yesterday, v)) }
        // Sort day sections descending
        let daySections = buckets.keys.compactMap { sec -> (String, [Session])? in
            if case let .day(d) = sec { return (d, buckets[sec] ?? []) }
            return nil
        }.sorted { $0.0 > $1.0 }
        for (d, list) in daySections { result.append((.day(d), list)) }
        if let v = buckets[.older] { result.append((.older, v)) }
        return result
    }
}

extension ISO8601DateFormatter {
    static let day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay]
        return f
    }()
    static func cachedDayString(from date: Date) -> String {
        return day.string(from: date)
    }
}

// MARK: - Git branch helpers

private extension String {
    func collapsedWhitespace() -> String {
        let parts = self.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
    var trimmedEmpty: Bool { self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func extractBranch(fromRawJSON raw: String) -> String? {
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let b = obj["git_branch"] as? String { return b }
        if let repo = obj["repo"] as? [String: Any], let b = repo["branch"] as? String { return b }
        if let b = obj["branch"] as? String { return b }
    }
    return nil
}

private func extractBranch(fromOutput s: String) -> String? {
    let patterns = [
        "(?m)^On\\s+branch\\s+([A-Za-z0-9._/-]+)",
        "(?m)^\\*\\s+([A-Za-z0-9._/-]+)$",
        "(?m)^(?:heads/)?([A-Za-z0-9._/-]+)$"
    ]
    for p in patterns {
        if let re = try? NSRegularExpression(pattern: p) {
            let range = NSRange(location: 0, length: (s as NSString).length)
            if let m = re.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 {
                let r = m.range(at: 1)
                if let swiftRange = Range(r, in: s) { return String(s[swiftRange]) }
            }
        }
    }
    return nil
}

// MARK: - Rollout filename regex helpers
private struct RolloutMatch { let ts: String; let uuid: String }
private struct RolloutRegex {
    private let regex: NSRegularExpression?

    init() {
        let pattern = "^rollout-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2})-([0-9a-fA-F-]+)\\.jsonl$"
        regex = try? NSRegularExpression(pattern: pattern)
    }

    func firstMatch(in name: String) -> RolloutMatch? {
        guard let regex else { return nil }
        let range = NSRange(location: 0, length: (name as NSString).length)
        guard let m = regex.firstMatch(in: name, range: range), m.numberOfRanges >= 3 else { return nil }
        let ns = name as NSString
        return RolloutMatch(ts: ns.substring(with: m.range(at: 1)), uuid: ns.substring(with: m.range(at: 2)))
    }
}

private extension Session {
    static let rolloutRegex = RolloutRegex()
    static let rolloutDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone.current  // Use local timezone, not UTC
        return f
    }()
    static func firstCommandLine(from raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Try to parse JSON object
        if let data = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // common keys
            if let v = (obj["command"] ?? obj["cmd"] ?? obj["script"] ?? obj["args"]) {
                if let str = v as? String { s = str }
                else if let arr = v as? [Any] { s = arr.map { String(describing: $0) }.joined(separator: " ") }
            }
        }
        // If multi-line, take first non-empty line
        for line in s.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return s
    }

    // Try to find a Git repository root by walking up from cwd.
    struct GitInfo { let root: String; let isWorktree: Bool; let isSubmodule: Bool }
    static func gitInfo(from start: String, maxLevels: Int = 6) -> GitInfo? {
        var url = URL(fileURLWithPath: start)
        let fm = FileManager.default
        for _ in 0..<maxLevels {
            let dotGitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGitDir.path, isDirectory: &isDir), isDir.boolValue {
                // Regular repo root
                return GitInfo(root: url.path, isWorktree: false, isSubmodule: false)
            }
            // .git file pointing to gitdir
            if fm.fileExists(atPath: dotGitDir.path) {
                if let data = try? String(contentsOf: dotGitDir, encoding: .utf8),
                   let range = data.range(of: "gitdir:") {
                    let path = data[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let lower = path.lowercased()
                    let worktree = lower.contains(".git/worktrees/")
                    let submodule = lower.contains(".git/modules/")
                    return GitInfo(root: url.path, isWorktree: worktree, isSubmodule: submodule)
                }
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}
