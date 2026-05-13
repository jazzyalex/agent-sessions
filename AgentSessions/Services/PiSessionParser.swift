import Foundation

final class PiSessionParser {
    private static let previewLineLimit = 200
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024

    private enum JSONValue: Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    private struct Entry: Codable {
        struct Message: Codable {
            let role: String?
            let content: JSONValue?
            let api: String?
            let provider: String?
            let model: String?
            let usage: JSONValue?
            let stopReason: String?
            let timestamp: Double?
            let responseId: String?
            let toolCallId: String?
            let toolName: String?
            let isError: Bool?
            let errorMessage: String?
            let command: String?
            let output: String?
            let exitCode: Int?
            let cancelled: Bool?
            let truncated: Bool?
            let fullOutputPath: String?
            let excludeFromContext: Bool?
            let customType: String?
            let display: Bool?
            let details: JSONValue?
            let summary: String?
            let fromId: String?
            let tokensBefore: Int?
        }

        let type: String
        let version: Int?
        let id: String?
        let parentId: String?
        let timestamp: String?
        let cwd: String?
        let parentSession: String?
        let message: Message?
        let provider: String?
        let modelId: String?
        let thinkingLevel: String?
        let summary: String?
        let name: String?
        let customType: String?
        let content: JSONValue?
        let display: Bool?
        let data: JSONValue?
        let details: JSONValue?
        let label: String?
        let targetId: String?
        let fromId: String?
        let firstKeptEntryId: String?
        let tokensBefore: Int?
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseFile(at url: URL) -> Session? {
        guard let entries = loadPreviewEntries(url, lineLimit: previewLineLimit),
              let header = entries.first(where: { $0.type == "session" }),
              let id = header.id else { return nil }

        let activeEntries = currentTreeEntries(from: entries)
        let messages = activeEntries.compactMap(\.message)
        let nonMetaCount = messages.reduce(0) { $0 + nonMetaEventCount(for: $1) }
        let title = deriveTitle(entries: activeEntries)
        let model = deriveModel(entries: activeEntries)
        let start = parseDate(header.timestamp)
        let end = activeEntries.reversed().compactMap { parseDate($0.timestamp) }.first ?? start

        return Session(
            id: id,
            source: .pi,
            startTime: start,
            endTime: end,
            model: model,
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: nonMetaCount,
            events: [],
            cwd: normalizedStoredPath(header.cwd),
            repoName: repoName(from: header.cwd),
            lightweightTitle: title,
            lightweightCommands: estimatedToolCount(entries: activeEntries),
            parentSessionID: parentSessionID(from: header.parentSession),
            customTitle: title,
            surface: .cli,
            reasoningEffort: deriveThinkingLevel(entries: activeEntries)
        )
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        if !allowLargeFile,
           let fileSize = fileSize(at: url),
           fileSize > defaultFullParseMaxBytes {
            return nil
        }
        guard let entries = loadEntries(url),
              let header = entries.first(where: { $0.type == "session" }),
              let id = header.id else { return nil }

        let activeEntries = currentTreeEntries(from: entries)
        let events = buildEvents(entries: activeEntries)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let title = deriveTitle(entries: activeEntries)
        let start = parseDate(header.timestamp)
        let end = activeEntries.reversed().compactMap { parseDate($0.timestamp) }.first ?? start

        return Session(
            id: id,
            source: .pi,
            startTime: start,
            endTime: end,
            model: deriveModel(entries: activeEntries),
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: nonMetaCount,
            events: events,
            cwd: normalizedStoredPath(header.cwd),
            repoName: repoName(from: header.cwd),
            lightweightTitle: title,
            lightweightCommands: estimatedToolCount(entries: activeEntries),
            parentSessionID: parentSessionID(from: header.parentSession),
            customTitle: title,
            surface: .cli,
            reasoningEffort: deriveThinkingLevel(entries: activeEntries)
        )
    }

