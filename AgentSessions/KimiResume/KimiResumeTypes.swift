import Foundation

/// What to do when the session id cannot be used.
///
/// Kimi exposes `--session <id>` and `--continue`; there is no `--resume`, so
/// the only fallback is "continue the most recent session for this working
/// directory".
enum KimiFallbackPolicy: String {
    case sessionThenContinue
    case sessionOnly
}

struct KimiResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum KimiStrategyUsed: Equatable {
    case sessionByID
    case continueMostRecent
    case none
}

struct KimiResumeResult {
    let launched: Bool
    let strategy: KimiStrategyUsed
    let error: String?
    let command: String?
}
