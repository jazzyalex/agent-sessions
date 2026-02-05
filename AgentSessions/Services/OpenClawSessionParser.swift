import Foundation
import CryptoKit

/// Parser for OpenClaw (and legacy Clawdbot) JSONL session transcripts.
///
/// Observed format (v3):
/// - Header: { "type":"session", "version":3, "id": "...", "timestamp":"ISO8601", "cwd":"..." }
/// - Messages: { "type":"message", "id":"...", "parentId":"...", "timestamp":"ISO8601", "message":{ "role": "...", "content":[...] } }
/// - Tool calls inside assistant content: { "type":"toolCall", "id":"...", "name":"...", "arguments":{...} }
/// - Tool results as separate messages: role == "toolResult" with toolCallId + toolName + content[]
/// - Meta records: model_change, thinking_level_change, compaction, etc.
final class OpenClawSessionParser {
    private static let previewScanLimit = 2_000

    enum TitleStrategy: String {
        case promptOnly
        case originOnly
        case originThenPrompt
        case promptThenOrigin
    }

    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        let reader = JSONLReader(url: url)

        var sessionID: String? = nil
        var cwd: String? = nil
        var model: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var title: String? = nil
        var firstToolName: String? = nil
        var estimatedEvents = 0
        var estimatedCommands = 0
        var idx = 0

        // Housekeeping heuristics
        var sawNonHousekeepingUser = false
        var sawHeartbeatPrompt = false

