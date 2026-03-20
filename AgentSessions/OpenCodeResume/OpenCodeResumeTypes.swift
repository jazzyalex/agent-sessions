import Foundation

enum OpenCodeFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct OpenCodeResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum OpenCodeStrategyUsed {
    case resumeByID
    case continueMostRecent
    case none
}

struct OpenCodeResumeResult {
    let launched: Bool
    let strategy: OpenCodeStrategyUsed
    let error: String?
    let command: String?
}
