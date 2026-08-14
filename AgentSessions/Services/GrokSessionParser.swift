import Foundation

/// Parses Grok CLI session directories into `Session` values.
///
/// A session directory holds `summary.json` (sidecar) beside
/// `chat_history.jsonl` (transcript). The sidecar is authoritative for identity,
/// working directory, title, model and both timestamps; the transcript carries
/// no per-record time of its own, so every event inherits the session bounds.
///
/// Transcript record types, all verified against 141 real sessions at CLI
/// version 1.0.0 (`chat_format_version: 1`):
///
/// - `system` — one per session, `content` is the system prompt string.
/// - `user` — `content` is an array of parts (`text`, `image`). A `prompt_index`
///   marks a genuine user turn; `synthetic_reason` marks an injected one, which
///   is why title derivation skips them.
/// - `assistant` — `content` is a plain string, with `model_id`,
///   `model_fingerprint`, `reasoning_effort`, and an optional `tool_calls`
///   array of `{id, name, arguments}` where `arguments` is a JSON *string*.
/// - `reasoning` — readable rationale lives in `summary[].text`;
///   `encrypted_content` is opaque and deliberately ignored.
/// - `tool_result` — `content` string keyed back by `tool_call_id`, plus an
///   optional `images` array of data URLs.
/// - `backend_tool_call` — server-side tools (web search); the descriptor is
///   under `kind`, and no matching `tool_result` is emitted for it.
enum GrokSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024
    private static let previewLineLimit = 200

    private struct Sidecar: Decodable {
        struct Info: Decodable {
            let id: String?
            let cwd: String?
        }
        let info: Info?
        let sessionSummary: String?
        let generatedTitle: String?
        let createdAt: String?
        let updatedAt: String?
        let lastActiveAt: String?
        let currentModelId: String?
        let numChatMessages: Int?
        let reasoningEffort: String?
        let parentSessionId: String?
        let gitRootDir: String?

        enum CodingKeys: String, CodingKey {
            case info
            case sessionSummary = "session_summary"
            case generatedTitle = "generated_title"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case lastActiveAt = "last_active_at"
            case currentModelId = "current_model_id"
            case numChatMessages = "num_chat_messages"
            case reasoningEffort = "reasoning_effort"
            case parentSessionId = "parent_session_id"
            case gitRootDir = "git_root_dir"
        }
    }

    static func parseFile(at url: URL) -> Session? {
        build(url: url, lineLimit: previewLineLimit, includeEvents: false, allowLargeFile: true)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        build(url: url, lineLimit: nil, includeEvents: true, allowLargeFile: allowLargeFile)
    }

    private static func build(url: URL, lineLimit: Int?, includeEvents: Bool, allowLargeFile: Bool) -> Session? {
        guard let id = GrokSessionDiscovery.sessionID(forTranscript: url) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }

        let sidecar = readSidecar(for: url)
        let startTime = sidecar?.createdAt.flatMap(parseDate)
        let endTime = sidecar?.updatedAt.flatMap(parseDate) ?? sidecar?.lastActiveAt.flatMap(parseDate)

        guard let lines = loadLines(url, lineLimit: lineLimit) else { return nil }

        var events: [SessionEvent] = []
        var nonMetaCount = 0
        var commandCount = 0
        var firstPromptText: String?
        var assistantModel: String?

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            if assistantModel == nil, let m = object["model_id"] as? String, !m.isEmpty {
                assistantModel = m
            }
            if firstPromptText == nil, type == "user", isGenuinePrompt(object) {
                firstPromptText = textContent(from: object["content"])
            }

            let built = makeEvents(type: type, object: object, time: startTime, line: line, index: index)
            nonMetaCount += built.filter { $0.kind != .meta }.count
            commandCount += built.filter { $0.kind == .tool_call }.count
            if includeEvents { events.append(contentsOf: built) }
        }

        let cwd = sidecar?.info?.cwd ?? sidecar?.gitRootDir
        let title = firstNonEmpty(sidecar?.generatedTitle, sidecar?.sessionSummary, firstPromptText)

        // A subagent run is written twice: as its own top-level session directory and
        // as `<parent>/subagents/<id>/meta.json`. Only the latter records the parent,
        // so resolve it from the sibling tree — the sidecar never carries it.
        let bucket = url.deletingLastPathComponent().deletingLastPathComponent()
        let subagent = GrokSessionDiscovery.subagentLink(forSessionID: id, inBucket: bucket)

        // `loadLines` stops at `previewLineLimit`, so a preview that came back
        // short read the whole transcript and its own non-meta count is exact.
        // Only a genuinely truncated preview falls back to the sidecar, whose
        // `num_chat_messages` counts raw records — including `system` and
        // `reasoning`, both of which render as meta — and so overstates the
        // message count. Using it unconditionally let a transcript of nothing
        // but meta records report a nonzero count and slip past the hide-zero
        // and hide-low list filters.
        let previewTruncated = lineLimit.map { lines.count >= $0 } ?? false
        let eventCount = previewTruncated ? (sidecar?.numChatMessages ?? nonMetaCount) : nonMetaCount

        return Session(id: id,
                       source: .grok,
                       startTime: startTime,
                       endTime: endTime,
                       model: sidecar?.currentModelId ?? assistantModel,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: eventCount,
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       // nil, not 0: the preview stops at `previewLineLimit`, so
                       // a zero means "none in the first N lines", not "none".
                       // A stored 0 short-circuits SearchCoordinator.shouldDeepScan
                       // ahead of its event count. Matches Kimi and OpenCode.
                       lightweightCommands: commandCount > 0 ? commandCount : nil,
                       parentSessionID: sidecar?.parentSessionId ?? subagent?.parentSessionID,
                       subagentType: subagent?.subagentType,
                       surface: .cli,
                       reasoningEffort: sidecar?.reasoningEffort)
    }

    /// A genuine user turn carries `prompt_index`. Records with
    /// `synthetic_reason` are injected by the CLI (interrupt notices, context
    /// re-priming) and must not become the session title.
    private static func isGenuinePrompt(_ object: [String: Any]) -> Bool {
        if object["synthetic_reason"] != nil { return false }
        return object["prompt_index"] != nil
    }

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
        let path = GrokSessionDiscovery.summaryFile(forTranscript: url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    // MARK: - Event id ↔ transcript line

    /// Builds a Grok event id as `"<lineIndex>-<suffix>"`, where `lineIndex` is the
    /// 0-based index of the transcript line the record came from and `suffix`
    /// separates the several events one record can produce (`u`, `a`, `t0`…, `r`,
    /// `b`, `s`, `m`, `think`).
    ///
    /// The line number is load-bearing outside this parser. `SessionInlineImageMapper`
    /// gets a *physical line index* from the base64 scanner and otherwise has no way
    /// back to a parsed event, because a Grok record is not one event: an assistant
    /// reply carrying both `content` text and `tool_calls` emits an `.assistant`
    /// event plus one `.tool_call` per call, and an unparseable record emits none.
    /// Event positions therefore drift away from line numbers as a session goes on,
    /// and comparing the two directly pins an inline image to an *earlier* user turn
    /// than the one it belongs to. Reading the line back off the id is the only way
    /// to reconcile the two coordinate spaces.
    ///
    /// Construction and decoding sit together on purpose so that changing the format
    /// is one edit rather than two, and `InlineSessionImageMappingTests` pins the
    /// literal shape so a rename fails a test instead of silently misplacing images.
    ///
    /// One caveat the format cannot express: `loadLines` drops empty lines, so this
    /// counts non-empty lines while the scanner counts newline bytes. The Grok CLI
    /// writes exactly one JSON object per line and never a blank, so the two agree;
    /// the OpenClaw branch of the same mapper already relies on that same equivalence
    /// (`JSONLReader` skips empty lines too).
    static func eventID(lineIndex: Int, suffix: String) -> String {
        "\(lineIndex)-\(suffix)"
    }

    /// Recovers the 0-based transcript line an event was parsed from, or nil for an
    /// id that does not carry one — callers fall back rather than guess.
    static func sourceLineIndex(forEventID eventID: String) -> Int? {
        guard let separator = eventID.firstIndex(of: "-") else { return nil }
        return Int(eventID[eventID.startIndex..<separator])
    }

    private static func makeEvents(type: String,
                                   object: [String: Any],
                                   time: Date?,
                                   line: String,
                                   index: Int) -> [SessionEvent] {
        switch type {
        case "user":
            let text = textContent(from: object["content"])
            return [SessionEvent(id: eventID(lineIndex: index, suffix: "u"), timestamp: time, kind: .user, role: "user", text: text,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: nil, parentID: nil, isDelta: false, rawJSON: line)]

        case "assistant":
            var out: [SessionEvent] = []
            if let text = object["content"] as? String, !text.isEmpty {
                out.append(SessionEvent(id: eventID(lineIndex: index, suffix: "a"), timestamp: time, kind: .assistant, role: "assistant", text: text,
                                        toolName: nil, toolInput: nil, toolOutput: nil,
                                        messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
            }
            let calls = object["tool_calls"] as? [[String: Any]] ?? []
            for (callIndex, call) in calls.enumerated() {
                out.append(SessionEvent(id: eventID(lineIndex: index, suffix: "t\(callIndex)"), timestamp: time, kind: .tool_call, role: "assistant", text: nil,
                                        toolName: call["name"] as? String,
                                        // `arguments` is already a JSON string on the wire.
                                        toolInput: call["arguments"] as? String,
                                        toolOutput: nil,
                                        messageID: call["id"] as? String, parentID: nil, isDelta: false, rawJSON: line))
            }
            if out.isEmpty { out.append(meta(index: index, suffix: "m", role: "assistant", text: nil, time: time, line: line)) }
            return out

        case "tool_result":
            return [SessionEvent(id: eventID(lineIndex: index, suffix: "r"), timestamp: time, kind: .tool_result, role: "tool", text: nil,
                                 toolName: nil, toolInput: nil,
                                 toolOutput: object["content"] as? String,
                                 messageID: object["tool_call_id"] as? String,
                                 parentID: nil, isDelta: false, rawJSON: line)]

        case "reasoning":
            // Readable rationale is the summary text; `encrypted_content` is an
            // opaque server blob. Rendered as meta with a `thinking` role, the
            // same shape Pi uses for its thinking blocks.
            guard let text = summaryText(from: object["summary"]), !text.isEmpty else {
                return [meta(index: index, suffix: "m", role: "thinking", text: nil, time: time, line: line)]
            }
            return [meta(index: index, suffix: "think", role: "thinking", text: "[thinking] \(text)", time: time, line: line)]

        case "backend_tool_call":
            // Server-side tool (web search). The descriptor is the payload; no
            // separate tool_result record accompanies it.
            let kind = object["kind"] as? [String: Any]
            return [SessionEvent(id: eventID(lineIndex: index, suffix: "b"), timestamp: time, kind: .tool_call, role: "assistant", text: nil,
                                 toolName: kind?["tool_type"] as? String ?? "backend_tool",
                                 toolInput: jsonString(kind?["action"]),
                                 toolOutput: nil,
                                 messageID: nil, parentID: nil, isDelta: false, rawJSON: line)]

        case "system":
            return [meta(index: index, suffix: "s", role: "system", text: object["content"] as? String, time: time, line: line)]

        default:
            return [meta(index: index, suffix: "m", role: type, text: nil, time: time, line: line)]
        }
    }

    private static func meta(index: Int, suffix: String, role: String?, text: String?, time: Date?, line: String) -> SessionEvent {
        SessionEvent(id: eventID(lineIndex: index, suffix: suffix), timestamp: time, kind: .meta, role: role, text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: line)
    }

    /// User `content` is an array of parts; assistant `content` is a bare string.
    private static func textContent(from content: Any?) -> String? {
        if let string = content as? String { return string.isEmpty ? nil : string }
        guard let parts = content as? [[String: Any]] else { return nil }
        let chunks: [String] = parts.compactMap { part in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "image": return "[image]"
            default: return nil
            }
        }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func summaryText(from value: Any?) -> String? {
        guard let parts = value as? [[String: Any]] else { return nil }
        let chunks = parts.compactMap { $0["text"] as? String }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

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

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    /// Sidecar timestamps are RFC 3339 with six fractional digits
    /// ("2026-07-31T10:13:27.574131Z"); the no-fraction formatter is the
    /// fallback for any field that omits them.
    private static func parseDate(_ value: String) -> Date? {
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
}
