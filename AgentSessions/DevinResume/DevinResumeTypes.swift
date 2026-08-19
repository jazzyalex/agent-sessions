import Foundation

/// What to do when the session id cannot be used.
///
/// Devin exposes `--resume <id>` and `--continue`, so
/// the only fallback is "continue the most recent session for this working
/// directory".
enum DevinFallbackPolicy: String {
    case sessionThenContinue
    case sessionOnly
}

struct DevinResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum DevinStrategyUsed: Equatable {
    case sessionByID
    case continueMostRecent
    case none
}

struct DevinResumeResult {
    let launched: Bool
    let strategy: DevinStrategyUsed
    let error: String?
    let command: String?
}
