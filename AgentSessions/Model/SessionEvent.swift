import Foundation

public enum SessionEventKind: String, Codable, CaseIterable {
    case user
    case assistant
    case tool_call
    case tool_result
    case error
    case meta
}

public struct SessionEvent: Identifiable, Codable, Equatable {
    public let id: String
    public let timestamp: Date?
    public let kind: SessionEventKind
    public let role: String?
    public let text: String?
    public let toolName: String?
    public let toolInput: String?
    public let toolOutput: String?
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
            case "tool_call", "tool-call", "toolcall", "tool_use", "tool-use", "function_call": return .tool_call
            case "tool_result", "tool-result", "toolresult", "function_result": return .tool_result
            case "error", "err": return .error
            case "meta", "system", "environment_context", "environment-context", "env_context": return .meta
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
