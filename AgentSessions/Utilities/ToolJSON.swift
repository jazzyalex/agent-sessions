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
        contentItemParts(value).map(joinedText)
    }

    /// One content item: its text, or an image (a data marker, not localized).
    enum ContentItemPart: Equatable, Sendable {
        case text(String)
        case image
    }

    /// Classifies a Codex content-item array. Returns nil for any other shape.
    static func contentItemParts(_ value: Any) -> [ContentItemPart]? {
        guard let items = value as? [Any], !items.isEmpty else { return nil }
        var parts: [ContentItemPart] = []
        for raw in items {
            guard let item = raw as? [String: Any],
                  let part = contentItemPart(type: item["type"] as? String, text: item["text"] as? String)
            else { return nil }
            parts.append(part)
        }
        return parts
    }

    /// Same classification for a typed payload value.
    static func contentItemParts(_ value: ToolPayloadValue) -> [ContentItemPart]? {
        guard case .array(let items) = value, !items.isEmpty else { return nil }
        var parts: [ContentItemPart] = []
        for raw in items {
            guard case .object(let item) = raw,
                  let part = contentItemPart(type: item["type"]?.stringValue, text: item["text"]?.stringValue)
            else { return nil }
            parts.append(part)
        }
        return parts
    }

    /// The one join rule: text parts join with no separator; each image is its own `[image]` line.
    static func joinedText(_ parts: [ContentItemPart]) -> String {
        var out = ""
        for part in parts {
            switch part {
            case .text(let text):
                out += text
            case .image:
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                out += "[image]\n"
            }
        }
        return out
    }

    private static func contentItemPart(type: String?, text: String?) -> ContentItemPart? {
        switch type {
        case "text", "input_text", "output_text":
            guard let text else { return nil }
            return .text(text)
        case "input_image", "image":
            return .image
        default:
            return nil
        }
    }
}
