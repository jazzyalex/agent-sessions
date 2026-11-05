import Foundation

public enum SessionEventKind: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case tool_call
    case tool_result
    case error
    case meta
}

public struct SessionEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date?
    public let kind: SessionEventKind
    public let role: String?
    public let text: String?
    public let toolName: String?
    public let toolInput: String?
    public let toolOutput: String?
    /// Codex tool namespace (e.g. `mcp__node_repl__`); nil for other agents.
    public var toolNamespace: String? = nil
    /// Provider call id linking a tool call to its output (Codex `call_id`); nil when unknown.
    public var toolCallID: String? = nil
    // Internal (not `public`): the payload types are module-internal.
    /// Structured tool output, set only when the original output is an array/object of at most 256 KB minified.
    var toolOutputValue: ToolPayloadValue? = nil
    /// Structured facts recorded next to the result text (stdout/stderr split, exit code, agent label).
    var toolSidecar: ToolSidecar? = nil
    /// Set when the parser classified the result as a runtime error or a user rejection.
    var toolDisposition: ToolDisposition? = nil
    // Delta/stream grouping
    public let messageID: String?
    public let parentID: String?
    public let isDelta: Bool
    public let rawJSON: String
}

extension SessionEventKind {
    static func from(role: String?, type: String?) -> SessionEventKind {
        if let t = type?.lowercased() {
            switch t {
            case "tool_call", "tool-call", "toolcall", "tool_use", "tool-use", "function_call", "web_search_call", "custom_tool_call": return .tool_call
            case "tool_result", "tool-result", "toolresult", "function_result", "function_call_output", "web_search_call_output", "custom_tool_call_output": return .tool_result
            case "error", "err": return .error
            case "meta",
                 "system",
                 "summary",
                 "file-history-snapshot",
                 "queue-operation",
                 "api-request",
                 "api-request-blob",
                 "api-request-shape",
                 "assistant.turn_start",
                 "assistant.turn_end",
                 "session.truncation",
                 "tool.execution_start",
                 "environment_context",
                 "environment-context",
                 "env_context",
                 "thread_rolled_back":
                return .meta
            default: break
            }
        }
        if let r = role?.lowercased() {
            switch r {
            case "user": return .user
            case "assistant": return .assistant
            case "tool": return .tool_result
            case "system": return .meta
            default: break
            }
        }
        return .meta
    }
}
