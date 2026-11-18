import Foundation

/// Provenance recorded independently of the original event's role and text.
enum MessageOrigin: Codable, Equatable, Sendable {
    case typed
    case context(kinds: [String])
    case notification(kind: String)
    case peer(from: String)
    case compaction
    case skill(name: String)
    case command(name: String)
    case scheduled(kind: String)
    case harnessRetry
    case parentTask
    case approvalRequest
    case approvalVerdict(outcome: String)
    case placeholder

    /// A Codex message mixing typed and injected items that the parser could not align: its raw
    /// text holds injected context, and no typed projection exists.
    var isUnresolvedMixed: Bool {
        if case .context(let kinds) = self { return kinds == ["codex.mixed.unresolved"] }
        return false
    }

    var isHiddenContext: Bool {
        switch self {
        case .context, .skill, .harnessRetry: return true
        default: return false
        }
    }
}

enum MessageRowStyle: Equatable, Sendable { case card, line, none }

struct MessagePresentation: Equatable, Sendable {
    var origin: MessageOrigin?
    var body: String
    var summary: String?

    var rowStyle: MessageRowStyle {
        switch origin {
        case .placeholder: return .none
        case .context, .notification, .compaction, .skill, .scheduled, .harnessRetry: return .line
        case .peer: return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .line : .card
        default: return .card
        }
    }
}
