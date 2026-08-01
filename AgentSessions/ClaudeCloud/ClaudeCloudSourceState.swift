import Foundation

/// What the cloud source is currently doing, and what the user is told about it.
///
/// Every case renders a distinct, non-empty string. That is enforced by test, not
/// convention: the reconnecting-forever bug was a degraded state that existed in the
/// model and nowhere on screen, so it read as a hang. There is no state here whose
/// presentation is "keep spinning".
enum ClaudeCloudSourceState: Equatable {
    case disabled
    case notConnected
    case expired
    case rateLimited(until: Date?)
    case offline
    case contractDrift(String)
    case empty
    case ok(count: Int)

    var displayMessage: String {
        switch self {
        case .disabled:
            return "Cloud sessions are off"
        case .notConnected:
            return "Connect claude.ai in Settings to see cloud sessions"
        case .expired:
            return "claude.ai session expired — paste a fresh session cookie in Settings"
        case .rateLimited(let until):
            guard let until else { return "Rate limited — retrying shortly" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            return "Rate limited — retrying at \(f.string(from: until))"
        case .offline:
            return "Offline — showing last known cloud sessions"
        case .contractDrift:
            return "Cloud sessions unavailable (claude.ai API changed)"
        case .empty:
            return "No active cloud sessions"
        case .ok(let count):
            return count == 1 ? "1 active cloud session" : "\(count) active cloud sessions"
        }
    }

    /// True when rows on screen may be older than they look. Only the states that
    /// deliberately retain last-known rows are stale; `empty` is a fresh answer.
    var isStale: Bool {
        switch self {
        case .rateLimited, .offline: return true
        default: return false
        }
    }
}
