import Foundation

/// User-facing transcript view modes.
///
/// - `transcript`: Conversation-focused, normal transcript rendering.
/// - `terminal`: CLI-style terminal rendering.
/// - `json`: Raw JSON view (pretty-printed) for the underlying events.
public enum SessionViewMode: String, CaseIterable, Identifiable, Codable {
    case transcript
    case terminal
    case json
    public var id: String { rawValue }
}

public extension SessionViewMode {
    /// Map to the underlying TranscriptRenderMode used by builders.
    var transcriptRenderMode: TranscriptRenderMode {
        switch self {
        case .transcript: return .normal
        case .terminal: return .terminal
        case .json: return .json
        }
    }

    /// Derive a SessionViewMode from an existing TranscriptRenderMode
    /// for backward compatibility with persisted preferences.
    static func from(_ mode: TranscriptRenderMode) -> SessionViewMode {
        switch mode {
        case .normal: return .transcript
        case .terminal: return .terminal
        case .json: return .json
        }
    }
}
