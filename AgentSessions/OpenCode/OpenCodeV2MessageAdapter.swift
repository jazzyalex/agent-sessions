import Foundation

/// Maps one OpenCode 2.0 `session_message` row onto the v1 message/part shape
/// that `OpenCodeSessionParser.buildPartEvents` and the telemetry scan already
/// understand.
///
/// OpenCode 2.0 stores a session as an ordered stream of typed rows
/// (`user`, `assistant`, `shell`, `system`, `compaction`, `idle`, ...) in
/// `session_message`, keyed by `seq`. An assistant row is one model step: its
/// `content` array holds text, reasoning, and tool items, and its `tokens`
/// object has the same components as a v1 `step-finish` part. Translating at
/// this boundary keeps one event builder and one usage reducer for both
/// schemas. Source: anomalyco/opencode v2.0.32 packages/schema/src/session-message.ts.
enum OpenCodeV2MessageAdapter {
    struct Adapted {
        /// v1-shaped message object (role, model fields, time, tokens).
        let message: [String: Any]
        /// v1-shaped parts. Unknown row types become one part with that type so
        /// the event builder records them as meta events.
        let parts: [(id: String, dict: [String: Any])]
    }

    /// Row types that count as conversation messages in the session list.
    static let conversationTypes: Set<String> = ["user", "assistant", "shell"]

    /// An assistant row for a request the provider refused before generating:
    /// `finish: "error"`, an `error` that is a rate or quota refusal
    /// (`provider.free-limit`, or HTTP status 429), no `tokens` and no content.
    /// A refused request is not billed, so it used none, as a completed
    /// compaction without tokens does. Any other error, or a row with partial
    /// content, may have been billed; its usage stays unknown.
    static func isFailedRequestWithoutUsage(_ data: [String: Any]) -> Bool {
        guard let error = data["error"] as? [String: Any],
              data["tokens"] == nil,
              data["finish"] as? String == "error",
              (data["content"] as? [Any])?.isEmpty == true else { return false }
        if error["type"] as? String == "provider.free-limit" { return true }
        guard let status = error["status"] as? NSNumber,
              CFGetTypeID(status) != CFBooleanGetTypeID() else { return false }
        return status.intValue == 429 && status.doubleValue == 429
    }

    /// Key set on the adapted message of a refused request, so the usage reducer
    /// can tell a session of only refusals from one with missing accounting.
    static let refusedWithoutUsageKey = "refusedWithoutUsage"

    static func adapt(rowID: String, type: String, timeCreatedMillis: Int64,
                      timeUpdatedMillis: Int64 = 0, data: [String: Any]) -> Adapted {
        let time = data["time"] as? [String: Any] ?? [:]
        let created: Any? = time["created"] ?? (timeCreatedMillis > 0 ? NSNumber(value: timeCreatedMillis) : nil)

        switch type {
        case "user":
            var message: [String: Any] = ["role": "user"]
            if let created { message["time"] = ["created": created] }
            let files = (data["files"] as? [[String: Any]]) ?? []
            var parts: [(id: String, dict: [String: Any])] = []
            if let visible = visibleUserText(data) {
                parts.append((rowID + "-text", ["type": "text", "text": visible]))
            }
            for (index, file) in files.enumerated() {
                var part: [String: Any] = ["type": "file"]
                if let mime = file["mime"] as? String { part["mime"] = mime }
                if let name = file["name"] as? String { part["filename"] = name }
                if let mime = file["mime"] as? String, let payload = file["data"] as? String {
                    part["url"] = "data:\(mime);base64,\(payload)"
                }
                parts.append((rowID + "-file-\(index)", part))
            }
            return Adapted(message: message, parts: parts)

        case "assistant":
            var message: [String: Any] = ["role": "assistant"]
            if let agent = data["agent"] as? String { message["agent"] = agent }
            if let model = data["model"] as? [String: Any] {
                if let id = model["id"] as? String { message["modelID"] = id }
                if let provider = model["providerID"] as? String { message["providerID"] = provider }
                if let variant = model["variant"] as? String { message["variant"] = variant }
            }
            if !time.isEmpty { message["time"] = time }
            for key in ["cost", "tokens", "error", "finish"] {
                if let value = data[key] { message[key] = value }
            }

            var parts: [(id: String, dict: [String: Any])] = []
            for (index, item) in ((data["content"] as? [[String: Any]]) ?? []).enumerated() {
                let partID = rowID + "-c\(index)"
                switch item["type"] as? String {
                case "tool":
                    parts.append((partID, toolPart(item)))
                default:
                    // text and reasoning already use the v1 part shape.
                    parts.append((partID, item))
                }
            }
            // One assistant row is one model request, which is exactly what a
            // v1 step-finish part records. Every assistant row gets one, even
            // when `tokens` is absent or malformed: the usage reducer then sees
            // an incomplete step-finish and reports the session total as
            // unavailable instead of publishing a partial sum as complete.
            // The one exception is a request the provider refused outright.
            if isFailedRequestWithoutUsage(data) {
                message[refusedWithoutUsageKey] = true
            } else {
                parts.append((rowID + "-step-finish", stepFinishPart(data: data, reason: data["finish"],
                                                                     timeUpdatedMillis: timeUpdatedMillis)))
            }
            return Adapted(message: message, parts: parts)

        case "shell":
            // A user-run shell command. Render it as a tool call so the command
            // and its output appear in the transcript.
            var message: [String: Any] = ["role": "assistant"]
            if let created { message["time"] = ["created": created] }
            var state: [String: Any] = [
                "status": data["status"] ?? "completed",
                "input": ["command": data["command"] ?? ""],
            ]
            // Shell output is a page object {output, cursor, size, truncated}
            // (packages/schema/src/shell.ts); show its text, not the wrapper.
            if let page = data["output"] as? [String: Any] {
                if let text = page["output"] as? String { state["output"] = text }
            } else if let text = data["output"] as? String {
                state["output"] = text
            }
            if let exit = data["exit"] { state["metadata"] = ["exit": exit] }
            var stateTime: [String: Any] = [:]
            if let created { stateTime["start"] = created }
            if let completed = time["completed"] { stateTime["end"] = completed }
            if !stateTime.isEmpty { state["time"] = stateTime }
            let part: [String: Any] = [
                "type": "tool",
                "tool": "shell",
                "callID": data["shellID"] ?? rowID,
                "state": state,
            ]
            return Adapted(message: message, parts: [(rowID + "-shell", part)])

        default:
            // system, synthetic, skill, compaction, idle, agent-switched,
            // model-switched, location-switched, and future types: keep the
            // row as a meta event only.
            var message: [String: Any] = ["role": "system"]
            if let created { message["time"] = ["created": created] }
            var part = data
            part["type"] = type
            var parts: [(id: String, dict: [String: Any])] = [(rowID + "-meta", part)]
            // A compaction request is billed like any model step. Its usage is
            // optional in the schema (running compactions and some completed
            // ones carry none), so only a present `tokens` value counts; a
            // malformed one still fails the session total closed.
            if type == "compaction", data["tokens"] != nil {
                parts.append((rowID + "-step-finish", stepFinishPart(data: data, reason: "compaction",
                                                                     timeUpdatedMillis: timeUpdatedMillis)))
            }
            return Adapted(message: message, parts: parts)
        }
    }

