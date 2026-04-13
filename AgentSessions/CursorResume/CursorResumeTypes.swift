import Foundation

enum CursorFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct CursorResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
}

enum CursorStrategyUsed: Equatable {
    case resumeByID
    case continueMostRecent
    case none
}

struct CursorResumeResult {
    let launched: Bool
    let strategy: CursorStrategyUsed
    let error: String?
    let command: String?
}
