import Foundation

/// What to do when the session id cannot be used.
///
/// Grok exposes `--resume <id>` and `--continue`, so
/// the only fallback is "continue the most recent session for this working
/// directory".
enum GrokFallbackPolicy: String {
    case sessionThenContinue
    case sessionOnly
}

struct GrokResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum GrokStrategyUsed: Equatable {
    case sessionByID
    case continueMostRecent
    case none
}

struct GrokResumeResult {
    let launched: Bool
    let strategy: GrokStrategyUsed
    let error: String?
    let command: String?
}
