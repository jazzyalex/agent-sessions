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
                if sessionHint == nil { sessionHint = extractSessionID(from: obj) }
                if cwd == nil { cwd = extractCWD(from: obj) }
                if model == nil { model = extractModel(from: obj) }
                if let ts = extractTimestamp(from: obj) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }
                let kind = eventKind(from: obj)
                switch kind {
                case .user, .assistant:
                    messageCount += 1
                    if firstUser == nil, kind == .user, let t = extractText(from: obj), !t.isEmpty {
                        firstUser = truncateTitle(t)
                    }
                case .tool_call:
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
        if cwd == nil { cwd = inferCWDBestEffort(from: url) }
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
                if sessionHint == nil { sessionHint = extractSessionID(from: obj) }
                if cwd == nil { cwd = extractCWD(from: obj) }
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
        if cwd == nil { cwd = inferCWDBestEffort(from: url) }
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
        let type = extractType(from: obj)
        let kind = eventKind(from: obj)
        switch kind {
        case .user, .assistant:
            let role = normalizedRole(from: obj) ?? (kind == .user ? "user" : "assistant")
            let text = extractText(from: obj)
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
                    messageID: extractMessageID(from: obj),
                    parentID: extractParentID(from: obj),
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case .tool_call:
            let name = extractToolName(from: obj) ?? "tool"
            let input = extractToolInput(from: obj)
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
                    messageID: extractMessageID(from: obj),
                    parentID: extractParentID(from: obj),
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case .tool_result:
            let name = extractToolName(from: obj) ?? "tool"
            let output = extractToolOutput(from: obj)
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
                    messageID: extractMessageID(from: obj),
                    parentID: extractParentID(from: obj),
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case .meta where type == "reasoning":
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
                    messageID: extractMessageID(from: obj),
                    parentID: extractParentID(from: obj),
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        case .meta where type == "topic" || type == "file-history-snapshot":
            let summary: String = {
                if type == "topic", let t = obj["topic"] as? String { return "[topic] \(t)" }
                return "[\(type)]"
            }()
            return [metaEvent(id: baseEventID, ts: ts, text: summary, raw: rawJSON)]
        case .error:
            return [
                SessionEvent(
                    id: baseEventID,
                    timestamp: ts,
                    kind: .error,
                    role: normalizedRole(from: obj) ?? "error",
                    text: extractText(from: obj) ?? extractToolOutput(from: obj),
                    toolName: nil,
                    toolInput: nil,
                    toolOutput: nil,
                    messageID: extractMessageID(from: obj),
                    parentID: extractParentID(from: obj),
                    isDelta: false,
                    rawJSON: rawJSON
                )
            ]
        default:
            let label = type.isEmpty ? "(missing type)" : "[\(type)]"
            return [metaEvent(id: baseEventID, ts: ts, text: label, raw: rawJSON)]
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
        for key in ["timestamp", "createdAt", "created_at", "updatedAt", "updated_at", "time", "ts"] {
            guard let value = obj[key] else { continue }
            if let n = value as? NSNumber {
                return dateFromEpoch(n.doubleValue)
            }
            if let s = value as? String {
                if let numeric = Double(s) {
                    return dateFromEpoch(numeric)
                }
                if let date = isoDate(s) {
                    return date
                }
            }
        }
        return nil
    }

    private static func extractModel(from obj: [String: Any]) -> String? {
        for key in ["model", "modelId", "model_id"] {
            if let m = obj[key] as? String, !m.isEmpty { return m }
        }
        if let pd = obj["providerData"] as? [String: Any] {
            if let m = pd["model"] as? String, !m.isEmpty { return m }
            if let m = pd["modelId"] as? String, !m.isEmpty { return m }
            if let m = pd["model_id"] as? String, !m.isEmpty { return m }
        }
        if let message = obj["message"] as? [String: Any] {
            for key in ["model", "modelId", "model_id"] {
                if let m = message[key] as? String, !m.isEmpty { return m }
            }
        }
        if let metadata = obj["metadata"] as? [String: Any] {
            for key in ["model", "modelId", "model_id"] {
                if let m = metadata[key] as? String, !m.isEmpty { return m }
            }
        }
        return nil
    }

    private static func eventKind(from obj: [String: Any]) -> SessionEventKind {
        let type = extractType(from: obj)
        let role = normalizedRole(from: obj)
        if type == "assistant_message" { return .assistant }
        if type == "user_message" { return .user }
        if type == "message" || type == "chat.message" || type == "conversation.message" || type == "assistant_message" || type == "user_message" {
            return SessionEventKind.from(role: role, type: nil)
        }
        let mapped = SessionEventKind.from(role: role, type: type)
        if mapped != .meta { return mapped }
        switch type {
        case "user", "human":
            return .user
        case "assistant", "model":
            return .assistant
        default:
            return mapped
        }
    }

    private static func extractType(from obj: [String: Any]) -> String {
        for key in ["type", "event", "eventType", "event_type", "kind"] {
            if let s = obj[key] as? String, !s.isEmpty { return s.lowercased() }
        }
        return ""
    }

    private static func normalizedRole(from obj: [String: Any]) -> String? {
        let role = firstString(in: obj, keys: ["role", "authorRole", "author_role", "sender", "speaker"])
            ?? nestedString(in: obj, path: ["message", "role"])
            ?? nestedString(in: obj, path: ["author", "role"])
        guard let role else { return nil }
        switch role.lowercased() {
        case "human": return "user"
        case "model": return "assistant"
        default: return role.lowercased()
        }
    }

    private static func extractSessionID(from obj: [String: Any]) -> String? {
        let explicit = firstString(in: obj, keys: [
            "sessionId", "session_id", "conversationId", "conversation_id",
            "chatId", "chat_id", "threadId", "thread_id"
        ])
        if let explicit { return explicit }
        if let nested = nestedString(in: obj, path: ["session", "id"])
            ?? nestedString(in: obj, path: ["conversation", "id"])
            ?? nestedString(in: obj, path: ["chat", "id"]) {
            return nested
        }
        let type = extractType(from: obj)
        if type.contains("session") || type.contains("conversation") || type == "metadata" {
            return firstString(in: obj, keys: ["id"])
        }
        return nil
    }

    private static func extractCWD(from obj: [String: Any]) -> String? {
        firstString(in: obj, keys: [
            "cwd", "currentWorkingDirectory", "current_working_directory",
            "workspace", "workspaceRoot", "workspace_root", "projectRoot", "project_root"
        ])
        ?? nestedString(in: obj, path: ["session", "cwd"])
        ?? nestedString(in: obj, path: ["workspace", "path"])
        ?? nestedString(in: obj, path: ["project", "path"])
    }

    private static func extractMessageID(from obj: [String: Any]) -> String? {
        firstString(in: obj, keys: ["messageId", "message_id", "uuid", "id"])
            ?? nestedString(in: obj, path: ["message", "id"])
    }

    private static func extractParentID(from obj: [String: Any]) -> String? {
        firstString(in: obj, keys: ["parentId", "parent_id"])
            ?? nestedString(in: obj, path: ["message", "parentId"])
            ?? nestedString(in: obj, path: ["message", "parent_id"])
    }

    private static func extractText(from obj: [String: Any]) -> String? {
        for key in ["content", "text", "rawContent", "raw_content", "delta", "summary"] {
            if let text = stringifyContent(obj[key]), !text.isEmpty { return text }
        }
        if let message = obj["message"] as? [String: Any] {
            for key in ["content", "text", "rawContent", "raw_content", "delta"] {
                if let text = stringifyContent(message[key]), !text.isEmpty { return text }
            }
        }
        if let parts = obj["parts"], let text = stringifyContent(parts), !text.isEmpty { return text }
        return nil
    }

    private static func extractToolName(from obj: [String: Any]) -> String? {
        firstString(in: obj, keys: ["name", "toolName", "tool_name", "functionName", "function_name"])
            ?? nestedString(in: obj, path: ["tool", "name"])
            ?? nestedString(in: obj, path: ["function", "name"])
            ?? nestedString(in: obj, path: ["message", "name"])
    }

    private static func extractToolInput(from obj: [String: Any]) -> String? {
        for key in ["arguments", "args", "input", "parameters", "params", "toolInput", "tool_input"] {
            if let value = stringifyJSONValue(obj[key]) { return value }
        }
        if let message = obj["message"] as? [String: Any] {
            for key in ["arguments", "args", "input", "parameters", "params", "content"] {
                if let value = stringifyJSONValue(message[key]) { return value }
            }
        }
        return nil
    }

    private static func extractToolOutput(from obj: [String: Any]) -> String? {
        for key in ["output", "result", "toolOutput", "tool_output", "content", "text"] {
            if let value = stringifyJSONValue(obj[key]) { return value }
        }
        if let message = obj["message"] as? [String: Any] {
            for key in ["output", "result", "content", "text"] {
                if let value = stringifyJSONValue(message[key]) { return value }
            }
        }
        if let value = stringifyJSONValue(obj["message"]) { return value }
        return nil
    }

    private static func stringifyContent(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let d = value as? [String: Any] {
            for key in ["text", "content", "value", "input", "output"] {
                if let text = stringifyContent(d[key]), !text.isEmpty { return text }
            }
            if let message = d["message"] as? [String: Any],
               let text = stringifyContent(message["content"]), !text.isEmpty {
                return text
            }
            return stringifyJSONValue(d)
        }
        if let arr = value as? [Any] {
            var parts: [String] = []
            for item in arr {
                if let d = item as? [String: Any] {
                    if let t = d["text"] as? String { parts.append(t); continue }
                    if let t = d["content"] as? String { parts.append(t); continue }
                    if let t = nestedString(in: d, path: ["text", "value"]) { parts.append(t); continue }
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

    private static func dateFromEpoch(_ raw: Double) -> Date {
        let seconds: Double
        let magnitude = abs(raw)
        if magnitude > 1_000_000_000_000_000_000 {
            seconds = raw / 1_000_000_000
        } else if magnitude > 1_000_000_000_000_000 {
            seconds = raw / 1_000_000
        } else if magnitude > 10_000_000_000 {
            seconds = raw / 1_000
        } else {
            seconds = raw
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func firstString(in obj: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = obj[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let n = obj[key] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    private static func nestedString(in obj: [String: Any], path: [String]) -> String? {
        var current: Any? = obj
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        if let s = current as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = current as? NSNumber { return n.stringValue }
        return nil
    }

    private static func inferCWDBestEffort(from url: URL) -> String? {
        guard let projectName = extractProjectDirName(from: url) else { return nil }
        if let decoded = percentOrBase64DecodedPath(projectName) { return decoded }
        return inferHyphenEncodedPath(projectName)
    }

    private static func extractProjectDirName(from url: URL) -> String? {
        let components = url.pathComponents
        for (i, component) in components.enumerated() where component == "projects" {
            let next = i + 1
            guard next < components.count else { continue }
            let projectDir = components[next]
            if projectDir == "projects" || projectDir == "tool-results" || projectDir.isEmpty { return nil }
            return projectDir
        }
        return nil
    }

    private static func percentOrBase64DecodedPath(_ projectName: String) -> String? {
        if let decoded = projectName.removingPercentEncoding, decoded.hasPrefix("/") {
            return decoded
        }
        let urlBase64 = projectName.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = urlBase64.padding(toLength: ((urlBase64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        if let data = Data(base64Encoded: padded),
           let decoded = String(data: data, encoding: .utf8),
           decoded.hasPrefix("/") {
            return decoded
        }
        return nil
    }

    private static func inferHyphenEncodedPath(_ projectName: String) -> String? {
        let segments = projectName.components(separatedBy: "-")
        guard !segments.isEmpty else { return nil }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        var resolvedPrefix = ""
        var currentComponent = segments[0]
        var i = 1

        while i < segments.count {
            let candidateDir = resolvedPrefix + "/" + currentComponent
            if fm.fileExists(atPath: candidateDir, isDirectory: &isDir), isDir.boolValue {
                resolvedPrefix = candidateDir
                currentComponent = segments[i]
            } else {
                currentComponent = currentComponent + "-" + segments[i]
            }
            i += 1
        }

        let inferred = resolvedPrefix + "/" + currentComponent
        return inferred == "/" ? nil : inferred
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
