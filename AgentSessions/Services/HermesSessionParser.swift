import Foundation
import SQLite3

final class HermesSessionParser {
    private struct SessionJSON: Codable {
        struct ModelConfig: Codable {
            let cwd: String?
        }

        enum JSONValue: Codable {
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
                case .string(let value):
                    try container.encode(value)
                case .number(let value):
                    try container.encode(value)
                case .bool(let value):
                    try container.encode(value)
                case .object(let value):
                    try container.encode(value)
                case .array(let value):
                    try container.encode(value)
                case .null:
                    try container.encodeNil()
                }
            }
        }

        struct Message: Codable {
            struct ToolCall: Codable {
                struct FunctionCall: Codable {
                    let name: String?
                    let arguments: String?
                }

                let id: String?
                let type: String?
                let function: FunctionCall?
            }

            let role: String?
            let content: String?
            let tool_calls: [ToolCall]?
            let tool_call_id: String?
            let tool_name: String?
            let finish_reason: String?
            let reasoning: String?
            let codex_reasoning_items: [JSONValue]?
        }

        let session_id: String
        let model: String?
        let platform: String?
        let session_start: String?
        let last_updated: String?
        let cwd: String?
        let model_config: ModelConfig?
        let message_count: Int?
        let messages: [Message]?
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

    private static let localTimestampWithFractional: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return formatter
    }()

    private static let localTimestampBasic: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parseFile(at url: URL) -> Session? {
        guard let payload = load(url) else { return nil }
        let eventsEstimate = estimatedNonMetaCount(messages: payload.messages ?? [], fallback: payload.message_count ?? 0)
        let title = deriveTitle(messages: payload.messages ?? [], platform: payload.platform, sessionID: payload.session_id)
        let projectContext = extractProjectContext(payload)

        return Session(
            id: payload.session_id,
            source: .hermes,
            startTime: parseDate(payload.session_start),
            endTime: parseDate(payload.last_updated),
            model: payload.model,
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: eventsEstimate,
            events: [],
            cwd: projectContext.cwd,
            repoName: projectContext.repoName,
            lightweightTitle: title,
            lightweightCommands: estimatedToolCalls(messages: payload.messages ?? []),
            customTitle: title
        )
    }

    static func parseFileFull(at url: URL) -> Session? {
        guard let payload = load(url) else { return nil }
        let timestamp = parseDate(payload.last_updated) ?? parseDate(payload.session_start)
        let events = buildEvents(messages: payload.messages ?? [], fallbackTimestamp: timestamp)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let title = deriveTitle(messages: payload.messages ?? [], platform: payload.platform, sessionID: payload.session_id)
        let projectContext = extractProjectContext(payload)

        return Session(
            id: payload.session_id,
            source: .hermes,
            startTime: parseDate(payload.session_start),
            endTime: parseDate(payload.last_updated),
            model: payload.model,
            filePath: url.path,
            fileSizeBytes: fileSize(at: url),
            eventCount: nonMetaCount,
            events: events,
            cwd: projectContext.cwd,
            repoName: projectContext.repoName,
            lightweightTitle: title,
            lightweightCommands: estimatedToolCalls(messages: payload.messages ?? []),
            customTitle: title
        )
    }

    private static func load(_ url: URL) -> SessionJSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionJSON.self, from: data)
    }

    private static func extractProjectContext(_ payload: SessionJSON) -> (cwd: String?, repoName: String?) {
        let direct = payload.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nested = payload.model_config?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (direct?.isEmpty == false) ? direct : ((nested?.isEmpty == false) ? nested : nil)
        let platform = normalizedPlatformLabel(payload.platform)

        // Preserve the recorded cwd for search/path filtering, but use Hermes'
        // platform as the row project label so the Project column shows origin.
        return (normalizedStoredPath(candidate), platform)
    }

    private static func normalizedPlatformLabel(_ platform: String?) -> String? {
        guard let label = platform?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }
        return label
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

    private static func buildEvents(messages: [SessionJSON.Message], fallbackTimestamp: Date?) -> [SessionEvent] {
        var events: [SessionEvent] = []
        events.reserveCapacity(messages.count * 2)

        for (index, message) in messages.enumerated() {
            let baseID = String(format: "hermes-%04d", index + 1)
            let rawJSON = rawJSONBase64(message)
            let role = normalizedRole(message.role)
            let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)

            switch role {
            case "user":
                if let content, !content.isEmpty {
                    events.append(SessionEvent(id: baseID,
                                               timestamp: fallbackTimestamp,
                                               kind: .user,
                                               role: "user",
                                               text: content,
                                               toolName: nil,
                                               toolInput: nil,
                                               toolOutput: nil,
                                               messageID: nil,
                                               parentID: nil,
                                               isDelta: false,
                                               rawJSON: rawJSON))
                }
            case "assistant":
                if let content, !content.isEmpty {
                    events.append(SessionEvent(id: baseID,
                                               timestamp: fallbackTimestamp,
                                               kind: .assistant,
                                               role: "assistant",
                                               text: content,
                                               toolName: nil,
                                               toolInput: nil,
                                               toolOutput: nil,
                                               messageID: nil,
                                               parentID: nil,
                                               isDelta: false,
                                               rawJSON: rawJSON))
                }
                for (toolIndex, toolCall) in (message.tool_calls ?? []).enumerated() {
                    let toolID = toolCall.id?.trimmingCharacters(in: .whitespacesAndNewlines)
                    events.append(SessionEvent(id: baseID + String(format: "-t%02d", toolIndex + 1),
                                               timestamp: fallbackTimestamp,
                                               kind: .tool_call,
                                               role: "assistant",
                                               text: nil,
                                               toolName: toolCall.function?.name,
                                               toolInput: toolCall.function?.arguments,
                                               toolOutput: nil,
                                               messageID: toolID,
                                               parentID: nil,
                                               isDelta: false,
                                               rawJSON: rawJSON))
                }
                if let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                    events.append(SessionEvent(id: baseID + "-meta",
                                               timestamp: fallbackTimestamp,
                                               kind: .meta,
                                               role: "meta",
                                               text: "[reasoning] " + reasoning,
                                               toolName: nil,
                                               toolInput: nil,
                                               toolOutput: nil,
                                               messageID: nil,
                                               parentID: nil,
                                               isDelta: false,
                                               rawJSON: rawJSON))
                }
            case "tool":
                let toolOutput = content
                let kind: SessionEventKind = (message.finish_reason == "error") ? .error : .tool_result
                events.append(SessionEvent(id: baseID,
                                           timestamp: fallbackTimestamp,
                                           kind: kind,
                                           role: "tool",
                                           text: nil,
                                           toolName: message.tool_name,
                                           toolInput: nil,
                                           toolOutput: toolOutput,
                                           messageID: message.tool_call_id,
                                           parentID: nil,
                                           isDelta: false,
                                           rawJSON: rawJSON))
            default:
                if let content, !content.isEmpty {
                    events.append(SessionEvent(id: baseID,
                                               timestamp: fallbackTimestamp,
                                               kind: .meta,
                                               role: role,
                                               text: content,
                                               toolName: nil,
                                               toolInput: nil,
                                               toolOutput: nil,
                                               messageID: nil,
                                               parentID: nil,
                                               isDelta: false,
                                               rawJSON: rawJSON))
                }
            }
        }

        return events
    }

    private static func deriveTitle(messages: [SessionJSON.Message], platform: String?, sessionID: String) -> String {
        for message in messages where normalizedRole(message.role) == "user" {
            guard let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
            if looksLikeHermesPreamble(content) { continue }
            let collapsed = collapseWhitespace(in: content)
            if !collapsed.isEmpty { return collapsed }
        }

        let platformLabel = (platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? platform! : "Hermes"
        return "\(platformLabel) \(sessionID)"
    }

    private static func looksLikeHermesPreamble(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("[system: the user has invoked") { return true }
        if lowered.contains("[skill directory:") { return true }
        if lowered.contains("name: hermes-agent") { return true }
        if lowered.contains("resolve any relative paths in this skill") { return true }
        return false
    }

    private static func estimatedNonMetaCount(messages: [SessionJSON.Message], fallback: Int) -> Int {
        guard !messages.isEmpty else { return max(0, fallback) }
        var count = 0
        for message in messages {
            let role = normalizedRole(message.role)
            let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["user", "assistant", "tool"].contains(role), let content, !content.isEmpty {
                count += 1
            }
            count += message.tool_calls?.count ?? 0
        }
        return max(count, fallback)
    }

    private static func estimatedToolCalls(messages: [SessionJSON.Message]) -> Int {
        messages.reduce(0) { $0 + ($1.tool_calls?.count ?? 0) }
    }

    private static func normalizedRole(_ role: String?) -> String {
        role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = iso8601Fractional.date(from: value) { return date }
        if let date = iso8601Basic.date(from: value) { return date }
        if let date = localTimestampWithFractional.date(from: value) { return date }
        return localTimestampBasic.date(from: value)
    }

    private static func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    private static func collapseWhitespace(in value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func rawJSONBase64<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return data.base64EncodedString()
    }
}

