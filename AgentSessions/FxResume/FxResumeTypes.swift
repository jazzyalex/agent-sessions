import Foundation

/// What to do when the session id cannot be used.
///
/// fx exposes `--resume <id>` and `--continue`, so the only fallback is
/// "continue the latest session for this workspace".
enum FxFallbackPolicy: String {
    case sessionThenContinue
    case sessionOnly
}

struct FxResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum FxStrategyUsed: Equatable {
    case sessionByID
    case continueMostRecent
    case none
}

struct FxResumeResult {
    let launched: Bool
    let strategy: FxStrategyUsed
    let error: String?
    let command: String?
}
