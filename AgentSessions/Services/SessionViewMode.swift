import Foundation

/// User-facing transcript view modes.
///
/// - `blocks`: "Session" (formerly "Rich") — block-based rendering with collapsible
///   tool calls (v5 redesign). This is now the ONLY session-style transcript view;
///   the old Terminal-backed "Session" view has been retired from the UI (C4a).
/// - `transcript`: Conversation-focused, normal transcript rendering ("Text").
/// - `terminal`: CLI-style terminal rendering. No longer reachable as an ACTIVE
///   view mode — `resolveViewMode` maps any persisted/legacy `.terminal` state to
///   `.blocks`. The case is kept because persistence migration must recognize it,
///   `transcriptRenderMode` still maps to it, and `SessionTerminalView`'s statics
///   (e.g. `computePreambleUserBlockIndexes`) are still used by `.blocks` rendering.
/// - `json`: Raw JSON view (pretty-printed) for the underlying events.
public enum SessionViewMode: String, CaseIterable, Identifiable, Codable {
    case blocks        // "Session" — block-based rendering (v5 redesign)
    case transcript
    case terminal      // legacy-only; unreachable as an active mode post-migration
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
    /// One-way mapping: `.blocks` (Session) has no legacy TranscriptRenderMode
    /// counterpart, so it deliberately maps to `.normal` for persistence
    /// compatibility with old builds, but `.normal` always derives back to
    /// `.transcript` here (never `.blocks`). Old builds reading a preference
    /// written by a build that supports Session (blocks) mode will fall back to Text.
    ///
    /// Note: this raw derivation still returns `.terminal` for a legacy `.terminal`
    /// render mode — callers that need the resolved, UI-reachable mode should go
    /// through `resolveViewMode(viewModeRaw:renderModeRaw:)` instead, which folds
    /// `.terminal` into `.blocks`.
    static func from(_ mode: TranscriptRenderMode) -> SessionViewMode {
        switch mode {
        case .normal: return .transcript
        case .terminal: return .terminal
        case .json: return .json
        }
    }
}

/// Resolves the persisted view-mode preference (plus legacy render-mode fallback)
/// into the `SessionViewMode` that should actually be shown.
///
/// This is the single source of truth for the Terminal-removal migration (C4a):
/// the old Terminal-backed "Session" view is no longer reachable from the menu,
/// so any persisted state that used to mean "show Terminal" must resolve to
/// `.blocks` (the new Session view) instead of leaving the user on a blank or
/// unreachable view.
///
/// Mapping:
/// - `viewModeRaw == "terminal"` → `.blocks` (existing Terminal users land on Session)
/// - `viewModeRaw == "blocks"` → `.blocks`
/// - `viewModeRaw == "transcript"` → `.transcript`
/// - `viewModeRaw == "json"` → `.json`
/// - `viewModeRaw` empty/unrecognized → fall back to legacy `renderModeRaw`
///   (via `SessionViewMode.from`), with a legacy `.terminal` render mode also
///   folding to `.blocks`; any remaining unknown/empty value defaults to `.blocks`.
public func resolveViewMode(viewModeRaw: String, renderModeRaw: String) -> SessionViewMode {
    if let persisted = SessionViewMode(rawValue: viewModeRaw) {
        return persisted == .terminal ? .blocks : persisted
    }
    let legacy = TranscriptRenderMode(rawValue: renderModeRaw).map(SessionViewMode.from) ?? .blocks
    return legacy == .terminal ? .blocks : legacy
}
