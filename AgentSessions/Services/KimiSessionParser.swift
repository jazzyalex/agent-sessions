import Foundation

/// Parses Kimi Code `wire.jsonl` op-journals into `Session` values.
///
/// Line 1 is the journal envelope (`type: "metadata"`). Every later line is a
/// flattened op: `{type, ...payload, time}`.
///
/// Conversation content is split across *two* op families, and only carrying
/// both yields a complete transcript:
/// - `context.append_message` holds **user turns only**. Real journals never
///   put an assistant or tool message here — across seven captures every one of
///   these ops was `role: "user"` with no `toolCalls`.
/// - `context.append_loop_event` holds everything the model produced:
///   `content.part` (assistant `text`, plus `think` reasoning), `tool.call`,
///   and `tool.result`. Ignoring it renders Kimi sessions as user turns only
///   and undercounts every message statistic.
enum KimiSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024
    private static let previewLineLimit = 200

    private struct Sidecar: Decodable {
        let archived: Bool?
        let customTitle: String?
        let isCustomTitle: Bool?
        let lastPrompt: String?
        let title: String?
        let workDir: String?
    }

    static func parseFile(at url: URL) -> Session? {
        build(url: url, lineLimit: previewLineLimit, includeEvents: false, allowLargeFile: true)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        build(url: url, lineLimit: nil, includeEvents: true, allowLargeFile: allowLargeFile)
    }

    private static func build(url: URL, lineLimit: Int?, includeEvents: Bool, allowLargeFile: Bool) -> Session? {
        guard let id = KimiSessionDiscovery.sessionID(forWireFile: url) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }

        guard let lines = loadLines(url, lineLimit: lineLimit) else { return nil }

        var events: [SessionEvent] = []
        var startTime: Date?
        var endTime: Date?
        var model: String?
        var firstUserText: String?
        var nonMetaCount = 0

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            let time = timestamp(from: object)
            if let time {
                if startTime == nil || time < startTime! { startTime = time }
                if endTime == nil || time > endTime! { endTime = time }
            }

            if type == "config.update" || type == "llm.request",
               let m = modelIdentifier(from: object) {
                model = m
            }

            let built = makeEvents(type: type, object: object, time: time, line: line, index: index)
            nonMetaCount += built.filter { $0.kind != .meta }.count
            if firstUserText == nil {
                firstUserText = built.first(where: { $0.kind == .user })?.text
            }
            if includeEvents { events.append(contentsOf: built) }
        }

        let sidecar = readSidecar(for: url)
        let cwd = sidecar?.workDir
        let title = sidecar?.title ?? sidecar?.lastPrompt ?? firstUserText
        let customTitle = (sidecar?.isCustomTitle == true) ? sidecar?.customTitle : nil

        return Session(id: id,
                       source: .kimi,
                       startTime: startTime,
                       endTime: endTime,
                       model: model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: nonMetaCount,
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       customTitle: customTitle,
                       surface: .cli)
    }

    /// Streams newline-delimited lines, stopping once `lineLimit` is reached.
    ///
    /// The preview path must never materialise the whole journal: a single
    /// `llm.tools_snapshot` op is ~70KB and `llm.request` repeats once per
    /// retry, so an active session's `wire.jsonl` grows fast — and
    /// `parseLightweight` runs over every discovered file on every scan.
    /// Mirrors `PiSessionParser.loadPreviewEntries`.
    private static func loadLines(_ url: URL, lineLimit: Int?) -> [String]? {
        guard let lineLimit else {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var lines: [String] = []
        var buffer = Data()
        let newline = Data([0x0A])

        while lines.count < lineLimit {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while lines.count < lineLimit, let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = Data(buffer[range.upperBound..<buffer.endIndex])
                if lineData.isEmpty { continue }
                if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
            }
        }

        if lines.count < lineLimit, !buffer.isEmpty,
           let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    private static func readSidecar(for url: URL) -> Sidecar? {
        let path = KimiSessionDiscovery.stateFile(forWireFile: url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    /// `time` and `created_at` are both epoch milliseconds.
    private static func timestamp(from object: [String: Any]) -> Date? {
        if let ms = object["time"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = object["created_at"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }

    /// Real 0.29.1 journals never put a bare `model` on `config.update` — the
    /// user's selection arrives as `modelAlias` ("moonshot-ai/kimi-k2.7-code"),
    /// while `llm.request` carries both `modelAlias` and the concrete `model`
    /// ("kimi-k2.7-code"). Strip the provider segment so both paths agree.
    private static func modelIdentifier(from object: [String: Any]) -> String? {
        if let alias = object["modelAlias"] as? String, !alias.isEmpty {
            return alias.split(separator: "/").last.map(String.init) ?? alias
        }
        if let m = object["model"] as? String, !m.isEmpty { return m }
        return nil
    }

    private static func makeEvents(type: String,
                                   object: [String: Any],
                                   time: Date?,
                                   line: String,
                                   index: Int) -> [SessionEvent] {
        if type == "context.append_loop_event",
           let event = object["event"] as? [String: Any],
           let eventType = event["type"] as? String {
            return makeLoopEvents(eventType: eventType, event: event,
                                  time: time, line: line, index: index)
        }

        guard type == "context.append_message",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return [meta(index: index, suffix: "", time: time, line: line)]
        }

        var out: [SessionEvent] = []
        let text = textContent(from: message["content"])

        switch role {
        case "user":
            out.append(SessionEvent(id: "\(index)-u", timestamp: time, kind: .user, role: role, text: text,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        // No observed Kimi journal emits an assistant or tool *message* — that
        // content arrives as loop events instead. These two branches are a
        // defensive fallback for a future format that materialises them; do not
        // read them as the live assistant path.
        case "assistant":
            if let text, !text.isEmpty {
                out.append(SessionEvent(id: "\(index)-a", timestamp: time, kind: .assistant, role: role, text: text,
                                        toolName: nil, toolInput: nil, toolOutput: nil,
                                        messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
            }
            let calls = message["toolCalls"] as? [[String: Any]] ?? []
            for (callIndex, call) in calls.enumerated() {
                out.append(SessionEvent(id: "\(index)-t\(callIndex)", timestamp: time, kind: .tool_call, role: role, text: nil,
                                        toolName: call["name"] as? String,
                                        toolInput: call["arguments"] as? String,
                                        toolOutput: nil,
                                        messageID: call["id"] as? String, parentID: nil, isDelta: false, rawJSON: line))
            }
        case "tool":
            let isError = (message["isError"] as? Bool) == true
            out.append(SessionEvent(id: "\(index)-r", timestamp: time, kind: isError ? .error : .tool_result, role: role, text: nil,
                                    toolName: nil, toolInput: nil, toolOutput: text,
                                    messageID: message["toolCallId"] as? String, parentID: nil, isDelta: false, rawJSON: line))
        default:
            out.append(SessionEvent(id: "\(index)-m", timestamp: time, kind: .meta, role: role, text: text,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        }

        if out.isEmpty {
            out.append(SessionEvent(id: "\(index)-m", timestamp: time, kind: .meta, role: role, text: nil,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        }
        return out
    }

    /// Builds events from `context.append_loop_event`, the op family that
    /// carries every assistant reply and every tool call Kimi makes.
    ///
    /// One loop event yields at most one `SessionEvent`; `step.begin`/`step.end`
    /// and any future event type fall through to `.meta` so nothing is dropped.
    private static func makeLoopEvents(eventType: String,
                                       event: [String: Any],
                                       time: Date?,
                                       line: String,
                                       index: Int) -> [SessionEvent] {
        switch eventType {
        case "content.part":
            // `think` parts are reasoning, not answer text — same rule the
            // message-content path applies in `textContent`.
            guard let part = event["part"] as? [String: Any],
                  part["type"] as? String == "text",
                  let text = part["text"] as? String,
                  !text.isEmpty else {
                return [meta(index: index, suffix: "-m", time: time, line: line)]
            }
            return [SessionEvent(id: "\(index)-a", timestamp: time, kind: .assistant, role: "assistant", text: text,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: event["stepUuid"] as? String, parentID: nil, isDelta: false, rawJSON: line)]

        case "tool.call":
            return [SessionEvent(id: "\(index)-t", timestamp: time, kind: .tool_call, role: "assistant", text: nil,
                                 toolName: event["name"] as? String,
                                 toolInput: jsonString(event["args"]),
                                 toolOutput: nil,
                                 messageID: event["toolCallId"] as? String,
                                 parentID: event["stepUuid"] as? String, isDelta: false, rawJSON: line)]

        case "tool.result":
            // `result` is an object: `{output}`, `{output, isError}`, or
            // `{output, note}`. Failures are flagged by a nested `isError`,
            // never at the event's top level.
            let result = event["result"] as? [String: Any]
            // Every observed result is an object; the bare-string branch is
            // speculative forward-compat, not a shape seen in the wild.
            let output = (result?["output"] as? String) ?? (event["result"] as? String)
            let isError = (result?["isError"] as? Bool) == true
            return [SessionEvent(id: "\(index)-r", timestamp: time, kind: isError ? .error : .tool_result, role: "tool", text: nil,
                                 toolName: nil, toolInput: nil, toolOutput: output,
                                 messageID: event["toolCallId"] as? String,
                                 parentID: event["parentUuid"] as? String, isDelta: false, rawJSON: line)]

        default:
            return [meta(index: index, suffix: "-m", time: time, line: line)]
        }
    }

    private static func meta(index: Int, suffix: String, time: Date?, line: String) -> SessionEvent {
        SessionEvent(id: "\(index)\(suffix)", timestamp: time, kind: .meta, role: nil, text: nil,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: line)
    }

    /// Serialises `tool.call` arguments, which arrive as a JSON object.
    /// Mirrors `PiSessionParser.jsonString`, including its large-payload guard.
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

    /// Flattens nested ContentParts. `think` parts are reasoning, not answer
    /// text, so they are dropped from the rendered body.
    private static func textContent(from content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        let chunks: [String] = parts.compactMap { part in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "image_url": return "[image]"
            case "audio_url": return "[audio]"
            case "video_url": return "[video]"
            default: return nil
            }
        }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
