import Foundation

// Test-only shims for types referenced by AgentSessions/Model/Session.swift.
// The LogicTests target intentionally avoids pulling in the full app module.

enum FeatureFlags {
    static let filterUsesCachedTranscriptOnly: Bool = true
}

final class TranscriptCache {
    func getCached(_ sessionID: String) -> String? { nil }
    func getOrGenerate(session: Session) -> String { "" }
}