        do {
            try reader.forEachLineWhile { rawLine in
                idx += 1
                guard idx <= previewScanLimit else { return false }
                guard let obj = decodeObject(rawLine) else { return true }
                guard let type = obj["type"] as? String else { return true }

                if let ts = parseTimestamp(obj["timestamp"] ?? (obj["message"] as? [String: Any])?["timestamp"]) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                switch type {
                case "session":
                    if sessionID == nil, let id = obj["id"] as? String, !id.isEmpty { sessionID = id }
                    if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }

                case "model_change":
                    if let m = obj["modelId"] as? String, !m.isEmpty { model = m }

                case "message":
                    guard let msg = obj["message"] as? [String: Any] else { return true }
                    let role = (msg["role"] as? String) ?? ""
                    if role == "user" {
                        if let userText = extractText(fromContent: msg["content"]) {
                            let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if isHeartbeatPrompt(trimmed) {
                                sawHeartbeatPrompt = true
                                return true
                            }
                            if isNewSessionScaffold(trimmed) {
                                return true
                            }
                            sawNonHousekeepingUser = true
                            if title == nil {
                                title = deriveTitle(fromUserText: trimmed)
                            }
                        }
                        estimatedEvents += 1
                    } else if role == "assistant" {
                        // Count assistant text and toolCalls as events (approx).
                        if let content = msg["content"] as? [Any] {
                            for block in content {
                                guard let b = block as? [String: Any], let btype = b["type"] as? String else { continue }
                                switch btype {
                                case "toolCall":
                                    estimatedEvents += 1
                                    estimatedCommands += 1
                                    if firstToolName == nil { firstToolName = b["name"] as? String }
                                case "text":
                                    if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        estimatedEvents += 1
                                    }
                                default:
                                    break
                                }
                            }
                        }
                        if model == nil, let m = msg["model"] as? String, !m.isEmpty { model = m }
                    } else if role == "toolResult" {
                        estimatedEvents += 1
                        estimatedCommands += 1
                        if firstToolName == nil { firstToolName = msg["toolName"] as? String }
                    } else {
                        // Other roles -> meta; ignore for preview counts.
                    }

                default:
                    break
                }
                return true
            }
        } catch {
            return nil
        }

        let agentID = agentIDFromPath(url)
        let baseID = forcedID
            ?? sessionID
            ?? url.deletingPathExtension().lastPathComponent
            ?? sha256(path: url.path)
        let id: String = {
            if let forcedID, forcedID.hasPrefix("openclaw:") { return forcedID }
            return "openclaw:\(agentID):\(baseID)"
        }()

        // Title fallback: first tool call name if no useful user prompt exists.
        if title == nil, let firstToolName, !firstToolName.isEmpty {
            title = firstToolName
        }

        // If we only saw housekeeping scaffolding, mark as housekeeping so default filters hide it.
        let isHousekeeping = !sawNonHousekeepingUser && sawHeartbeatPrompt

        return Session(
            id: id,
            source: .openclaw,
            startTime: tmin ?? mtime,
            endTime: tmax ?? mtime,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: max(0, estimatedEvents),
            events: [],
            cwd: cwd,
            repoName: nil,
            lightweightTitle: title,
            lightweightCommands: estimatedCommands,
            isHousekeeping: isHousekeeping
        )
    }

    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let reader = JSONLReader(url: url)

        var events: [SessionEvent] = []
        var sessionID: String? = nil
        var cwd: String? = nil
        var model: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil

        var sawNonHousekeepingUser = false
        var sawHeartbeatPrompt = false
        var idx = 0

        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let obj = decodeObject(rawLine) else { return }
                guard let type = obj["type"] as? String else { return }

                let baseID = eventID(for: url, index: idx)
                let ts = parseTimestamp(obj["timestamp"] ?? (obj["message"] as? [String: Any])?["timestamp"])

                if let ts {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                switch type {
                case "session":
                    if sessionID == nil, let id = obj["id"] as? String, !id.isEmpty { sessionID = id }
                    if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                    // Keep as meta for raw view parity.
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[session]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "model_change":
                    if let m = obj["modelId"] as? String, !m.isEmpty { model = m }
                    let provider = obj["provider"] as? String
                    let mid = obj["modelId"] as? String
                    let text = "[model_change] " + [provider, mid].compactMap { $0 }.joined(separator: " ")
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: text.isEmpty ? "[model_change]" : text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: obj["parentId"] as? String,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "thinking_level_change":
                    let level = obj["thinkingLevel"] as? String
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: level != nil ? "[thinking_level] \(level!)" : "[thinking_level]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: obj["parentId"] as? String,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "message":
                    guard let msg = obj["message"] as? [String: Any] else { return }
                    let role = (msg["role"] as? String) ?? ""
                    let messageID = obj["id"] as? String
                    let parentID = obj["parentId"] as? String

                    if role == "user" {
                        if let userText = extractText(fromContent: msg["content"]) {
                            let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if isHeartbeatPrompt(trimmed) { sawHeartbeatPrompt = true }
                            if !isHeartbeatPrompt(trimmed) && !isNewSessionScaffold(trimmed) { sawNonHousekeepingUser = true }
                        }
                        let text = extractText(fromContent: msg["content"])
                        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            events.append(SessionEvent(
                                id: baseID,
                                timestamp: ts,
                                kind: .user,
                                role: "user",
                                text: text,
                                toolName: nil,
                                toolInput: nil,
                                toolOutput: nil,
                                messageID: messageID,
                                parentID: parentID,
                                isDelta: false,
                                rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                            ))
                        }

                    } else if role == "assistant" {
                        if model == nil, let m = msg["model"] as? String, !m.isEmpty { model = m }
                        if let content = msg["content"] as? [Any] {
                            var blockIndex = 0
                            for anyBlock in content {
                                blockIndex += 1
                                guard let block = anyBlock as? [String: Any], let btype = block["type"] as? String else { continue }
                                switch btype {
                                case "text":
                                    guard let t = block["text"] as? String else { continue }
                                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.isEmpty { continue }
                                    events.append(SessionEvent(
                                        id: baseID + String(format: "-b%02d", blockIndex),
                                        timestamp: ts,
                                        kind: .assistant,
                                        role: "assistant",
                                        text: t,
                                        toolName: nil,
                                        toolInput: nil,
                                        toolOutput: nil,
                                        messageID: messageID,
                                        parentID: parentID,
                                        isDelta: false,
                                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                                    ))
                                case "toolCall":
                                    let toolCallId = block["id"] as? String
                                    let toolName = block["name"] as? String
                                    let args = block["arguments"]
                                    events.append(SessionEvent(
                                        id: baseID + String(format: "-t%02d", blockIndex),
                                        timestamp: ts,
                                        kind: .tool_call,
                                        role: "assistant",
                                        text: nil,
                                        toolName: toolName,
                                        toolInput: stringifyJSONBounded(args),
                                        toolOutput: nil,
                                        messageID: toolCallId,
                                        parentID: messageID,
                                        isDelta: false,
                                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                                    ))
                                default:
                                    // Keep unknown blocks as meta so the raw stream isn't lost.
                                    events.append(SessionEvent(
                                        id: baseID + String(format: "-u%02d", blockIndex),
                                        timestamp: ts,
                                        kind: .meta,
                                        role: "meta",
                                        text: "[assistant/\(btype)]",
                                        toolName: nil,
                                        toolInput: nil,
                                        toolOutput: nil,
                                        messageID: messageID,
                                        parentID: parentID,
                                        isDelta: false,
                                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: block))
                                    ))
                                }
                            }
                        }

                    } else if role == "toolResult" {
                        let toolCallId = msg["toolCallId"] as? String
                        let toolName = msg["toolName"] as? String
                        let output = extractText(fromContent: msg["content"])
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: ((msg["isError"] as? Bool) ?? false) ? .error : .tool_result,
                            role: "tool",
                            text: nil,
                            toolName: toolName,
                            toolInput: nil,
                            toolOutput: output,
                            messageID: toolCallId,
                            parentID: toolCallId,
                            isDelta: false,
                            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                        ))
                    } else {
                        // Preserve unusual roles as meta.
                        let text = extractText(fromContent: msg["content"])
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .meta,
                            role: role,
                            text: text,
                            toolName: msg["toolName"] as? String,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                        ))
                    }

                default:
                    // Preserve unknown record types as meta for raw view/debugging.
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[\(type)]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: obj["parentId"] as? String,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))
                }
            }
        } catch {
            return nil
        }

        let agentID = agentIDFromPath(url)
        let baseID = forcedID
            ?? sessionID
            ?? url.deletingPathExtension().lastPathComponent
            ?? sha256(path: url.path)
        let id: String = {
            if let forcedID, forcedID.hasPrefix("openclaw:") { return forcedID }
            return "openclaw:\(agentID):\(baseID)"
        }()

        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let start = tmin ?? mtime
        let end = tmax ?? mtime
        let isHousekeeping = !sawNonHousekeepingUser && sawHeartbeatPrompt

        return Session(
            id: id,
            source: .openclaw,
            startTime: start,
            endTime: end,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: max(events.filter { $0.kind != .meta }.count, 0),
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: nil,
            isHousekeeping: isHousekeeping
        )
    }

    // MARK: - Title helpers

    private static func deriveTitle(fromUserText text: String) -> String {
        let strategy = currentTitleStrategy()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[Telegram ") else {
            return trimmed
        }

        let parsed = parseTelegramPrefix(trimmed)
        let origin = parsed.origin
        let msg = parsed.message

        switch strategy {
        case .promptOnly:
            return msg ?? trimmed
        case .originOnly:
            return origin ?? trimmed
        case .originThenPrompt:
            if let origin, let msg { return "\(origin) — \(msg)" }
            return origin ?? msg ?? trimmed
        case .promptThenOrigin:
            if let origin, let msg { return "\(msg) — \(origin)" }
            return msg ?? origin ?? trimmed
        }
    }

    private static func currentTitleStrategy() -> TitleStrategy {
        let raw = UserDefaults.standard.string(forKey: "OpenClawTitleStrategy") ?? ""
        return TitleStrategy(rawValue: raw) ?? .originThenPrompt
    }

    private static func parseTelegramPrefix(_ text: String) -> (origin: String?, message: String?) {
        guard let close = text.firstIndex(of: "]") else {
            return (origin: nil, message: nil)
        }
        let inside = text[text.index(after: text.startIndex)..<close]
        var origin = String(inside)
        origin = origin.replacingOccurrences(of: "Telegram ", with: "")
        if let idRange = origin.range(of: " id:") {
            origin = String(origin[..<idRange.lowerBound])
        }
        origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)

        var msg = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Common suffix: [message_id: ...]
        if let r = msg.range(of: "\n[message_id:", options: [.caseInsensitive]) {
            msg = String(msg[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if msg.hasSuffix("]"), let r = msg.range(of: "[message_id:", options: [.caseInsensitive]) {
            // If the message_id is inline at the end, drop it.
            msg = String(msg[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if msg.isEmpty { return (origin: origin.isEmpty ? nil : origin, message: nil) }
        return (origin: origin.isEmpty ? nil : origin, message: msg)
    }

    private static func isHeartbeatPrompt(_ text: String) -> Bool {
        let lower = text.lowercased()
        if !lower.contains("heartbeat.md") { return false }
        if lower.contains("read heartbeat.md") { return true }
        if lower.contains("consider outstanding tasks") { return true }
        return false
    }

    private static func isNewSessionScaffold(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("a new session was started via /new") || lower.contains("via /new or /reset")
    }

    // MARK: - Content extraction

    private static func extractText(fromContent any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : s
        }
        guard let arr = any as? [Any] else { return nil }

        let hasImage: Bool = arr.contains { item in
            guard let d = item as? [String: Any] else { return false }
            return (d["type"] as? String) == "image"
        }

        var texts: [String] = []
        texts.reserveCapacity(min(arr.count, 8))
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            if (d["type"] as? String) == "text", let t = d["text"] as? String {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // Telegram attachments: Clawdbot injects a verbose "[media attached: ...]" hint string.
                // Hide it when an actual inline image block is present.
                if hasImage, isRedundantMediaAttachmentText(trimmed) { continue }
                texts.append(t)
            }
        }
        if texts.isEmpty {
            return hasImage ? "Image attached" : nil
        }
        return texts.joined(separator: "\n")
    }

    private static func isRedundantMediaAttachmentText(_ trimmed: String) -> Bool {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("[media attached:") { return true }
        if lower.contains("to send an image back") && lower.contains("media:") { return true }
        return false
    }

    // MARK: - JSON helpers

    private static func decodeObject(_ rawLine: String) -> [String: Any]? {
        guard let data = rawLine.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return any as? [String: Any]
    }

    private static func parseTimestamp(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: normalizeEpochSeconds(n)) }
        if let n = any as? Int { return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(n))) }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }  // microseconds
        if value > 1e11 { return value / 1_000 }       // milliseconds
        return value
    }

    private static func sanitizeLargeStrings(in any: Any) -> Any {
        // Keep in sync with other parsers: cap huge raw JSON fields so DB and raw views stay responsive.
        let maxBytes = 256 * 1024
        if let s = any as? String {
            if s.utf8.count > maxBytes {
                return "[OMITTED bytes=\(s.utf8.count)]"
            }
            return s
        }
        if let arr = any as? [Any] {
            return arr.map { sanitizeLargeStrings(in: $0) }
        }
        if let dict = any as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = sanitizeLargeStrings(in: v)
            }
            return out
        }
        return any
    }

    private static func rawJSONBase64(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: []) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private static func stringifyJSONBounded(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        guard JSONSerialization.isValidJSONObject(any) else { return String(describing: any) }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return String(describing: any)
        }
        if data.count > 32_768 {
            return "[OMITTED large JSON payload bytes=\(data.count)]"
        }
        return String(data: data, encoding: .utf8)
    }

    private static func eventID(for url: URL, index: Int) -> String {
        let base = sha256(path: url.path)
        return base + String(format: "-%06d", index)
    }

    private static func sha256(path: String) -> String {
        let data = Data(path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func agentIDFromPath(_ url: URL) -> String {
        let comps = url.pathComponents
        guard let i = comps.lastIndex(of: "agents"), i + 1 < comps.count else { return "main" }
        let agent = comps[i + 1]
        return agent.isEmpty ? "main" : agent
    }
}