    private static func currentTreeEntries(from entries: [Entry]) -> [Entry] {
        guard entries.count > 1,
              entries.contains(where: { $0.parentId != nil }),
              let leafID = entries.reversed().compactMap(\.id).first else {
            return entries
        }

        var byID: [String: Entry] = [:]
        for entry in entries {
            if let id = entry.id { byID[id] = entry }
        }

        var activeIDs = Set<String>()
        var nextID: String? = leafID
        while let id = nextID, !activeIDs.contains(id), let entry = byID[id] {
            activeIDs.insert(id)
            nextID = entry.parentId
        }

        guard activeIDs.count > 1 else { return entries }
        return entries.filter { entry in
            guard let id = entry.id else { return true }
            return activeIDs.contains(id)
        }
    }

    private static func loadEntries(_ url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var entries: [Entry] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            if let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)) {
                entries.append(entry)
            } else if shouldIgnoreTrailingPartialLine(content: content, lineIndex: index, lineCount: lines.count, parsedEntries: entries) {
                break
            } else {
                return nil
            }
        }
        guard entries.first?.type == "session" else { return nil }
        return entries
    }

    private static func loadPreviewEntries(_ url: URL, lineLimit: Int) -> [Entry]? {
        let decoder = JSONDecoder()
        var entries: [Entry] = []

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var buffer = Data()
            let newline = Data([0x0A])

            while entries.count < lineLimit {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while entries.count < lineLimit, let range = buffer.range(of: newline) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer = Data(buffer[range.upperBound..<buffer.endIndex])
                    if lineData.isEmpty { continue }
                    guard let entry = try? decoder.decode(Entry.self, from: lineData) else {
                        return nil
                    }
                    entries.append(entry)
                }
            }

            if entries.count < lineLimit,
               !buffer.isEmpty,
               let entry = try? decoder.decode(Entry.self, from: buffer) {
                entries.append(entry)
            }
        } catch {
            return nil
        }

        guard entries.first?.type == "session" else { return nil }
        return entries
    }

    private static func shouldIgnoreTrailingPartialLine(content: String,
                                                       lineIndex: Int,
                                                       lineCount: Int,
                                                       parsedEntries: [Entry]) -> Bool {
        !parsedEntries.isEmpty && !content.hasSuffix("\n") && lineIndex == lineCount - 1
    }

    private static func buildEvents(entries: [Entry]) -> [SessionEvent] {
        entries.enumerated().flatMap { index, entry -> [SessionEvent] in
            let id = entry.id ?? String(format: "pi-%04d", index + 1)
            let rawJSON = rawJSONBase64(entry)
            if entry.type == "message", let message = entry.message {
                return buildMessageEvents(entry: entry,
                                          message: message,
                                          baseID: id,
                                          fallbackTimestamp: parseDate(entry.timestamp) ?? parseMillis(message.timestamp),
                                          rawJSON: rawJSON)
            }

            guard entry.type != "session" else { return [] }
            let text = metaText(for: entry)
            return [SessionEvent(id: id,
                                 timestamp: parseDate(entry.timestamp),
                                 kind: .meta,
                                 role: entry.type,
                                 text: text,
                                 toolName: nil,
                                 toolInput: nil,
                                 toolOutput: nil,
                                 messageID: id,
                                 parentID: entry.parentId,
                                 isDelta: false,
                                 rawJSON: rawJSON)]
        }
    }

    private static func normalizedKind(for message: Entry.Message) -> SessionEventKind {
        if message.isError == true { return .error }
        switch normalizedRole(message.role) {
        case "toolresult", "bashexecution":
            return .tool_result
        case "custom", "branchsummary", "compactionsummary":
            return .meta
        default:
            break
        }
        return SessionEventKind.from(role: message.role, type: nil)
    }

    private static func buildMessageEvents(entry: Entry,
                                           message: Entry.Message,
                                           baseID: String,
                                           fallbackTimestamp: Date?,
                                           rawJSON: String) -> [SessionEvent] {
        let role = normalizedRole(message.role)
        switch role {
        case "assistant":
            return assistantEvents(entry: entry,
                                   message: message,
                                   baseID: baseID,
                                   fallbackTimestamp: fallbackTimestamp,
                                   rawJSON: rawJSON)
        case "toolresult":
            return [toolResultEvent(entry: entry,
                                    message: message,
                                    baseID: baseID,
                                    fallbackTimestamp: fallbackTimestamp,
                                    rawJSON: rawJSON)]
        case "bashexecution":
            return bashExecutionEvents(entry: entry,
                                       message: message,
                                       baseID: baseID,
                                       fallbackTimestamp: fallbackTimestamp,
                                       rawJSON: rawJSON)
        case "custom", "branchsummary", "compactionsummary":
            return [metaMessageEvent(entry: entry,
                                     message: message,
                                     baseID: baseID,
                                     fallbackTimestamp: fallbackTimestamp,
                                     rawJSON: rawJSON)]
        default:
            let kind = normalizedKind(for: message)
            let text = textContent(from: message.content)
            return [SessionEvent(id: baseID,
                                 timestamp: fallbackTimestamp,
                                 kind: kind,
                                 role: message.role,
                                 text: (kind == .user || kind == .assistant || kind == .error) ? text : nil,
                                 toolName: message.toolName,
                                 toolInput: kind == .tool_call ? text : nil,
                                 toolOutput: kind == .tool_result ? text : nil,
                                 messageID: baseID,
                                 parentID: entry.parentId,
                                 isDelta: false,
                                 rawJSON: rawJSON)]
        }
    }

    private static func assistantEvents(entry: Entry,
                                        message: Entry.Message,
                                        baseID: String,
                                        fallbackTimestamp: Date?,
                                        rawJSON: String) -> [SessionEvent] {
        guard case .array(let blocks)? = message.content else {
            let text = textContent(from: message.content)
            guard text?.isEmpty == false else { return [] }
            return [SessionEvent(id: baseID,
                                 timestamp: fallbackTimestamp,
                                 kind: .assistant,
                                 role: message.role,
                                 text: text,
                                 toolName: nil,
                                 toolInput: nil,
                                 toolOutput: nil,
                                 messageID: baseID,
                                 parentID: entry.parentId,
                                 isDelta: false,
                                 rawJSON: rawJSON)]
        }

        var events: [SessionEvent] = []
        for (blockIndex, block) in blocks.enumerated() {
            guard case .object(let object) = block else { continue }
            let blockID = baseID + String(format: "-b%02d", blockIndex + 1)
            let blockType = normalizedBlockType(stringValue(object["type"]))
            switch blockType {
            case "text":
                guard let text = stringValue(object["text"]), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                events.append(SessionEvent(id: blockID,
                                           timestamp: fallbackTimestamp,
                                           kind: .assistant,
                                           role: message.role,
                                           text: text,
                                           toolName: nil,
                                           toolInput: nil,
                                           toolOutput: nil,
                                           messageID: baseID,
                                           parentID: entry.parentId,
                                           isDelta: false,
                                           rawJSON: rawJSON))
            case "thinking":
                guard let thinking = stringValue(object["thinking"]), !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                events.append(SessionEvent(id: blockID,
                                           timestamp: fallbackTimestamp,
                                           kind: .meta,
                                           role: "thinking",
                                           text: "[thinking] \(thinking)",
                                           toolName: nil,
                                           toolInput: nil,
                                           toolOutput: nil,
                                           messageID: baseID,
                                           parentID: entry.parentId,
                                           isDelta: false,
                                           rawJSON: rawJSON))
            case "toolcall":
                events.append(SessionEvent(id: blockID,
                                           timestamp: fallbackTimestamp,
                                           kind: .tool_call,
                                           role: message.role,
                                           text: nil,
                                           toolName: stringValue(object["name"]),
                                           toolInput: jsonString(object["arguments"]),
                                           toolOutput: nil,
                                           messageID: stringValue(object["id"]) ?? baseID,
                                           parentID: entry.parentId,
                                           isDelta: false,
                                           rawJSON: rawJSON))
            default:
                continue
            }
        }
        return events
    }

    private static func toolResultEvent(entry: Entry,
                                        message: Entry.Message,
                                        baseID: String,
                                        fallbackTimestamp: Date?,
                                        rawJSON: String) -> SessionEvent {
        let text = textContent(from: message.content)
        return SessionEvent(id: baseID,
                            timestamp: fallbackTimestamp,
                            kind: message.isError == true ? .error : .tool_result,
                            role: message.role,
                            text: message.isError == true ? text : nil,
                            toolName: message.toolName,
                            toolInput: nil,
                            toolOutput: message.isError == true ? nil : text,
                            messageID: message.toolCallId ?? baseID,
                            parentID: message.toolCallId ?? entry.parentId,
                            isDelta: false,
                            rawJSON: rawJSON)
    }

    private static func bashExecutionEvents(entry: Entry,
                                            message: Entry.Message,
                                            baseID: String,
                                            fallbackTimestamp: Date?,
                                            rawJSON: String) -> [SessionEvent] {
        let output = message.output ?? message.errorMessage
        let isError = message.exitCode.map { $0 != 0 } ?? false
        let commandID = baseID + "-cmd"
        let resultID = baseID + "-result"
        return [
            SessionEvent(id: commandID,
                         timestamp: fallbackTimestamp,
                         kind: .tool_call,
                         role: message.role,
                         text: nil,
                         toolName: "bash",
                         toolInput: message.command,
                         toolOutput: nil,
                         messageID: commandID,
                         parentID: entry.parentId,
                         isDelta: false,
                         rawJSON: rawJSON),
            SessionEvent(id: resultID,
                         timestamp: fallbackTimestamp,
                         kind: isError ? .error : .tool_result,
                         role: message.role,
                         text: isError ? output : nil,
                         toolName: "bash",
                         toolInput: nil,
                         toolOutput: isError ? nil : output,
                         messageID: commandID,
                         parentID: commandID,
                         isDelta: false,
                         rawJSON: rawJSON)
        ]
    }

    private static func metaMessageEvent(entry: Entry,
                                         message: Entry.Message,
                                         baseID: String,
                                         fallbackTimestamp: Date?,
                                         rawJSON: String) -> SessionEvent {
        let role = normalizedRole(message.role)
        let text: String? = {
            switch role {
            case "custom":
                let prefix = message.customType.map { "[custom/\($0)] " } ?? "[custom] "
                return prefix + (textContent(from: message.content) ?? "")
            case "branchsummary":
                return "[branch_summary] \(message.summary ?? "")"
            case "compactionsummary":
                return "[compaction_summary] \(message.summary ?? "")"
            default:
                return textContent(from: message.content)
            }
        }()
        return SessionEvent(id: baseID,
                            timestamp: fallbackTimestamp,
                            kind: .meta,
                            role: message.role,
                            text: text,
                            toolName: nil,
                            toolInput: nil,
                            toolOutput: nil,
                            messageID: baseID,
                            parentID: entry.parentId,
                            isDelta: false,
                            rawJSON: rawJSON)
    }

    private static func textContent(from value: JSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .array(let values):
            var hasImage = false
            let parts = values.compactMap { item -> String? in
                guard case .object(let object) = item else { return nil }
                if normalizedBlockType(stringValue(object["type"])) == "image" { hasImage = true }
                if let text = stringValue(object["text"]) { return text }
                if let text = stringValue(object["content"]) { return text }
                if let thinking = stringValue(object["thinking"]) { return thinking }
                return nil
            }
            if parts.isEmpty {
                return hasImage ? "Image attached" : nil
            }
            return parts.joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func metaText(for entry: Entry) -> String {
        switch entry.type {
        case "model_change":
            return "Pi model: \([entry.provider, entry.modelId].compactMap { $0 }.joined(separator: "/"))"
        case "thinking_level_change":
            return "Pi thinking level: \(entry.thinkingLevel ?? "unknown")"
        case "compaction":
            return "Pi compaction: \(entry.summary ?? "")"
        case "branch_summary":
            return "Pi branch summary: \(entry.summary ?? "")"
        case "custom":
            let type = entry.customType ?? "unknown"
            return "Pi custom entry \(type): \(jsonString(entry.data) ?? "")"
        case "custom_message":
            let type = entry.customType ?? "unknown"
            return "Pi custom message \(type): \(textContent(from: entry.content) ?? "")"
        case "label":
            let label = entry.label ?? "cleared"
            return "Pi label \(label) on \(entry.targetId ?? "unknown")"
        case "session_info":
            return "Pi session name: \(entry.name ?? "")"
        default:
            return "Pi \(entry.type)"
        }
    }

    private static func deriveTitle(entries: [Entry]) -> String {
        if let name = entries.reversed().first(where: { $0.type == "session_info" })?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        for entry in entries where entry.type == "message" {
            guard normalizedRole(entry.message?.role) == "user",
                  let text = collapsedWhitespace(textContent(from: entry.message?.content)),
                  !text.isEmpty else { continue }
            return text
        }
        return entries.first?.id.map { "Pi session \($0.prefix(8))" } ?? "Pi session"
    }

    private static func deriveModel(entries: [Entry]) -> String? {
        if let assistant = entries.reversed().compactMap(\.message).first(where: { normalizedRole($0.role) == "assistant" }) {
            return assistant.model
        }
        if let modelChange = entries.reversed().first(where: { $0.type == "model_change" }) {
            return modelChange.modelId
        }
        return nil
    }

    private static func deriveThinkingLevel(entries: [Entry]) -> String? {
        entries.reversed().first(where: { $0.type == "thinking_level_change" })?.thinkingLevel
    }

    private static func estimatedToolCount(entries: [Entry]) -> Int {
        entries.compactMap(\.message).reduce(0) { count, message in
            let role = normalizedRole(message.role)
            let messageToolCount = (role == "toolresult" || role == "bashexecution") ? 1 : 0
            return count + toolCallBlockCount(in: message.content) + messageToolCount
        }
    }

    private static func nonMetaEventCount(for message: Entry.Message) -> Int {
        let kind = normalizedKind(for: message)
        if normalizedRole(message.role) == "assistant" {
            return assistantContentEventCount(message.content)
        }
        if normalizedRole(message.role) == "bashexecution" {
            return 2
        }
        return kind == .meta ? 0 : 1
    }

    private static func assistantContentEventCount(_ content: JSONValue?) -> Int {
        guard case .array(let blocks)? = content else {
            return textContent(from: content)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1 : 0
        }
        return blocks.reduce(0) { count, block in
            guard case .object(let object) = block,
                  let type = stringValue(object["type"]) else { return count }
            let normalizedType = normalizedBlockType(type)
            if normalizedType == "text" || normalizedType == "toolcall" { return count + 1 }
            return count
        }
    }

    private static func toolCallBlockCount(in content: JSONValue?) -> Int {
        guard case .array(let blocks)? = content else { return 0 }
        return blocks.filter { block in
            guard case .object(let object) = block else { return false }
            return normalizedBlockType(stringValue(object["type"])) == "toolcall"
        }.count
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return iso8601Fractional.date(from: value) ?? iso8601Basic.date(from: value)
    }

    private static func parseMillis(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value / 1000.0)
    }

    private static func normalizedStoredPath(_ rawPath: String?) -> String? {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func repoName(from rawPath: String?) -> String? {
        guard let path = normalizedStoredPath(rawPath) else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func parentSessionID(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func fileSize(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize
    }

    private static func normalizedRole(_ role: String?) -> String {
        role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""
    }

    private static func stringValue(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return text
        case .number(let number):
            return String(number)
        case .bool(let bool):
            return String(bool)
        default:
            return nil
        }
    }

    private static func normalizedBlockType(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""
    }

    private static func jsonString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = stringValue(value) { return string }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        if data.count > 32_768 {
            return "[OMITTED large JSON payload bytes=\(data.count)]"
        }
        return String(data: data, encoding: .utf8)
    }

    private static func collapsedWhitespace(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private static func rawJSONBase64<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return data.base64EncodedString()
    }
}
