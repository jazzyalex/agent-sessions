import Foundation

enum CopilotFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct CopilotResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum CopilotStrategyUsed {
    case resumeByID
    case continueMostRecent
    case none
}

struct CopilotResumeResult {
    let launched: Bool
    let strategy: CopilotStrategyUsed
    let error: String?
    let command: String?
}
