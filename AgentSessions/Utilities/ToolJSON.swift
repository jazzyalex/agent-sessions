import Foundation

/// Display serialization for tool input/output JSON.
/// Never use for rawJSON, archive, pricing or telemetry encoders.
enum ToolJSON {
    /// Serializes a JSON object without escaping slashes. Keys are always sorted.
    static func string(from object: Any, pretty: Bool) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Joins a Codex content-item array (`input_text` / `output_text` / `text` / image items)
    /// into plain text. Text parts join with no separator; each image becomes its own `[image]` line.
    /// Returns nil for any other shape.
    static func joinedContentItemText(_ value: Any) -> String? {
        guard let items = value as? [Any], !items.isEmpty else { return nil }
        var out = ""
        for raw in items {
            guard let item = raw as? [String: Any], let type = item["type"] as? String else { return nil }
            switch type {
            case "text", "input_text", "output_text":
                guard let text = item["text"] as? String else { return nil }
                out += text
            case "input_image", "image":
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                out += "[image]\n"
            default:
                return nil
            }
        }
        return out
    }
}
