import Foundation
import CryptoKit

/// Parser for Droid (Factory) JSONL session formats.
///
/// Supported dialects:
/// - A) Interactive on-disk session store (`~/.factory/sessions/.../*.jsonl`):
///      `type=session_start` + `type=message` with `message.content[]` parts (`text`, `tool_use`, `tool_result`)
/// - B) Stream-json exec logs (`droid exec --output-format stream-json`):
///      `type=system|message|tool_call|tool_result|completion`
final class DroidSessionParser {
    private enum Dialect {
        case sessionStore
        case streamJSON
    }

    private final class LockedISO8601DateFormatter: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: ISO8601DateFormatter

        init(formatOptions: ISO8601DateFormatter.Options) {
            let f = ISO8601DateFormatter()
            f.formatOptions = formatOptions
            formatter = f
        }

        func date(from string: String) -> Date? {
            lock.lock()
            let date = formatter.date(from: string)
            lock.unlock()
            return date
        }
    }

    private static let previewScanLimit = 200
    private static let sniffScanLimit = 50
    private static let maxRawResultContentBytes = 8_192

    private static let systemReminderOpenTag = "<system-reminder>"
    private static let systemReminderCloseTag = "</system-reminder>"
    private static let dateFormatterWithFractionalSeconds = LockedISO8601DateFormatter(
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )
    private static let dateFormatter = LockedISO8601DateFormatter(formatOptions: [.withInternetDateTime])

    private static func normalizedType(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func normalizedRole(_ raw: Any?) -> String {
        guard let raw = raw as? String else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func canonicalPartType(_ raw: Any?) -> String {
        guard let raw = raw as? String else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func sessionIDField(_ obj: [String: Any]) -> String? {
        return stringValue(obj, keys: ["session_id", "sessionId"])
            ?? stringValue(obj, keys: ["session"])
    }

    private static func messageText(_ obj: [String: Any]) -> String? {
        return stringValue(obj, keys: ["text", "content", "message"])
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        guard let any else { return nil }
        if let boolValue = any as? Bool { return boolValue }
        if let stringValue = any as? String {
            let lower = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower == "true" || lower == "1" { return true }
            if lower == "false" || lower == "0" { return false }
        }
        return nil
    }

    // MARK: - Public

    static func looksLikeStreamJSONFile(url: URL) -> Bool {
        let lines = readFirstLines(url: url, maxBytes: 512 * 1024, maxLines: sniffScanLimit)
        guard !lines.isEmpty else { return false }

        var recognized = 0
        var sawSessionID = false
        var sawPrimary = false

        for line in lines {
            guard let obj = decodeObject(line),
                  let typeRaw = obj["type"] as? String else { continue }
            let type = normalizedType(typeRaw)

            switch type {
            case "system", "message", "toolcall", "toolresult", "completion", "error":
                recognized += 1
            default:
                break
            }

            if sessionIDField(obj) != nil {
                sawSessionID = true
            }
            if type == "message", normalizedRole(obj["role"]) == "user", messageText(obj) != nil {
                sawPrimary = true
            }
            if type == "toolcall", stringValue(obj, keys: ["toolName", "tool_name", "name"]) != nil { sawPrimary = true }
            if type == "completion", obj["finalText"] != nil { sawPrimary = true }
            if type == "error", messageText(obj) != nil { sawPrimary = true }
        }

        // Require multiple signals to avoid false positives.
        return recognized >= 3 && sawSessionID && sawPrimary
    }

    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        guard let dialect = detectDialect(url: url) else { return nil }

        switch dialect {
        case .sessionStore:
            return parseSessionStorePreview(url: url, forcedID: forcedID, size: size, mtime: mtime)
        case .streamJSON:
            return parseStreamJSONPreview(url: url, forcedID: forcedID, size: size, mtime: mtime)
        }
    }

    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        guard let dialect = detectDialect(url: url) else { return nil }

        switch dialect {
        case .sessionStore:
            return parseSessionStoreFull(url: url, forcedID: forcedID, size: size, mtime: mtime)
        case .streamJSON:
            return parseStreamJSONFull(url: url, forcedID: forcedID, size: size, mtime: mtime)
        }
    }

    // MARK: - Dialect detection

    private static func detectDialect(url: URL) -> Dialect? {
        // Fast path: stream-json candidates (projects root) can be detected by type list.
        if looksLikeStreamJSONFile(url: url) { return .streamJSON }

        // Otherwise, check for interactive store markers in the head.
        let lines = readFirstLines(url: url, maxBytes: 256 * 1024, maxLines: 5)
        for line in lines {
            guard let obj = decodeObject(line),
                  let typeRaw = obj["type"] as? String else { continue }
            let type = normalizedType(typeRaw)
            if type == "sessionstart" { return .sessionStore }
            if type == "message", obj["message"] is [String: Any] { return .sessionStore }
        }
        return nil
    }

    // MARK: - Session store (A)

    private static func parseSessionStorePreview(url: URL, forcedID: String?, size: Int, mtime: Date) -> Session? {
        let reader = JSONLReader(url: url)
        var sessionID: String? = forcedID
        var title: String? = nil
        var cwd: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var estimatedEvents = 0
        var estimatedCommands = 0
        var idx = 0

        // Model from adjacent settings file when present.
        let model: String? = loadModelFromSettingsSibling(url: url)

        do {
            try reader.forEachLineWhile({ rawLine in
                idx += 1
                guard idx <= previewScanLimit else { return false }
                guard let obj = decodeObject(rawLine),
                      let type = obj["type"] as? String else { return true }

                if normalizedType(type) == "sessionstart" {
                    if sessionID == nil { sessionID = obj["id"] as? String }
                    if title == nil { title = obj["title"] as? String }
                    if cwd == nil { cwd = obj["cwd"] as? String }
                    return true
                }

                if normalizedType(type) != "message" { return true }

                if let ts = decodeDate(obj["timestamp"]) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                guard let msg = obj["message"] as? [String: Any],
                      let parts = msg["content"] as? [[String: Any]] else { return true }
                let role = normalizedRole(msg["role"])

                // Title fallback: first user text block that isn't empty.
                if title == nil, role == "user" {
                    if let first = parts.first(where: { canonicalPartType($0["type"]) == "text" }),
                       let text = first["text"] as? String {
                        let extracted = extractUserPromptFromSystemReminder(text)
                        let trimmed = extracted.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { title = trimmed }
                    }
                }

                var hasText = false
                for p in parts {
                    let pt = canonicalPartType(p["type"])
                    if pt == "text", let text = p["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasText = true
                    } else if pt == "tooluse" {
                        estimatedCommands += 1
                        estimatedEvents += 1
                    } else if pt == "toolresult" {
                        estimatedEvents += 1
                    }
                }
                if hasText { estimatedEvents += 1 }

                return true
            })
        } catch {
            return nil
        }

        let id = sessionID ?? forcedID ?? sha256(path: url.path)
        return Session(
            id: id,
            source: .droid,
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

    private static func parseSessionStoreFull(url: URL, forcedID: String?, size: Int, mtime: Date) -> Session? {
        let reader = JSONLReader(url: url)

        var events: [SessionEvent] = []
        var sessionID: String? = forcedID
        var cwd: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil

        // Join state: tool_use.id -> (name, input)
        var toolUseByID: [String: (name: String?, input: Any?)] = [:]

        let model: String? = loadModelFromSettingsSibling(url: url)

        var idx = 0
        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let obj = decodeObject(rawLine),
                      let type = obj["type"] as? String else { return }

                if normalizedType(type) == "sessionstart" {
                    if sessionID == nil { sessionID = obj["id"] as? String }
                    if cwd == nil { cwd = obj["cwd"] as? String }
                    return
                }

                if normalizedType(type) != "message" { return }
                let ts = decodeDate(obj["timestamp"])
                if let ts {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                let envelopeID = obj["id"] as? String
                guard let msg = obj["message"] as? [String: Any],
                      let parts = msg["content"] as? [[String: Any]] else {
                    return
                }
                let roleRaw = normalizedRole(msg["role"])

                var textParts: [String] = []
                var seq = 0

                func flushTextIfNeeded() {
                    let joined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    textParts.removeAll(keepingCapacity: true)
                    guard !joined.isEmpty else { return }
                    seq += 1
                    let kind: SessionEventKind = (roleRaw == "user") ? .user : .assistant

                    if kind == .user {
                        let extracted = extractUserPromptFromSystemReminder(joined)
                        let originalTrimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                        let reminderTrimmed = extracted.reminder?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let promptText = extracted.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

                        let canSplit = (reminderTrimmed?.isEmpty == false) && !promptText.isEmpty && promptText != originalTrimmed
                        if canSplit, let reminderText = reminderTrimmed {
                            events.append(SessionEvent(
                                id: eventID(for: url, index: idx) + String(format: "-p%02d-pre", seq),
                                timestamp: ts,
                                kind: .user,
                                role: roleRaw,
                                text: reminderText,
                                toolName: nil,
                                toolInput: nil,
                                toolOutput: nil,
                                messageID: envelopeID,
                                parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                                isDelta: false,
                                rawJSON: rawJSONBase64(sanitizeLargeStrings(in: ["type": "system_reminder", "content": reminderText]))
                            ))
                        }

                        let finalText = canSplit ? promptText : originalTrimmed
                        if !finalText.isEmpty {
                            events.append(SessionEvent(
                                id: eventID(for: url, index: idx) + String(format: "-p%02d", seq),
                                timestamp: ts,
                                kind: .user,
                                role: roleRaw,
                                text: finalText,
                                toolName: nil,
                                toolInput: nil,
                                toolOutput: nil,
                                messageID: envelopeID,
                                parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                                isDelta: false,
                                rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                            ))
                        }
                        return
                    }

                    events.append(SessionEvent(
                        id: eventID(for: url, index: idx) + String(format: "-p%02d", seq),
                        timestamp: ts,
                        kind: kind,
                        role: roleRaw,
                        text: joined,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: envelopeID,
                        parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))
                }

                var toolSeq = 0
                for p in parts {
                    let pt = canonicalPartType(p["type"])
                    if pt == "text" {
                        if let text = p["text"] as? String { textParts.append(text) }
                        continue
                    }

                    // Non-text blocks should preserve ordering relative to surrounding text.
                    flushTextIfNeeded()

                    if pt == "tooluse" {
                        toolSeq += 1
                        let toolID = stringValue(p, keys: ["id", "toolId"])
                        let toolName = stringValue(p, keys: ["name", "tool_name"])
                        let input = p["input"]
                        if let toolID, !toolID.isEmpty {
                            toolUseByID[toolID] = (name: toolName, input: input)
                        }
                        events.append(SessionEvent(
                            id: eventID(for: url, index: idx) + String(format: "-t%02d", toolSeq),
                            timestamp: ts,
                            kind: .tool_call,
                            role: "assistant",
                            text: nil,
                            toolName: toolName,
                            toolInput: stringifyJSON(input),
                            toolOutput: nil,
                            messageID: toolID,
                            parentID: envelopeID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(["type": "tool_use", "part": sanitizeLargeStrings(in: p)])
                        ))
                    } else if pt == "toolresult" {
                        toolSeq += 1
                        let toolUseID = stringValue(p, keys: ["tool_use_id", "toolUseId", "tool_use"])
                        let output = p["content"] as? String

                        let toolMeta = toolUseID.flatMap { toolUseByID[$0] }
                        let toolName = toolMeta?.name
                        let toolInput = stringifyJSON(toolMeta?.input)

                        var rawPart = p
                        if let output, output.utf8.count > maxRawResultContentBytes {
                            rawPart["content"] = "[OUTPUT_OMITTED bytes=\(output.utf8.count)]"
                        }

                        events.append(SessionEvent(
                            id: eventID(for: url, index: idx) + String(format: "-r%02d", toolSeq),
                            timestamp: ts,
                            kind: .tool_result,
                            role: "tool",
                            text: nil,
                            toolName: toolName,
                            toolInput: toolInput,
                            toolOutput: output,
                            messageID: toolUseID,
                            parentID: envelopeID,
                            isDelta: false,
                            rawJSON: rawJSONBase64(["type": "tool_result", "part": sanitizeLargeStrings(in: rawPart)])
                        ))
                    } else {
                        // Forward compatible: keep unknown parts as meta.
                        toolSeq += 1
                        events.append(SessionEvent(
                            id: eventID(for: url, index: idx) + String(format: "-m%02d", toolSeq),
                            timestamp: ts,
                            kind: .meta,
                            role: roleRaw,
                            text: "[Unsupported Droid content type: \(pt)]",
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: envelopeID,
                            parentID: obj["parentId"] as? String,
                            isDelta: false,
                            rawJSON: rawJSONBase64(["type": "unknown_part", "part": sanitizeLargeStrings(in: p)])
                        ))
                    }
                }

                flushTextIfNeeded()
            }
        } catch {
            return nil
        }

        let sid = sessionID ?? forcedID ?? sha256(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        return Session(
            id: sid,
            source: .droid,
            startTime: tmin ?? mtime,
            endTime: tmax ?? mtime,
            model: model,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: cwd,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: events.filter { $0.kind == .tool_call }.count
        )
    }

    // MARK: - Stream JSON (B)

    private static func parseStreamJSONPreview(url: URL, forcedID: String?, size: Int, mtime: Date) -> Session? {
        let reader = JSONLReader(url: url)
        var sessionID: String? = forcedID
        var model: String? = nil
        var cwd: String? = nil
        var title: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var estimatedEvents = 0
        var estimatedCommands = 0
        var idx = 0

        do {
            try reader.forEachLineWhile({ rawLine in
                idx += 1
                guard idx <= previewScanLimit else { return false }
                guard let obj = decodeObject(rawLine),
                      let typeRaw = obj["type"] as? String else { return true }
                let type = normalizedType(typeRaw)

                if sessionID == nil {
                    sessionID = sessionIDField(obj)
                }
                if let ts = decodeDate(obj["timestamp"]) {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                switch type {
                case "system":
                    if model == nil { model = stringValue(obj, keys: ["model", "modelId", "model_name"]) }
                    if cwd == nil { cwd = stringValue(obj, keys: ["cwd", "workingDirectory", "working_directory"]) }
                case "message":
                    estimatedEvents += 1
                    let text = messageText(obj)
                    if title == nil,
                       normalizedRole(obj["role"]) == "user",
                       let text {
                        let extracted = extractUserPromptFromSystemReminder(text)
                        let trimmed = extracted.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { title = trimmed }
                    }
                case "toolcall":
                    estimatedCommands += 1
                    estimatedEvents += 1
                case "toolresult":
                    estimatedEvents += 1
                case "completion":
                    let final = (obj["finalText"] as? String) ?? messageText(obj) ?? (obj["final"] as? String)
                    if let final,
                       !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        estimatedEvents += 1
                    }
                case "error":
                    if let errorText = messageText(obj),
                       !errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        estimatedEvents += 1
                    }
                default:
                    break
                }

                return true
            })
        } catch {
            return nil
        }

        let sid = sessionID ?? forcedID ?? sha256(path: url.path)
        return Session(
            id: sid,
            source: .droid,
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

    private static func parseStreamJSONFull(url: URL, forcedID: String?, size: Int, mtime: Date) -> Session? {
        let reader = JSONLReader(url: url)

        var events: [SessionEvent] = []
        var sessionID: String? = forcedID
        var model: String? = nil
        var cwd: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil

        // Join state: toolCallId -> (name, parameters)
        var toolByCallID: [String: (name: String?, params: Any?)] = [:]

        var idx = 0
        do {
            try reader.forEachLine { rawLine in
                idx += 1
                guard let obj = decodeObject(rawLine),
                      let typeRaw = obj["type"] as? String else { return }
                let type = normalizedType(typeRaw)

                if sessionID == nil {
                    sessionID = sessionIDField(obj)
                }
                let ts = decodeDate(obj["timestamp"])
                if let ts {
                    if tmin == nil || ts < tmin! { tmin = ts }
                    if tmax == nil || ts > tmax! { tmax = ts }
                }

                let baseID = (sessionID ?? sha256(path: url.path)) + String(format: "-%05d", idx)

                switch type {
                case "system":
                    if model == nil { model = stringValue(obj, keys: ["model", "modelId", "model_name"]) }
                    if cwd == nil { cwd = stringValue(obj, keys: ["cwd", "workingDirectory", "working_directory"]) }
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "system",
                        text: nil,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "message":
                    let role = normalizedRole(obj["role"])
                    let text = messageText(obj)
                    let kind: SessionEventKind = (role == "user") ? .user : .assistant
                    if kind == .user, let text {
                        let extracted = extractUserPromptFromSystemReminder(text)
                        let originalTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let reminderTrimmed = extracted.reminder?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let promptText = extracted.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

                        let canSplit = (reminderTrimmed?.isEmpty == false) && !promptText.isEmpty && promptText != originalTrimmed
                        if canSplit, let reminderText = reminderTrimmed {
                        events.append(SessionEvent(
                            id: baseID + "-pre",
                            timestamp: ts,
                            kind: .user,
                            role: "user",
                                text: reminderText,
                                toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: obj["id"] as? String,
                            parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                            isDelta: false,
                            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: ["type": "system_reminder", "content": reminderText]))
                        ))
                    }

                        let finalText = canSplit ? promptText : originalTrimmed
                        events.append(SessionEvent(
                            id: baseID,
                            timestamp: ts,
                            kind: .user,
                            role: "user",
                            text: finalText.isEmpty ? nil : finalText,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: obj["id"] as? String,
                            parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                            isDelta: (obj["subtype"] as? String)?.lowercased() == "delta",
                            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                        ))
                        break
                    }

                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: kind,
                        role: role,
                        text: text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: stringValue(obj, keys: ["parentId", "parent_id"]),
                        isDelta: (obj["subtype"] as? String)?.lowercased() == "delta",
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "toolcall":
                    let callID = stringValue(obj, keys: ["toolCallId", "tool_call_id", "toolCallID"])
                        ?? stringValue(obj, keys: ["id"])
                    let name = stringValue(obj, keys: ["toolName", "tool_name", "name"])
                    let params = obj["parameters"] ?? obj["input"]
                    if let callID, !callID.isEmpty {
                        toolByCallID[callID] = (name: name, params: params)
                    }
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .tool_call,
                        role: "assistant",
                        text: nil,
                        toolName: name,
                        toolInput: stringifyJSON(params),
                        toolOutput: nil,
                        messageID: callID,
                        parentID: stringValue(obj, keys: ["messageId", "message_id"]),
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "toolresult":
                    let callID = stringValue(obj, keys: ["toolCallId", "tool_call_id", "toolCallID"])
                        ?? stringValue(obj, keys: ["id"])
                    let name = stringValue(obj, keys: ["toolName", "tool_name", "name"]) ?? callID.flatMap { toolByCallID[$0]?.name }
                    let value = obj["value"]
                    let output = stringifyJSON(value)
                    let isErrorFlag = boolValue(obj["isError"])
                        ?? boolValue(obj["is_error"])
                        ?? false
                    let exitCode: Int? = {
                        guard let dict = value as? [String: Any] else { return nil }
                        let any = dict["exitCode"] ?? dict["exit_code"] ?? dict["status"]
                            ?? obj["exitCode"] ?? obj["exit_code"]
                        if let i = any as? Int { return i }
                        if let d = any as? Double { return Int(d) }
                        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        return nil
                    }()
                    let isError = isErrorFlag || (exitCode != nil && exitCode != 0)
                    let kind: SessionEventKind = isError ? .error : .tool_result

                    var sanitized = obj
                    if let output, output.utf8.count > maxRawResultContentBytes {
                        sanitized["value"] = "[OUTPUT_OMITTED bytes=\(output.utf8.count)]"
                    }

                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: kind,
                        role: "tool",
                        text: isError ? output : nil,
                        toolName: name,
                        toolInput: callID.flatMap { stringifyJSON(toolByCallID[$0]?.params) },
                        toolOutput: output,
                        messageID: callID,
                        parentID: stringValue(obj, keys: ["messageId", "message_id"]),
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: sanitized))
                    ))

                case "completion":
                    let final = (obj["finalText"] as? String) ?? (obj["final"] as? String) ?? messageText(obj)
                    if let final,
                       !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        events.append(SessionEvent(
                            id: baseID + "-final",
                            timestamp: ts,
                            kind: .assistant,
                            role: "assistant",
                            text: final,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: obj["id"] as? String,
                            parentID: nil,
                            isDelta: false,
                            rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                        ))
                    }
                    // Keep completion stats visible in Raw JSON without cluttering transcript.
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .meta,
                        role: "meta",
                        text: nil,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                case "error":
                    let text = messageText(obj)
                    let source = stringValue(obj, keys: ["source"])
                    let rendered = [source, text]
                        .compactMap { value -> String? in
                            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                            return value
                        }
                        .joined(separator: ": ")
                    events.append(SessionEvent(
                        id: baseID,
                        timestamp: ts,
                        kind: .error,
                        role: "system",
                        text: rendered.isEmpty ? text : rendered,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: obj["id"] as? String,
                        parentID: stringValue(obj, keys: ["sessionId", "session_id"]),
                        isDelta: false,
                        rawJSON: rawJSONBase64(sanitizeLargeStrings(in: obj))
                    ))

                default:
                    // Ignore unknown event types.
                    break
                }
            }
        } catch {
            return nil
        }

        let sid = sessionID ?? forcedID ?? sha256(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        return Session(
            id: sid,
            source: .droid,
            startTime: tmin ?? mtime,
            endTime: tmax ?? mtime,
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

    private static func eventID(for url: URL, index: Int) -> String {
        let base = sha256(path: url.path)
        return base + String(format: "-%05d", index)
    }

    private static func decodeObject(_ rawLine: String) -> [String: Any]? {
        guard let data = rawLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func decodeDate(_ any: Any?) -> Date? {
        guard let any else { return nil }
        if let d = any as? Double { return Date(timeIntervalSince1970: normalizeEpochSeconds(d)) }
        if let i = any as? Int { return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(i))) }
        if let s = any as? String {
            if let d = dateFormatterWithFractionalSeconds.date(from: s) { return d }
            return dateFormatter.date(from: s)
        }
        return nil
    }

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private static func extractUserPromptFromSystemReminder(_ text: String) -> (reminder: String?, prompt: String) {
        // Some Droid sessions embed one or more <system-reminder>...</system-reminder> blocks
        // at the beginning of the first user message. We strip *leading* blocks only.
        var remainder = text
        var reminders: [String] = []

        while true {
            var start = remainder.startIndex
            while start < remainder.endIndex {
                let ch = remainder[start]
                if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                    start = remainder.index(after: start)
                    continue
                }
                break
            }
            guard start < remainder.endIndex else { break }

            let anchored = remainder[start...].range(of: systemReminderOpenTag,
                                                    options: [.caseInsensitive, .anchored])
            guard anchored != nil else { break }

            guard let openEnd = remainder[start...].firstIndex(of: ">") else { break }
            guard let closeRange = remainder.range(of: systemReminderCloseTag,
                                                  options: [.caseInsensitive],
                                                  range: openEnd..<remainder.endIndex) else {
                break
            }

            reminders.append(String(remainder[start..<closeRange.upperBound]))
            remainder = String(remainder[closeRange.upperBound...])
        }

        let prompt = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        let reminderJoined = reminders.isEmpty ? nil : reminders.joined(separator: "\n")
        // If stripping produces nothing, fall back to original text (avoid dropping real content).
        if prompt.isEmpty {
            return (reminderJoined, text)
        }
        return (reminderJoined, prompt)
    }

    private static func stringifyJSON(_ any: Any?) -> String? {
        guard let any else { return nil }
        if let s = any as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return String(describing: any)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func rawJSONBase64(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private static func sha256(path: String) -> String {
        let d = Data(path.utf8)
        let digest = SHA256.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadModelFromSettingsSibling(url: URL) -> String? {
        // Interactive sessions often have an adjacent `*.settings.json` with `model`.
        let settings = url.deletingPathExtension().appendingPathExtension("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { return nil }
        if let model = obj["model"] as? String, !model.isEmpty { return model }
        if let nested = obj["sessionDefaultSettings"] as? [String: Any],
           let model = nested["model"] as? String,
           !model.isEmpty {
            return model
        }
        return nil
    }

    private static func sanitizeLargeStrings(in dict: [String: Any]) -> [String: Any] {
        // Avoid exploding Raw JSON views with huge content fields. We keep the transcript content in
        // SessionEvent.text/toolOutput; raw JSON should remain inspectable but bounded.
        var out = dict
        func sanitizeValue(_ v: Any) -> Any {
            if let s = v as? String, s.utf8.count > maxRawResultContentBytes {
                return "[OMITTED bytes=\(s.utf8.count)]"
            }
            if let d = v as? [String: Any] {
                return sanitizeLargeStrings(in: d)
            }
            if let arr = v as? [Any] {
                return arr.map(sanitizeValue)
            }
            return v
        }
        for (k, v) in out {
            out[k] = sanitizeValue(v)
        }
        return out
    }

    private static func readFirstLines(url: URL, maxBytes: Int, maxLines: Int) -> [String] {
        guard maxBytes > 0, maxLines > 0 else { return [] }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return [] }
        var out: [String] = []
        out.reserveCapacity(min(maxLines, 64))
        var count = 0
        str.enumerateLines { line, stop in
            if count >= maxLines { stop = true; return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(trimmed)
                count += 1
            }
        }
        return out
    }
}
