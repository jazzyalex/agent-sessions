import Foundation
import CryptoKit

/// Parser for GitHub Copilot CLI agent session-state JSONL files.
///
/// Observed format: ~/.copilot/session-state/<sessionId>.jsonl
/// Each line is an event envelope: { type, data, id, timestamp, parentId }.
final class CopilotSessionParser {
    private static let previewScanLimit = 2_000
    private static let maxRawResultContentBytes = 8_192

    private static func normalizeEscapes(_ s: String?) -> String? {
        guard let s else { return nil }
        return s
            .replacingOccurrences(of: "\\r\\n", with: "\r\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }

    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        let reader = JSONLReader(url: url)
        var sessionID: String? = nil
        var model: String? = nil
        var cwd: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var title: String? = nil
        var estimatedEvents = 0
        var estimatedCommands = 0
        var idx = 0

        do {
            try reader.forEachLine { rawLine in
                if idx >= previewScanLimit { return }
                idx += 1
                guard let obj = decodeObject(rawLine) else { return }
                guard let type = obj["type"] as? String else { return }
                let data = obj["data"] as? [String: Any] ?? [:]

                if let ts = decodeDate(obj["timestamp"]) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                if sessionID == nil, type == "session.start" {
                    sessionID = data["sessionId"] as? String
                }
                if type == "session.model_change" {
                    if let m = data["newModel"] as? String, !m.isEmpty {
                        model = m
                    }
                }
                if cwd == nil, type == "session.info",
                   (data["infoType"] as? String) == "folder_trust",
                   let msg = data["message"] as? String {
                    cwd = parseFolderTrustPath(from: msg)
                }

                if type == "user.message" {
                    estimatedEvents += 1
                    if title == nil, let content = data["content"] as? String {
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { title = trimmed }
                    }
                } else if type == "assistant.message" {
                    let content = (data["content"] as? String) ?? ""
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        estimatedEvents += 1
                    }
                    if let toolReqs = data["toolRequests"] as? [[String: Any]] {
                        estimatedEvents += toolReqs.count
                        estimatedCommands += toolReqs.count
                    }
                } else if type == "tool.execution_complete" {
                    estimatedEvents += 1
                }
            }
        } catch {
            return nil
        }

        let id = forcedID ?? sessionID ?? fallbackID(for: url)
        return Session(
            id: id,
            source: .copilot,
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
            lightweightCommands: estimatedCommands
        )
    }

    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let reader = JSONLReader(url: url)

        var events: [SessionEvent] = []
        var sessionID: String? = nil
        var model: String? = nil
        var cwd: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var idx = 0

        // Tool join state keyed by toolCallId
        var toolByCallID: [String: (name: String?, args: Any?)] = [:]
        // Track toolCalls we emitted so we can attach args to results even if execution events come first.
        var seenToolCallIDs: Set<String> = []

        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let obj = decodeObject(rawLine) else { return }
                guard let type = obj["type"] as? String else { return }
                let data = obj["data"] as? [String: Any] ?? [:]
                let ts = decodeDate(obj["timestamp"])

                if let ts {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                if sessionID == nil, type == "session.start" {
                    sessionID = data["sessionId"] as? String
                }
                if type == "session.model_change" {
                    if let m = data["newModel"] as? String, !m.isEmpty {
                        model = m
                    }
                }
                if cwd == nil, type == "session.info",
                   (data["infoType"] as? String) == "folder_trust",
                   let msg = data["message"] as? String {
                    cwd = parseFolderTrustPath(from: msg)
                }

                let baseID = (forcedID ?? sessionID ?? fallbackID(for: url)) + String(format: "-%04d", idx)
                let parentID = obj["parentId"] as? String
                let messageID = obj["id"] as? String

                switch type {
                case "user.message":
                    if let content = data["content"] as? String {
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .user,
                            role: "user",
                            text: content,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(obj)
                        ))
                    }