struct HermesStateDBReader {
    static func listSessions(dbURL: URL) -> [Session] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, source, model, model_config, started_at, ended_at, message_count, tool_call_count, title
            FROM sessions
            ORDER BY started_at DESC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            guard !id.isEmpty else { continue }
            let source = text(stmt, 1)
            let model = optionalText(stmt, 2)
            let modelConfig = optionalText(stmt, 3)
            let startedAt = sqlite3_column_double(stmt, 4)
            let endedAt = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 5)
            let messageCount = Int(sqlite3_column_int64(stmt, 6))
            let toolCount = Int(sqlite3_column_int64(stmt, 7))
            let title = optionalText(stmt, 8) ?? firstUserMessage(db: db, sessionID: id)
            let cwd = cwdFromModelConfig(modelConfig)
            sessions.append(Session(
                id: id,
                source: .hermes,
                startTime: startedAt > 0 ? Date(timeIntervalSince1970: startedAt) : nil,
                endTime: endedAt > 0 ? Date(timeIntervalSince1970: endedAt) : nil,
                model: model,
                filePath: dbURL.path,
                fileSizeBytes: nil,
                eventCount: messageCount,
                events: [],
                cwd: cwd,
                repoName: source.isEmpty ? nil : source,
                lightweightTitle: title,
                lightweightCommands: toolCount > 0 ? toolCount : nil,
                customTitle: title
            ))
        }
        return sessions
    }

    static func loadFullSession(dbURL: URL, sessionID: String) -> Session? {
        guard let base = listSessions(dbURL: dbURL).first(where: { $0.id == sessionID }) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, role, content, tool_call_id, tool_calls, tool_name, timestamp, finish_reason, reasoning, reasoning_content, codex_reasoning_items
            FROM messages
            WHERE session_id = ?
            ORDER BY timestamp, id;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return base }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var events: [SessionEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let role = text(stmt, 1).lowercased()
            let content = optionalText(stmt, 2)
            let toolCallID = optionalText(stmt, 3)
            let toolCalls = optionalText(stmt, 4)
            let toolName = optionalText(stmt, 5)
            let timestamp = sqlite3_column_double(stmt, 6)
            let finishReason = optionalText(stmt, 7)
            let reasoning = optionalText(stmt, 8) ?? optionalText(stmt, 9)
            let codexReasoning = optionalText(stmt, 10)
            let date = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
            let raw = rawJSONBase64([
                "id": rowID,
                "role": role,
                "content": jsonValue(content),
                "tool_call_id": jsonValue(toolCallID),
                "tool_calls": jsonValue(toolCalls),
                "tool_name": jsonValue(toolName),
                "timestamp": timestamp,
                "finish_reason": jsonValue(finishReason)
            ])

            if let reasoning, !reasoning.isEmpty {
                events.append(SessionEvent(id: "hermes-\(rowID)-reasoning",
                                           timestamp: date,
                                           kind: .meta,
                                           role: role,
                                           text: reasoning,
                                           toolName: nil,
                                           toolInput: nil,
                                           toolOutput: nil,
                                           messageID: nil,
                                           parentID: nil,
                                           isDelta: false,
                                           rawJSON: raw))
            }
            if let codexReasoning, !codexReasoning.isEmpty {
                events.append(SessionEvent(id: "hermes-\(rowID)-codex-reasoning",
                                           timestamp: date,
                                           kind: .meta,
                                           role: role,
                                           text: codexReasoning,
                                           toolName: nil,
                                           toolInput: nil,
                                           toolOutput: nil,
                                           messageID: nil,
                                           parentID: nil,
                                           isDelta: false,
                                           rawJSON: raw))
            }

            switch role {
            case "user":
                if let content, !content.isEmpty {
                    events.append(event(id: "hermes-\(rowID)", timestamp: date, kind: .user, role: "user", text: content, rawJSON: raw))
                }
            case "assistant":
                if let content, !content.isEmpty {
                    events.append(event(id: "hermes-\(rowID)", timestamp: date, kind: .assistant, role: "assistant", text: content, rawJSON: raw))
                }
                events.append(contentsOf: toolCallEvents(rowID: rowID, timestamp: date, toolCalls: toolCalls, rawJSON: raw))
            case "tool":
                events.append(SessionEvent(id: "hermes-\(rowID)-tool",
                                           timestamp: date,
                                           kind: .tool_result,
                                           role: "tool",
                                           text: nil,
                                           toolName: toolName,
                                           toolInput: nil,
                                           toolOutput: content,
                                           messageID: toolCallID,
                                           parentID: nil,
                                           isDelta: false,
                                           rawJSON: raw))
            default:
                if let content, !content.isEmpty {
                    events.append(event(id: "hermes-\(rowID)-meta", timestamp: date, kind: .meta, role: role, text: content, rawJSON: raw))
                }
            }
        }

        return Session(id: base.id,
                       source: base.source,
                       startTime: base.startTime,
                       endTime: base.endTime,
                       model: base.model,
                       filePath: base.filePath,
                       fileSizeBytes: base.fileSizeBytes,
                       eventCount: events.filter { $0.kind != .meta }.count,
                       events: events,
                       cwd: base.cwd,
                       repoName: base.repoName,
                       lightweightTitle: base.lightweightTitle,
                       lightweightCommands: base.lightweightCommands,
                       customTitle: base.customTitle)
    }

    private static func event(id: String, timestamp: Date?, kind: SessionEventKind, role: String, text: String, rawJSON: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: timestamp,
                     kind: kind,
                     role: role,
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: nil,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON)
    }

    private static func toolCallEvents(rowID: Int64, timestamp: Date?, toolCalls: String?, rawJSON: String) -> [SessionEvent] {
        guard let toolCalls,
              let data = toolCalls.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.enumerated().map { index, call in
            let function = call["function"] as? [String: Any]
            return SessionEvent(id: "hermes-\(rowID)-tool-\(index)",
                                timestamp: timestamp,
                                kind: .tool_call,
                                role: "assistant",
                                text: nil,
                                toolName: function?["name"] as? String,
                                toolInput: function?["arguments"] as? String,
                                toolOutput: nil,
                                messageID: call["id"] as? String,
                                parentID: nil,
                                isDelta: false,
                                rawJSON: rawJSON)
        }
    }

    private static func firstUserMessage(db: OpaquePointer?, sessionID: String) -> String? {
        let sql = "SELECT content FROM messages WHERE session_id = ? AND role = 'user' ORDER BY timestamp LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return optionalText(stmt, 0)
    }

    private static func cwdFromModelConfig(_ raw: String?) -> String? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = obj["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return (cwd as NSString).expandingTildeInPath
    }

    private static func text(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
    }

    private static func optionalText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        let value = text(stmt, idx)
        return value.isEmpty ? nil : value
    }

    private static func rawJSONBase64(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return ""
        }
        return data.base64EncodedString()
    }

    private static func jsonValue(_ value: String?) -> Any {
        value ?? NSNull()
    }
}
