import Foundation

enum HermesFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct HermesResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum HermesStrategyUsed {
    case resumeByID
    case continueMostRecent
    case none
}

struct HermesResumeResult {
    let launched: Bool
    let strategy: HermesStrategyUsed
    let error: String?
    let command: String?
}