                case "assistant.message":
                    let content = (data["content"] as? String) ?? ""
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .assistant,
                            role: "assistant",
                            text: content,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(obj)
                        ))
                    }

                    if let toolReqs = data["toolRequests"] as? [[String: Any]] {
                        var tci = 0
                        for tr in toolReqs {
                            tci += 1
                            let toolCallId = tr["toolCallId"] as? String
                            let name = tr["name"] as? String
                            let args = tr["arguments"]

                            if let toolCallId, !toolCallId.isEmpty {
                                toolByCallID[toolCallId] = (name: name, args: args)
                                seenToolCallIDs.insert(toolCallId)
                            }

                            events.append(SessionEvent(
                                id: baseID + String(format: "-t%02d", tci),
                                timestamp: ts,
                                kind: .tool_call,
                                role: "assistant",
                                text: nil,
                                toolName: name,
                                toolInput: stringifyJSON(args),
                                toolOutput: nil,
                                messageID: toolCallId,
                                parentID: messageID,
                                isDelta: false,
                                rawJSON: rawJSONBase64(obj)
                            ))
                        }
                    }

                case "tool.execution_start":
                    guard let toolCallId = data["toolCallId"] as? String, !toolCallId.isEmpty else { return }
                    let toolName = data["toolName"] as? String
                    let args = data["arguments"]

                    if let existing = toolByCallID[toolCallId] {
                        let mergedName = existing.name ?? toolName
                        let mergedArgs = existing.args ?? args
                        toolByCallID[toolCallId] = (name: mergedName, args: mergedArgs)
                    } else {
                        toolByCallID[toolCallId] = (name: toolName, args: args)
                    }

                    // Keep as meta unless we need it to backfill a missing toolRequests entry.
                    if !seenToolCallIDs.contains(toolCallId) {
                        seenToolCallIDs.insert(toolCallId)
                        events.append(SessionEvent(
                            id: baseID + "-t00",
                            timestamp: ts,
                            kind: .tool_call,
                            role: "assistant",
                            text: nil,
                            toolName: toolName,
                            toolInput: stringifyJSON(args),
                            toolOutput: nil,
                            messageID: toolCallId,
                            parentID: messageID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(obj)
                        ))
                    }

                case "tool.execution_complete":
                    let toolCallId = data["toolCallId"] as? String
                    let success = (data["success"] as? Bool) ?? true
                    let result = data["result"] as? [String: Any]
                    let output = normalizeEscapes(result?["content"] as? String)

                    let toolMeta = toolCallId.flatMap { toolByCallID[$0] }
                    let toolName = toolMeta?.name
                    let toolInput = stringifyJSON(toolMeta?.args)

                    // Avoid storing huge results twice: keep full output in toolOutput, but redact from rawJSON.
                    var sanitized = obj
                    if let toolCallId, let output, output.utf8.count > maxRawResultContentBytes {
                        sanitized = sanitizeToolComplete(obj: obj, toolCallId: toolCallId, outputBytes: output.utf8.count)
                    }

                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: success ? .tool_result : .error,
                        role: "tool",
                        text: nil,
                        toolName: toolName,
                        toolInput: toolInput,
                        toolOutput: output,
                        messageID: toolCallId,
                        parentID: toolCallId,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitized)
                    ))

                case "session.info":
                    if let infoType = data["infoType"] as? String,
                       let msg = data["message"] as? String {
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .meta,
                            role: "meta",
                            text: "[info/\(infoType)] \(msg)",
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(obj)
                        ))
                    }

                case "session.truncation":
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[truncation]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSONBase64(obj)
                    ))

                case "assistant.turn_start", "assistant.turn_end":
                    // Marker only; keep as meta for raw view.
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[\(type)]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSONBase64(obj)
                    ))

                case "session.start":
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[session.start]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSONBase64(obj)
                    ))

                case "session.model_change":
                    if let m = data["newModel"] as? String {
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .meta,
                            role: "meta",
                            text: "[model] \(m)",
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: messageID,
                            parentID: parentID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(obj)
                        ))
                    }

                default:
                    // Unknown/unsupported event types: preserve as meta.
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: "[\(type)]",
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: messageID,
                        parentID: parentID,
                        isDelta: false,
                        rawJSON: rawJSONBase64(obj)
                    ))
                }
            }
        } catch {
            return nil
        }

        let id = forcedID ?? sessionID ?? fallbackID(for: url)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        return Session(
            id: id,
            source: .copilot,
            startTime: tmin,
            endTime: tmax,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil
        )
    }

    // MARK: - Helpers

    private static func decodeObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func decodeDate(_ any: Any?) -> Date? {
        guard let any else { return nil }
        if let s = any as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: s)
        }
        if let t = any as? TimeInterval { return Date(timeIntervalSince1970: t) }
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }

    private static func stringifyJSON(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return String(describing: any)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func rawJSONBase64(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: []).base64EncodedString()) ?? ""
    }

    private static func fallbackID(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if !base.isEmpty { return base }
        return sha256(path: url.path)
    }

    private static func sha256(path: String) -> String {
        let d = Data(path.utf8)
        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseFolderTrustPath(from message: String) -> String? {
        // Example:
        // "Folder /Users/alexm/Repository/Triada has been added to trusted folders."
        guard let range = message.range(of: "Folder ") else { return nil }
        let rest = message[range.upperBound...]
        if let end = rest.range(of: " has been") {
            return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func sanitizeToolComplete(obj: [String: Any], toolCallId: String, outputBytes: Int) -> [String: Any] {
        var root = obj
        guard var data = root["data"] as? [String: Any] else { return root }
        guard var result = data["result"] as? [String: Any] else { return root }
        result["content"] = "[OUTPUT_OMITTED bytes=\(outputBytes)]"
        data["result"] = result
        data["toolCallId"] = toolCallId
        root["data"] = data
        return root
    }
}
