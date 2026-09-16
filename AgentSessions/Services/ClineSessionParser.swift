import Foundation

/// Parses Cline CLI and Cline Desktop session directories into `Session` values.
///
/// A session directory holds `<session-id>.json` (the manifest sidecar) beside
/// `<session-id>.messages.json` (the transcript). The manifest is authoritative
/// for identity, workspace, title, model, surface and both timestamps; message
/// `ts` fields carry per-event time in epoch milliseconds.
///
/// Shapes verified against the redacted stage0 fixtures
/// (`Resources/Fixtures/stage0/agents/cline/cli_tool`,
/// `desktop_continued`):
///
/// - Manifest — `{version, session_id, source, started_at, ended_at, model,
///   cwd, workspace_root, prompt, metadata}`. `metadata.title` is the session
///   name; `messages_path` is an absolute export-time path and is never followed —
///   the adjacent `<session-id>.messages.json` is read instead.
/// - Messages — `{version, sessionId, messages[]}`. Each message is
///   `{role, ts, id, content[]}` where content blocks are:
///   `text` (`{type, text}`), `thinking` (`{type, thinking}`),
///   `tool_use` (`{type, id, name, input}`), `tool_result`
///   (`{type, tool_use_id, name, content, is_error}`).
/// - `text` renders under its enclosing message role; `thinking` is reasoning
///   and renders as meta; `tool_use` renders as a tool call preserving name and
///   JSON input; `tool_result` renders as a tool result, or an error when
///   `is_error` is true; any other block type survives as meta with its raw JSON.
enum ClineSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024
    static let defaultPreviewParseMaxBytes = 50 * 1024 * 1024

    // MARK: - Entry points

    /// Lightweight list pass: manifest plus message counts, never the events.
    /// `eventCount` is the exact non-meta count and `lightweightCommands` the
    /// tool-call count, so the list filters stay accurate without materialising
    /// the transcript.
    static func parseFile(at url: URL,
                          maxBytes: Int = defaultPreviewParseMaxBytes) -> Session? {
        guard combinedFileSize(forManifest: url) <= maxBytes else { return nil }
        return build(url: url, includeEvents: false)
    }

    static func parseFileFull(at url: URL,
                              allowLargeFile: Bool = false,
                              maxBytes: Int = defaultFullParseMaxBytes) -> Session? {
        let size = combinedFileSize(forManifest: url)
        if !allowLargeFile, size > maxBytes { return nil }
        return build(url: url, includeEvents: true)
    }

    private static func build(url: URL, includeEvents: Bool) -> Session? {
        guard let manifest = readManifest(at: url) else { return nil }
        guard manifest.version == 1 else { return nil }
        let size = combinedFileSize(forManifest: url)

        // Stable ID is the manifest's own `session_id`; the filename is only the
        // fallback for a manifest that lost it.
        let filenameBase = url.deletingPathExtension().lastPathComponent
        let id = manifest.sessionID?.isEmpty == false ? manifest.sessionID! : filenameBase
        guard !id.isEmpty else { return nil }

        let startTime = manifest.startedAt.flatMap(parseISODate)
        let endTime = manifest.endedAt.flatMap(parseISODate)
        let cwd = firstNonEmpty(manifest.cwd, manifest.workspaceRoot)
        let surface = surface(for: manifest.source)

        let messagesURL = ClineSessionDiscovery.messagesFile(forManifest: url)
        let messagesFile = readMessages(at: messagesURL, preserveRawBlocks: includeEvents)
        // A companion can be observed between replace/write operations. A full
        // reload must not turn either a missing or malformed messages file into an
        // authoritative empty session that clears a transcript already in memory.
        if includeEvents, messagesFile == nil { return nil }
        if let messagesFile, messagesFile.version != 1 { return nil }
        // The transcript belongs to this manifest only when its top-level session
        // id agrees. A nonempty mismatch is a real inconsistency (not a transient
        // write), so fail closed rather than attaching a stranger's transcript —
        // in both modes, so the list never offers a row the full parse refuses.
        if let companionID = messagesFile?.sessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !companionID.isEmpty,
           companionID != id {
            return nil
        }
        let messages = messagesFile?.messages

        var events: [SessionEvent] = []
        var nonMetaCount = 0
        var commandCount = 0
        var firstUserText: String?

        if let messages {
            for (messageIndex, message) in messages.enumerated() {
                if includeEvents {
                    let built = eventsForMessage(message, messageIndex: messageIndex)
                    nonMetaCount += built.filter { $0.kind != .meta }.count
                    commandCount += built.filter { $0.kind == .tool_call }.count
                    if firstUserText == nil {
                        firstUserText = built.first(where: { $0.kind == .user })?.text
                    }
                    events.append(contentsOf: built)
                } else {
                    let summary = lightweightSummary(for: message)
                    nonMetaCount += summary.nonMetaCount
                    commandCount += summary.commandCount
                    if firstUserText == nil { firstUserText = summary.firstUserText }
                }
            }
        }

        let title = firstNonEmpty(manifest.metadataTitle, manifest.prompt, firstUserText)

        return Session(id: id,
                       source: .cline,
                       startTime: startTime,
                       endTime: endTime,
                       model: manifest.model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: nonMetaCount,
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       lightweightCommands: commandCount > 0 ? commandCount : nil,
                       parentSessionID: nil,
                       subagentType: nil,
                       surface: surface,
                       reasoningEffort: nil)
    }

    /// Cline stores a session across two files. Limits and displayed sizes must
    /// account for both so a small manifest cannot hide an oversized transcript.
    static func combinedFileSize(forManifest url: URL) -> Int {
        let messagesURL = ClineSessionDiscovery.messagesFile(forManifest: url)
        return [url, messagesURL].reduce(into: 0) { total, fileURL in
            total += max(0, (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Manifest

    private struct Manifest {
        let version: Int?
        let sessionID: String?
        let source: String?
        let startedAt: String?
        let endedAt: String?
        let model: String?
        let cwd: String?
        let workspaceRoot: String?
        let prompt: String?
        let metadataTitle: String?

        init(object: [String: Any]) {
            version = object["version"] as? Int
            sessionID = object["session_id"] as? String
            source = (object["source"] as? String)
                ?? ((object["metadata"] as? [String: Any])?["source"] as? String)
            startedAt = object["started_at"] as? String
            endedAt = object["ended_at"] as? String
            model = object["model"] as? String
            cwd = object["cwd"] as? String
            workspaceRoot = object["workspace_root"] as? String
            prompt = (object["prompt"] as? String)
                ?? ((object["metadata"] as? [String: Any])?["prompt"] as? String)
            metadataTitle = (object["metadata"] as? [String: Any])?["title"] as? String
        }
    }

    private static func readManifest(at url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Manifest(object: object)
    }

    // MARK: - Messages

    struct Message {
        let role: String
        let time: Date?
        let id: String?
        let blocks: [[String: Any]]
        let rawBlocks: [String]

        init(role: String, time: Date?, id: String?, blocks: [[String: Any]], rawBlocks: [String]) {
            self.role = role
            self.time = time
            self.id = id
            self.blocks = blocks
            self.rawBlocks = rawBlocks
        }
    }

    private struct MessagesFile {
        let version: Int?
        let sessionId: String?
        let messages: [Message]
    }

    private static func readMessages(at url: URL, preserveRawBlocks: Bool) -> MessagesFile? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = object["messages"] as? [[String: Any]] else { return nil }
        // Retain the top-level identity so the caller can fail closed on mismatch.
        // Both key spellings are accepted; absence reads as "no claim", never as mismatch.
        let version = object["version"] as? Int
        let sessionId = (object["sessionId"] as? String) ?? (object["session_id"] as? String)
        var out: [Message] = []
        out.reserveCapacity(rawMessages.count)
        for raw in rawMessages {
            let role = (raw["role"] as? String) ?? "unknown"
            let time = msDate(raw["ts"])
            let id = raw["id"] as? String
            let blocks = raw["content"] as? [[String: Any]] ?? []
            let rawBlocks = preserveRawBlocks ? blocks.map { jsonEncode($0) } : []
            out.append(Message(role: role, time: time, id: id, blocks: blocks, rawBlocks: rawBlocks))
        }
        return MessagesFile(version: version, sessionId: sessionId, messages: out)
    }

    private static func lightweightSummary(for message: Message) -> (nonMetaCount: Int, commandCount: Int, firstUserText: String?) {
        let role = message.role.lowercased()
        var nonMetaCount = 0
        var commandCount = 0
        var firstUserText: String?

        for block in message.blocks {
            switch block["type"] as? String {
            case "text":
                if role == "user" || role == "assistant" { nonMetaCount += 1 }
                if role == "user", firstUserText == nil,
                   let text = block["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstUserText = text
                }
            case "tool_use":
                nonMetaCount += 1
                commandCount += 1
            case "tool_result":
                nonMetaCount += 1
            default:
                break
            }
        }
        return (nonMetaCount, commandCount, firstUserText)
    }

    /// One message becomes one event per content block, in order. Event ids are
    /// `"<messageIndex>-<blockIndex>"`; the message index is the coordinate other
    /// tools can use to locate a record inside the messages file.
    /// Internal so tests can exercise a single message without a file on disk.
    static func eventsForMessage(_ message: Message, messageIndex: Int) -> [SessionEvent] {
        var out: [SessionEvent] = []
        for (blockIndex, block) in message.blocks.enumerated() {
            let raw = message.rawBlocks.count > blockIndex ? message.rawBlocks[blockIndex] : jsonEncode(block)
            out.append(contentsOf: eventsForBlock(block,
                                                  role: message.role,
                                                  messageID: message.id,
                                                  time: message.time,
                                                  messageIndex: messageIndex,
                                                  blockIndex: blockIndex,
                                                  raw: raw))
        }
        return out
    }

    /// Dictionary entry point used by file-level tests that hand-construct blocks.
    static func eventsForBlockDictionary(_ block: [String: Any],
                                         role: String,
                                         messageID: String?,
                                         time: Date?,
                                         messageIndex: Int,
                                         blockIndex: Int) -> [SessionEvent] {
        eventsForBlock(block,
                       role: role,
                       messageID: messageID,
                       time: time,
                       messageIndex: messageIndex,
                       blockIndex: blockIndex,
                       raw: jsonEncode(block))
    }

    private static func eventsForBlock(_ block: [String: Any],
                                       role: String,
                                       messageID: String?,
                                       time: Date?,
                                       messageIndex: Int,
                                       blockIndex: Int,
                                       raw: String) -> [SessionEvent] {
        let eventID = "\(messageIndex)-\(blockIndex)"
        let type = (block["type"] as? String) ?? ""
        switch type {
        case "text":
            let text = block["text"] as? String
            let lowered = role.lowercased()
            if lowered == "user" {
                return [SessionEvent(id: eventID, timestamp: time, kind: .user, role: role, text: text,
                                     toolName: nil, toolInput: nil, toolOutput: nil,
                                     messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)]
            } else if lowered == "assistant" {
                return [SessionEvent(id: eventID, timestamp: time, kind: .assistant, role: role, text: text,
                                     toolName: nil, toolInput: nil, toolOutput: nil,
                                     messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)]
            } else {
                return [SessionEvent(id: eventID, timestamp: time, kind: .meta, role: role, text: text,
                                     toolName: nil, toolInput: nil, toolOutput: nil,
                                     messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)]
            }
        case "thinking":
            let text = block["thinking"] as? String
            return [SessionEvent(id: eventID, timestamp: time, kind: .meta, role: "thinking", text: text,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)]
        case "tool_use":
            return [SessionEvent(id: eventID, timestamp: time, kind: .tool_call, role: "assistant", text: nil,
                                 toolName: block["name"] as? String,
                                 toolInput: jsonString(block["input"]),
                                 toolOutput: nil,
                                 messageID: block["id"] as? String ?? messageID,
                                 parentID: messageID, isDelta: false, rawJSON: raw)]
        case "tool_result":
            let output = toolResultOutput(block["content"])
            let isError = (block["is_error"] as? Bool) == true
            return [SessionEvent(id: eventID, timestamp: time, kind: isError ? .error : .tool_result, role: "tool", text: nil,
                                 toolName: block["name"] as? String,
                                 toolInput: nil,
                                 toolOutput: output,
                                 messageID: block["tool_use_id"] as? String ?? messageID,
                                 parentID: messageID, isDelta: false, rawJSON: raw)]
        default:
            return [SessionEvent(id: eventID, timestamp: time, kind: .meta, role: role, text: nil,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)]
        }
    }

    private static func toolResultOutput(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return jsonString(value)
    }

    // MARK: - Helpers

    private static func surface(for source: String?) -> SessionSurface? {
        switch source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cli": return .cli
        case "desktop": return .desktop
        default: return nil
        }
    }

    /// Message timestamps are epoch milliseconds, like OpenCode's and Fx's.
    private static func msDate(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let ms = number.int64Value
            return ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1_000.0) : nil
        }
        return nil
    }

    private static func parseISODate(_ value: String) -> Date? {
        isoFracFormatter.date(from: value) ?? isoNoFracFormatter.date(from: value)
    }

    private static let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        if data.count > 32_768 {
            return "[OMITTED large JSON payload bytes=\(data.count)]"
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonEncode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
}
