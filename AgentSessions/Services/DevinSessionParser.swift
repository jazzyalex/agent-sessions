import Foundation

/// Turns a Devin `message_nodes.chat_message` payload into `SessionEvent`s.
///
/// Shapes verified with `scripts/devin_sessions_schema_probe.py` against 253
/// real sessions at CLI 3000.3.27 (`0becb483`). Unlike Grok, `content` is
/// always a plain string; the structure lives in sibling keys instead:
///
/// - `system` — `{message_id, role, content, metadata}`
/// - `user` — same, plus an optional `images` array and
///   `metadata.is_user_input`
/// - `assistant` — plus `tool_calls` and `thinking`. `tool_calls[]` entries are
///   `{id, index, kind, name, arguments}` where **`arguments` is a JSON object**,
///   not the JSON *string* Grok and Kimi use. `thinking` is
///   `{signature, thinking}`; only the latter is renderable.
/// - `tool` — plus `tool_call_id` keying it back to the call, and an optional
///   `images` array of `{width, height, base64_data}`.
enum DevinSessionParser {
    /// Builds the events for one node. A single assistant node can yield an
    /// assistant reply, a thinking block, and several tool calls.
    static func events(fromChatMessage json: String, nodeID: Int64, time: Date?) -> [SessionEvent] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [meta(nodeID: nodeID, suffix: "raw", role: nil, text: nil, time: time, raw: json)]
        }

        let role = object["role"] as? String ?? "?"
        let content = object["content"] as? String
        let messageID = object["message_id"] as? String

        switch role {
        case "user":
            var text = content
            if let images = object["images"] as? [[String: Any]], !images.isEmpty {
                // Images are inline base64; the transcript shows a marker, not
                // the payload, so a 1.5 MB screenshot never reaches the body.
                let markers = Array(repeating: "[image]", count: images.count).joined(separator: "\n")
                text = [markers, content].compactMap { $0 }.joined(separator: "\n")
            }
            return [SessionEvent(id: "\(nodeID)-u", timestamp: time, kind: .user, role: role, text: text,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: messageID, parentID: nil, isDelta: false, rawJSON: json)]

        case "assistant":
            var out: [SessionEvent] = []
            if let thinking = (object["thinking"] as? [String: Any])?["thinking"] as? String,
               !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(meta(nodeID: nodeID, suffix: "think", role: "thinking",
                                text: "[thinking] \(thinking)", time: time, raw: json))
            }
            if let content, !content.isEmpty {
                out.append(SessionEvent(id: "\(nodeID)-a", timestamp: time, kind: .assistant, role: role, text: content,
                                        toolName: nil, toolInput: nil, toolOutput: nil,
                                        messageID: messageID, parentID: nil, isDelta: false, rawJSON: json))
            }
            for (index, call) in (object["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                out.append(SessionEvent(id: "\(nodeID)-t\(index)", timestamp: time, kind: .tool_call, role: role, text: nil,
                                        toolName: call["name"] as? String,
                                        toolInput: jsonString(call["arguments"]),
                                        toolOutput: nil,
                                        messageID: call["id"] as? String,
                                        parentID: messageID, isDelta: false, rawJSON: json))
            }
            if out.isEmpty {
                out.append(meta(nodeID: nodeID, suffix: "a", role: role, text: nil, time: time, raw: json))
            }
            return out

        case "tool":
            var output = content
            if let images = object["images"] as? [[String: Any]], !images.isEmpty {
                // Same marker rule as the user arm: the payload never reaches
                // the transcript body.
                let markers = Array(repeating: "[image]", count: images.count).joined(separator: "\n")
                output = [markers, content].compactMap { $0 }.joined(separator: "\n")
            }
            return [SessionEvent(id: "\(nodeID)-r", timestamp: time, kind: .tool_result, role: role, text: nil,
                                 toolName: nil, toolInput: nil, toolOutput: output,
                                 messageID: object["tool_call_id"] as? String,
                                 parentID: nil, isDelta: false, rawJSON: json)]

        case "system":
            return [meta(nodeID: nodeID, suffix: "s", role: role, text: content, time: time, raw: json)]

        default:
            return [meta(nodeID: nodeID, suffix: "m", role: role, text: content, time: time, raw: json)]
        }
    }

    private static func meta(nodeID: Int64, suffix: String, role: String?, text: String?, time: Date?, raw: String) -> SessionEvent {
        SessionEvent(id: "\(nodeID)-\(suffix)", timestamp: time, kind: .meta, role: role, text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
    }

    /// `tool_calls[].arguments` arrives as a JSON object. Serialised with sorted
    /// keys so the rendered form is stable between runs.
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
}
