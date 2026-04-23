import Foundation

final class HermesSessionParser {
    private struct SessionJSON: Codable {
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
            cwd: nil,
            repoName: nil,
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
            cwd: nil,
            repoName: nil,
            lightweightTitle: title,
            lightweightCommands: estimatedToolCalls(messages: payload.messages ?? []),
            customTitle: title
        )
    }

    private static func load(_ url: URL) -> SessionJSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionJSON.self, from: data)
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
