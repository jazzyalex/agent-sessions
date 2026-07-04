import Foundation

/// User-facing transcript view modes.
///
/// - `blocks`: "Rich" — block-based rendering with collapsible tool calls (v5 redesign).
/// - `transcript`: Conversation-focused, normal transcript rendering.
/// - `terminal`: CLI-style terminal rendering.
/// - `json`: Raw JSON view (pretty-printed) for the underlying events.
public enum SessionViewMode: String, CaseIterable, Identifiable, Codable {
    case blocks        // "Rich" — block-based rendering (v5 redesign)
    case transcript
    case terminal
    case json
    public var id: String { rawValue }
}

public extension SessionViewMode {
    /// Map to the underlying TranscriptRenderMode used by builders.
    var transcriptRenderMode: TranscriptRenderMode {
        switch self {
        case .blocks: return .normal
        case .transcript: return .normal
        case .terminal: return .terminal
        case .json: return .json
        }
    }

    /// Derive a SessionViewMode from an existing TranscriptRenderMode
    /// for backward compatibility with persisted preferences.
    ///
    /// One-way mapping: `.blocks` (Rich) has no legacy TranscriptRenderMode
    /// counterpart, so it deliberately maps to `.normal` for persistence
    /// compatibility with old builds, but `.normal` always derives back to
    /// `.transcript` here (never `.blocks`). Old builds reading a preference
    /// written by a build that supports Rich mode will fall back to Text.
    static func from(_ mode: TranscriptRenderMode) -> SessionViewMode {
        switch mode {
        case .normal: return .transcript
        case .terminal: return .terminal
        case .json: return .json
        }
    }
}
