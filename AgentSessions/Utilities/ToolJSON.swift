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
}
