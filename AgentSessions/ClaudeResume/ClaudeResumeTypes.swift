import Foundation

// Public-facing types for the Claude Resume module (no app wiring yet)

enum ClaudeFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct ClaudeResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum ClaudeStrategyUsed {
    case resumeByID
    case continueMostRecent
    case none
}

struct ClaudeResumeResult {
    let launched: Bool
    let strategy: ClaudeStrategyUsed
    let error: String?
    let command: String?
}
