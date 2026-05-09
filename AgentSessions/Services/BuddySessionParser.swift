import Foundation
import CryptoKit

/// Shared JSONL line parsing for CodeBuddy and WorkBuddy transcripts.
///
/// Each product has its own facade parser type so line schemas can diverge later while
/// reusing timestamp extraction, content stringification, and `SessionEvent` mapping.
enum BuddyJSONLTranscriptParsing {
    private static let maxRawJSONFieldBytes = 8_192
    private static let previewLineLimit = 120
    private static let maxLightweightScanLines = 5_000

    // MARK: - Lightweight

    static func parseFile(at url: URL, source: SessionSource, forcedID: String? = nil) -> Session? {
        assert(source == .codebuddy || source == .workbuddy)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime

        let reader = JSONLReader(url: url)
        var messageCount = 0
        var toolCount = 0
        var firstUser: String?
        var idx = 0
        var sessionHint: String?
        var cwd: String?
        var model: String?
        var tmin: Date?
        var tmax: Date?

        do {
            try reader.forEachLineWhile { rawLine in
                idx += 1
                guard idx <= maxLightweightScanLines else { return false }
                if idx > previewLineLimit, messageCount > 0 { return false }
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return true
                }
                if sessionHint == nil, let sid = obj["sessionId"] as? String, !sid.isEmpty {
                    sessionHint = sid
                }
                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                    cwd = c
                }
                if model == nil { model = extractModel(from: obj) }
                if let ts = extractTimestamp(from: obj) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }
                let type = (obj["type"] as? String)?.lowercased() ?? ""
                switch type {
                case "message":
                    let role = (obj["role"] as? String)?.lowercased() ?? ""
                    if role == "user" || role == "assistant" { messageCount += 1 }
                    if firstUser == nil, role == "user", let t = stringifyContent(obj["content"]), !t.isEmpty {
                        firstUser = truncateTitle(t)
                    }
                case "function_call":
                    toolCount += 1
                default:
                    break
                }
                return true
            }
        } catch {
            return nil
        }

        guard messageCount > 0 else { return nil }

        let sid = forcedID ?? sha256(path: url.path)
        let repo = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }

        return Session(
            id: sid,
            source: source,
            startTime: tmin ?? ctime,
            endTime: tmax ?? mtime,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: max(messageCount + toolCount, messageCount),
            events: [],
            cwd: cwd,
            repoName: repo,
            lightweightTitle: firstUser,
            lightweightCommands: toolCount > 0 ? toolCount : nil,
            codexInternalSessionIDHint: sessionHint
        )
    }

    // MARK: - Full parse

    static func parseFileFull(at url: URL, source: SessionSource, forcedID: String? = nil) -> Session? {
        assert(source == .codebuddy || source == .workbuddy)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime

        let reader = JSONLReader(url: url)
        var events: [SessionEvent] = []
        events.reserveCapacity(256)
        var idx = 0
        var sessionHint: String?
        var cwd: String?
        var model: String?
        var tmin: Date?
        var tmax: Date?
        let eventIDPrefix = sha256(path: url.path).prefix(12)

        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let data = rawLine.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }
                if sessionHint == nil, let sid = obj["sessionId"] as? String, !sid.isEmpty {
                    sessionHint = sid
                }
                if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                    cwd = c
                }
                if model == nil { model = extractModel(from: obj) }
                if let ts = extractTimestamp(from: obj) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }
                let baseID = "\(eventIDPrefix)-\(idx)"
                events.append(contentsOf: parseLineEvents(obj, baseEventID: baseID))
            }
        } catch {
            return nil
        }

        let sid = forcedID ?? sha256(path: url.path)
        let repo = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let nonMeta = events.filter { $0.kind != .meta }.count
        let isHousekeeping = Session.computeIsHousekeeping(source: source, events: events)
        let toolCallCount = events.filter { $0.kind == .tool_call }.count
        let lightweightTitle: String? = events.lazy.compactMap { e -> String? in
            guard e.kind == .user, let t = e.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return truncateTitle(t)
        }.first

        return Session(
            id: sid,
            source: source,
            startTime: tmin ?? ctime,
            endTime: tmax ?? mtime,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: max(nonMeta, events.filter { $0.kind == .user || $0.kind == .assistant }.count),
            events: events,
            cwd: cwd,
            repoName: repo,
            lightweightTitle: lightweightTitle,
            lightweightCommands: toolCallCount > 0 ? toolCallCount : nil,
            isHousekeeping: isHousekeeping,
            codexInternalSessionIDHint: sessionHint
        )
    }

    // MARK: - Line parsing

    private static func parseLineEvents(_ obj: [String: Any], baseEventID: String) -> [SessionEvent] {
        let rawJSON = rawJSONBase64(truncateLargeStrings(in: obj))
        let ts = extractTimestamp(from: obj)
        guard let typeRaw = obj["type"] as? String else {
            return [metaEvent(id: baseEventID, ts: ts, text: "(missing type)", raw: rawJSON)]
        }
        let type = typeRaw.lowercased()
        switch type {
        case "message":
            let roleRaw = (obj["role"] as? String)?.lowercased() ?? "assistant"
            let role: String
            let kind: SessionEventKind
            switch roleRaw {
            case "user", "human":
                role = "user"; kind = .user
            case "assistant", "model":
                role = "assistant"; kind = .assistant
            case "system":
                role = "system"; kind = .meta
            default:
                role = roleRaw
                kind = .assistant
            }
            let text = stringifyContent(obj["content"])
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: kind,
                    role: role,
                    text: text,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: obj["id"] as? String,
                    parentID: obj["parentId"] as? String,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case "function_call":
            let name = (obj["name"] as? String) ?? "tool"
            let input = stringifyJSONValue(obj["arguments"]) ?? stringifyJSONValue(obj["message"])
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: .tool_call,
                    role: "assistant",
                    text: nil,
                    toolName: name,
                    toolInput: input,
                    toolOutput: nil,
                    messageID: obj["id"] as? String,
                    parentID: obj["parentId"] as? String,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case "function_call_result":
            let name = (obj["name"] as? String) ?? "tool"
            let output = stringifyJSONValue(obj["output"]) ?? stringifyJSONValue(obj["message"])
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: .tool_result,
                    role: "tool",
                    text: nil,
                    toolName: name,
                    toolInput: nil,
                    toolOutput: output,
                    messageID: obj["id"] as? String,
                    parentID: obj["parentId"] as? String,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case "reasoning":
            let body = (obj["rawContent"] as? String) ?? stringifyContent(obj["content"])
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: .meta,
                    role: "assistant",
                    text: body.map { "[reasoning]\n\($0)" },
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: obj["id"] as? String,
                    parentID: obj["parentId"] as? String,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case "topic", "file-history-snapshot":
            let summary: String = {
                if type == "topic", let t = obj["topic"] as? String { return "[topic] \(t)" }
                return "[\(type)]"
            }()
            return [metaEvent(id: baseEventID, ts: ts, text: summary, raw: rawJSON)]
        default:
            let mapped = SessionEventKind.from(role: nil, type: type)
            if mapped == .meta {
                return [metaEvent(id: baseEventID, ts: ts, text: "[\(type)]", raw: rawJSON)]
            }
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: mapped,
                    role: "meta",
                    text: nil,
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: nil,
                    parentID: nil,
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        }
    }

    private static func metaEvent(id: String, ts: Date?, text: String, raw: String) -> SessionEvent {
        SessionEvent(
            id: id,
            timestamp: ts,
            kind: .meta,
            role: "meta",
            text: text,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: nil,
            parentID: nil,
            isDelta: false,
            rawJSON: raw
        )
    }

    // MARK: - Helpers

    private static func extractTimestamp(from obj: [String: Any]) -> Date? {
        if let n = obj["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let i = obj["timestamp"] as? Int {
            return Date(timeIntervalSince1970: Double(i) / 1000.0)
        }
        if let s = obj["timestamp"] as? String {
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    private static func extractModel(from obj: [String: Any]) -> String? {
        if let pd = obj["providerData"] as? [String: Any] {
            if let m = pd["model"] as? String, !m.isEmpty { return m }
            if let m = pd["modelId"] as? String, !m.isEmpty { return m }
        }
        return nil
    }

    private static func stringifyContent(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let arr = value as? [Any] {
            var parts: [String] = []
            for item in arr {
                if let d = item as? [String: Any] {
                    if let t = d["text"] as? String { parts.append(t); continue }
                    if let t = d["content"] as? String { parts.append(t); continue }
                    if let sub = stringifyJSONValue(d) { parts.append(sub) }
                } else if let s = item as? String {
                    parts.append(s)
                }
            }
            let joined = parts.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return stringifyJSONValue(value)
    }

    private static func stringifyJSONValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

    private static func truncateLargeStrings(in obj: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in obj {
            if let s = v as? String, s.utf8.count > maxRawJSONFieldBytes {
                out[k] = String(s.prefix(maxRawJSONFieldBytes / 2)) + "...[truncated]"
            } else if let d = v as? [String: Any] {
                out[k] = truncateLargeStrings(in: d)
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func rawJSONBase64(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        let capped = s.utf8.count > maxRawJSONFieldBytes ? String(s.prefix(maxRawJSONFieldBytes)) + "..." : s
        return Data(capped.utf8).base64EncodedString()
    }

    private static func sha256(path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func truncateTitle(_ s: String, max: Int = 80) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max)) + "..."
    }
}

/// Parser entry point for CodeBuddy JSONL sessions.
enum CodebuddySessionParser {
    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        BuddyJSONLTranscriptParsing.parseFile(at: url, source: .codebuddy, forcedID: forcedID)
    }

    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        BuddyJSONLTranscriptParsing.parseFileFull(at: url, source: .codebuddy, forcedID: forcedID)
    }
}

/// Parser entry point for WorkBuddy JSONL sessions (structure may diverge from CodeBuddy over time).
enum WorkbuddySessionParser {
    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        BuddyJSONLTranscriptParsing.parseFile(at: url, source: .workbuddy, forcedID: forcedID)
    }

    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        BuddyJSONLTranscriptParsing.parseFileFull(at: url, source: .workbuddy, forcedID: forcedID)
    }
}