    /// The text a v2 user row shows in the transcript and session titles: its
    /// prompt plus an "[Attached: ...]" line naming any files, so a prompt that
    /// is only an image or file is not an empty turn. nil when both are empty.
    static func visibleUserText(_ data: [String: Any]) -> String? {
        var lines: [String] = []
        if let text = data["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(text)
        }
        if let attachments = attachmentLine((data["files"] as? [[String: Any]]) ?? []) {
            lines.append(attachments)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// v1-shaped step-finish part. `tokens` is copied as stored, whatever its
    /// shape, so the reducer's strict token validation decides completeness.
    /// `completedAt` is the raw completion value, also as stored: the row's own
    /// `time.completed`, else the row's update time when the row carries usage
    /// (an errored request or a completed compaction records no completion time).
    private static func stepFinishPart(data: [String: Any], reason: Any?,
                                       timeUpdatedMillis: Int64) -> [String: Any] {
        var part: [String: Any] = ["type": "step-finish"]
        if let tokens = data["tokens"] { part["tokens"] = tokens }
        let time = data["time"] as? [String: Any] ?? [:]
        if let completed = time["completed"] {
            part["completedAt"] = completed
        } else if data["tokens"] != nil, timeUpdatedMillis > 0 {
            part["completedAt"] = NSNumber(value: timeUpdatedMillis)
        }
        if let reason { part["reason"] = reason }
        if let cost = data["cost"] { part["cost"] = cost }
        if let model = data["model"] as? [String: Any] {
            if let id = model["id"] { part["modelID"] = id }
            if let variant = model["variant"] { part["variant"] = variant }
        }
        return part
    }

    /// "[Attached: shot.png, notes.pdf]" for a v2 user row's files, or nil.
    private static func attachmentLine(_ files: [[String: Any]]) -> String? {
        guard !files.isEmpty else { return nil }
        let names = files.map { file in
            (file["name"] as? String).map { ($0 as NSString).lastPathComponent }
                ?? (file["mime"] as? String)
                ?? "file"
        }
        return "[Attached: \(names.joined(separator: ", "))]"
    }

    /// v2 tool item → v1 tool part (`callID`, `tool`, `state.output`, `state.time.start/end`).
    private static func toolPart(_ item: [String: Any]) -> [String: Any] {
        let v2State = item["state"] as? [String: Any] ?? [:]
        var state: [String: Any] = [:]
        if let status = v2State["status"] { state["status"] = status }
        if let input = v2State["input"] { state["input"] = input }
        if let metadata = v2State["metadata"] { state["metadata"] = metadata }
        if let output = contentText(v2State["content"]) { state["output"] = output }
        if let error = v2State["error"] as? [String: Any] {
            state["error"] = (error["message"] as? String) ?? OpenCodeSessionParser.stringifyJSON(error)
        }
        let time = item["time"] as? [String: Any] ?? [:]
        var stateTime: [String: Any] = [:]
        if let start = time["ran"] ?? time["created"] { stateTime["start"] = start }
        if let end = time["completed"] { stateTime["end"] = end }
        if !stateTime.isEmpty { state["time"] = stateTime }

        var part: [String: Any] = ["type": "tool", "state": state]
        if let id = item["id"] { part["callID"] = id }
        if let name = item["name"] { part["tool"] = name }
        return part
    }

    /// Joins the text items of a v2 tool `content` array. File items are noted
    /// by name so a result that is only an attachment is not shown as empty.
    private static func contentText(_ value: Any?) -> String? {
        guard let items = value as? [[String: Any]], !items.isEmpty else { return nil }
        let pieces = items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "text":
                return item["text"] as? String
            case "file":
                let name = (item["name"] as? String) ?? (item["mime"] as? String) ?? "file"
                return "[file: \(name)]"
            default:
                return nil
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }
}
