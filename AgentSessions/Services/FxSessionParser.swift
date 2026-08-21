import Foundation

/// Parses fx (vercel-labs) session directories into `Session` values.
///
/// A session directory holds `session.json` (metadata sidecar),
/// `display.json` (title/preview), and `checkpoint.json` (the materialized
/// conversation). The sidecars are authoritative for identity, workspace,
/// title, model and both timestamps; history entries carry no per-entry time,
/// so text events inherit nil and only tool results carry their own
/// `created_at_ms`.
///
/// Shapes verified against the on-disk sessions at fx 0.0.4:
///
/// - `checkpoint.json` — `{schema_version, session_id, log_generation,
///   through_seq, state}`. `state.history[]` is the transcript; the sibling
///   `events.jsonl` is write-ahead infrastructure and is never read.
/// - `state.history[]` entries are whole turns keyed by `kind`:
///   `assistant` carries `{user: {text, images}, assistant, execution}`;
///   `interrupted` carries `{user, assistant (often null), tool_call,
///   completed_tool_names, terminal_reason}`. The user prompt lives *inside*
///   the turn — fx has no standalone user records.
/// - `execution.tool_steps[]` — each `{assistant, tool_calls, tool_results}`;
///   a turn renders user → per-step narration + calls + results → final reply.
/// - `tool_calls[]` — `{id, name, arguments_json}` where **`arguments_json`
///   is a JSON string** on the wire (Grok/Kimi's shape, not Devin's object).
/// - `tool_results[]` — `{tool_call_id, tool_name, status, output, preview,
///   truncated, created_at_ms, …}`, keyed back to its call by id.
/// - `user.images` — an array of image payloads; rendered as `[image]`
///   markers so the payload never reaches the transcript body.
enum FxSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024

    /// Reads `session.json` field by field out of a plain dictionary.
    /// Deliberately NOT `Decodable`, for the same reason Grok's sidecar reader
    /// is not: one unexpected field type must cost one field, not the session.
    private struct Sidecar {
        let schemaVersion: Int?
        let id: String?
        let createdAtMS: Int64?
        let updatedAtMS: Int64?
        let workspaceRoot: String?
        let model: String?
        let effort: String?
        let historyLen: Int?

        init(object: [String: Any]) {
            schemaVersion = FxSessionParser.int(object["schema_version"])
            id = object["id"] as? String
            createdAtMS = FxSessionParser.int64(object["created_at_ms"])
            updatedAtMS = FxSessionParser.int64(object["updated_at_ms"])
            workspaceRoot = object["workspace_root"] as? String
            if let preferences = object["preferences"] as? [String: Any] {
                model = preferences["model"] as? String
                effort = preferences["effort"] as? String
            } else {
                model = nil
                effort = nil
            }
            historyLen = FxSessionParser.int(object["history_len"])
        }
    }

    // MARK: - Entry points

    /// Lightweight list pass: sidecars only, never the checkpoint. `eventCount`
    /// is fx's own `history_len` — whole turns, not rendered events — which is
    /// exact enough for the zero/low-message visibility filters; the full parse
    /// replaces it with the real non-meta count.
    static func parseFile(at url: URL) -> Session? {
        build(url: url, includeEvents: false)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }
        return build(url: url, includeEvents: true)
    }

    private static func build(url: URL, includeEvents: Bool) -> Session? {
        guard let id = FxSessionDiscovery.sessionID(forCheckpoint: url) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sidecar = readSidecar(for: url)
        let startTime = sidecar?.createdAtMS.flatMap(msDate)
        let endTime = sidecar?.updatedAtMS.flatMap(msDate)

        var events: [SessionEvent] = []
        var nonMetaCount = 0
        var commandCount = 0
        var firstPromptText: String?

        if includeEvents, let checkpoint = readCheckpoint(for: url) {
            let state = checkpoint["state"] as? [String: Any]
            let history = state?["history"] as? [[String: Any]] ?? []
            for (turnIndex, turn) in history.enumerated() {
                let built = Self.events(forTurn: turn, turnIndex: turnIndex)
                nonMetaCount += built.filter { $0.kind != .meta }.count
                commandCount += built.filter { $0.kind == .tool_call }.count
                if firstPromptText == nil, let prompt = promptText(fromTurn: turn), !prompt.isEmpty {
                    firstPromptText = prompt
                }
                events.append(contentsOf: built)
            }
        }

        let cwd = sidecar?.workspaceRoot
        let displayTitle = readDisplayTitle(for: url)
        let title = firstNonEmpty(displayTitle, firstPromptText)

        return Session(id: id,
                       source: .fx,
                       startTime: startTime,
                       endTime: endTime,
                       model: sidecar?.model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: includeEvents ? nonMetaCount : max(sidecar?.historyLen ?? 0, 0),
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       lightweightCommands: commandCount > 0 ? commandCount : nil,
                       parentSessionID: nil,
                       subagentType: nil,
                       surface: .cli,
                       reasoningEffort: sidecar?.effort)
    }

    // MARK: - Turn rendering

    /// One history entry becomes one user event plus whatever the response
    /// produced. Event ids are `"<turnIndex>-<suffix>"`; the turn index is the
    /// coordinate other tools can use to locate a record inside the checkpoint.
    /// Internal so tests can exercise a single turn without a file on disk.
    static func events(forTurn turn: [String: Any], turnIndex: Int) -> [SessionEvent] {
        let kind = turn["kind"] as? String ?? "unknown"
        var out: [SessionEvent] = []

        if let user = turn["user"] as? [String: Any] {
            out.append(contentsOf: userEvents(from: user, turnIndex: turnIndex))
        }

        switch kind {
        case "assistant":
            if let execution = turn["execution"] as? [String: Any] {
                let steps = execution["tool_steps"] as? [[String: Any]] ?? []
                for (stepIndex, step) in steps.enumerated() {
                    out.append(contentsOf: toolStepEvents(from: step, turnIndex: turnIndex, stepIndex: stepIndex))
                }
            }
            if let reply = turn["assistant"] as? String, !reply.isEmpty {
                out.append(event(turnIndex: turnIndex, suffix: "a", kind: .assistant, role: "assistant", text: reply,
                                 messageID: nil, raw: jsonEncode(turn)))
            }

        case "interrupted":
            // A cancelled turn: the dangling call never got a result, and the
            // terminal reason is the only record of why the turn ends here.
            if let call = turn["tool_call"] as? [String: Any] {
                out.append(toolCallEvent(from: call, turnIndex: turnIndex, suffix: "t"))
            }
            let reason = turn["terminal_reason"] as? String ?? "interrupted"
            out.append(event(turnIndex: turnIndex, suffix: "i", kind: .meta, role: "system",
                             text: "[interrupted: \(reason)]", messageID: nil, raw: jsonEncode(turn)))

        default:
            out.append(event(turnIndex: turnIndex, suffix: "m", kind: .meta, role: kind,
                             text: nil, messageID: nil, raw: jsonEncode(turn)))
        }

        if out.isEmpty {
            out.append(event(turnIndex: turnIndex, suffix: "e", kind: .meta, role: kind,
                             text: nil, messageID: nil, raw: jsonEncode(turn)))
        }
        return out
    }

    private static func userEvents(from user: [String: Any], turnIndex: Int) -> [SessionEvent] {
        let text = user["text"] as? String
        let images = user["images"] as? [[String: Any]] ?? []
        var rendered = text
        if !images.isEmpty {
            let markers = Array(repeating: "[image]", count: images.count).joined(separator: "\n")
            rendered = [markers, text].compactMap { $0 }.joined(separator: "\n")
        }
        guard let rendered, !rendered.isEmpty else { return [] }
        return [event(turnIndex: turnIndex, suffix: "u", kind: .user, role: "user", text: rendered,
                      messageID: nil, raw: jsonEncode(user))]
    }

    private static func toolStepEvents(from step: [String: Any], turnIndex: Int, stepIndex: Int) -> [SessionEvent] {
        var out: [SessionEvent] = []
        if let narration = step["assistant"] as? String, !narration.isEmpty {
            out.append(event(turnIndex: turnIndex, suffix: "s\(stepIndex)a", kind: .assistant, role: "assistant", text: narration,
                             messageID: nil, raw: jsonEncode(step)))
        }
        let calls = step["tool_calls"] as? [[String: Any]] ?? []
        for (callIndex, call) in calls.enumerated() {
            out.append(toolCallEvent(from: call, turnIndex: turnIndex, suffix: "s\(stepIndex)t\(callIndex)"))
        }
        let results = step["tool_results"] as? [[String: Any]] ?? []
        for (resultIndex, result) in results.enumerated() {
            out.append(toolResultEvent(from: result, turnIndex: turnIndex, suffix: "s\(stepIndex)r\(resultIndex)"))
        }
        return out
    }

    private static func toolCallEvent(from call: [String: Any], turnIndex: Int, suffix: String) -> SessionEvent {
        event(turnIndex: turnIndex, suffix: suffix, kind: .tool_call, role: "assistant", text: nil,
              toolName: call["name"] as? String,
              // `arguments_json` is already a JSON string on the wire.
              toolInput: call["arguments_json"] as? String,
              toolOutput: nil,
              messageID: call["id"] as? String,
              raw: jsonEncode(call))
    }

    private static func toolResultEvent(from result: [String: Any], turnIndex: Int, suffix: String) -> SessionEvent {
        var output = result["output"] as? String
        if output == nil, let preview = result["preview"] as? String { output = preview }
        if let truncated = result["truncated"] as? Bool, truncated, output != nil {
            output! += "\n[truncated]"
        }
        return event(turnIndex: turnIndex, suffix: suffix, kind: .tool_result, role: "tool", text: nil,
                     toolName: result["tool_name"] as? String,
                     toolInput: nil,
                     toolOutput: output,
                     messageID: result["tool_call_id"] as? String,
                     time: (result["created_at_ms"] as? NSNumber).flatMap { msDate($0.int64Value) },
                     raw: jsonEncode(result))
    }

    /// The genuine user prompt of a turn, for title derivation. Interrupted
    /// turns still carry a real prompt, so they qualify like any other.
    private static func promptText(fromTurn turn: [String: Any]) -> String? {
        guard let user = turn["user"] as? [String: Any] else { return nil }
        return user["text"] as? String
    }

    // MARK: - Sidecars

    private static func readSidecar(for url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: FxSessionDiscovery.sidecarFile(forCheckpoint: url)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Sidecar(object: object)
    }

    private static func readCheckpoint(for url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// `display.json` holds the CLI-generated title/preview pair. It may be
    /// absent (`display_metadata_present: false` in the shared index); the
    /// first user prompt takes over then.
    private static func readDisplayTitle(for url: URL) -> String? {
        let path = url.deletingLastPathComponent().appendingPathComponent("display.json", isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Helpers

    private static func event(turnIndex: Int,
                              suffix: String,
                              kind: SessionEventKind,
                              role: String?,
                              text: String?,
                              toolName: String? = nil,
                              toolInput: String? = nil,
                              toolOutput: String? = nil,
                              messageID: String?,
                              time: Date? = nil,
                              raw: String) -> SessionEvent {
        SessionEvent(id: "\(turnIndex)-\(suffix)", timestamp: time, kind: kind, role: role, text: text,
                     toolName: toolName, toolInput: toolInput, toolOutput: toolOutput,
                     messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)
    }

    /// fx timestamps are epoch milliseconds, like OpenCode's and unlike Devin's seconds.
    private static func msDate(_ ms: Int64) -> Date? {
        ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1_000.0) : nil
    }

    private static func int(_ value: Any?) -> Int? {
        (value is Bool) ? nil : (value as? NSNumber)?.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        (value is Bool) ? nil : (value as? NSNumber)?.int64Value
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
