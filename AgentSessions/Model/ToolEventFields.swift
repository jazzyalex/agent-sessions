import Foundation

/// A JSON-like value carried by a tool call or tool result. Built from
/// `JSONSerialization` output or from a parsed JavaScript object literal.
indirect enum ToolPayloadValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([ToolPayloadValue])
    case object([String: ToolPayloadValue])

    /// Builds a value from `JSONSerialization` output. Returns nil for an unsupported type.
    init?(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let a as [Any]:
            var items: [ToolPayloadValue] = []
            items.reserveCapacity(a.count)
            for element in a {
                guard let v = ToolPayloadValue(jsonObject: element) else { return nil }
                items.append(v)
            }
            self = .array(items)
        case let d as [String: Any]:
            var map: [String: ToolPayloadValue] = [:]
            map.reserveCapacity(d.count)
            for (k, element) in d {
                guard let v = ToolPayloadValue(jsonObject: element) else { return nil }
                map[k] = v
            }
            self = .object(map)
        default:
            return nil
        }
    }

    /// The string for `.string`; nil for every other case.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    // MARK: Codable (plain JSON shape)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ToolPayloadValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: ToolPayloadValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension ToolPayloadValue {
    /// Largest minified size of a structured tool output kept as `SessionEvent.toolOutputValue` (spec §6.5).
    static let outputValueMaxBytes = 256 * 1024

    /// The `toolOutputValue` for a raw parsed output: only an array or object whose minified
    /// `ToolJSON` form is at most `outputValueMaxBytes`. Strings, scalars and larger values give nil.
    /// `sourceBytes` is the UTF-8 size of the JSON text the output was parsed from (e.g. the JSONL line),
    /// when known: a minified re-serialization of a sub-value is no longer than that text (bar float
    /// re-formatting), so a source within the budget skips the extra encode on the parse hot path.
    static func outputValue(fromRawOutput raw: Any, sourceBytes: Int? = nil) -> ToolPayloadValue? {
        guard raw is [Any] || raw is [String: Any] else { return nil }
        if let sourceBytes, sourceBytes <= outputValueMaxBytes {
            return ToolPayloadValue(jsonObject: raw)
        }
        guard let json = ToolJSON.string(from: raw, pretty: false),
              json.utf8.count <= outputValueMaxBytes else { return nil }
        return ToolPayloadValue(jsonObject: raw)
    }
}

/// Structured facts an agent records next to a tool result's text (spec §7.1 item 7).
/// P1 fields only; P2/P3 add diff, persisted-output, subagent stats and image refs.
struct ToolSidecar: Codable, Equatable, Sendable {
    var stdout: String?, stderr: String?
    var exitCode: Int?, isError: Bool?, interrupted: Bool?
    /// Agent-written label for the call: Antigravity toolSummary (decoded once), OpenCode state.title,
    /// Copilot toolTitle, Kimi display summary.
    var agentLabel: String?
}

/// How a tool result ended when the parser classified it as other than a normal output.
enum ToolDisposition: String, Codable, Sendable { case runtimeError, rejected }
