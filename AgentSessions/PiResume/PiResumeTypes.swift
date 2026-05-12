import Foundation

enum PiFallbackPolicy: String {
    case resumeThenContinue
    case resumeOnly
}

struct PiResumeInput {
    var sessionID: String?
    var workingDirectory: URL?
    var binaryOverride: String?
    var sessionDirectory: URL?
}

enum PiStrategyUsed: Equatable {
    case sessionByID
    case resumeByID
    case continueMostRecent
    case none
}

struct PiResumeResult {
    let launched: Bool
    let strategy: PiStrategyUsed
    let error: String?
    let command: String?
}
