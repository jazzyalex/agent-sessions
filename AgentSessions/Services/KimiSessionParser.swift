import Foundation

/// Parses Kimi Code `wire.jsonl` op-journals into `Session` values.
///
/// Line 1 is the journal envelope (`type: "metadata"`). Every later line is a
/// flattened op: `{type, ...payload, time}`. Conversation content arrives as
/// `context.append_message` ops carrying a nested `Message`.
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

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let lineLimit, lines.count > lineLimit { lines = Array(lines.prefix(lineLimit)) }

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
        guard type == "context.append_message",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return [SessionEvent(id: "\(index)", timestamp: time, kind: .meta, role: nil, text: nil,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: nil, parentID: nil, isDelta: false, rawJSON: line)]
        }

        var out: [SessionEvent] = []
        let text = textContent(from: message["content"])

        switch role {
        case "user":
            out.append(SessionEvent(id: "\(index)-u", timestamp: time, kind: .user, role: role, text: text,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
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
