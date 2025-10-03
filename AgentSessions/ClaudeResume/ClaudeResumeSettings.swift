import Foundation
import SwiftUI

@MainActor
final class ClaudeResumeSettings: ObservableObject {
    static let shared = ClaudeResumeSettings()

    enum Keys {
        static let binaryPath = "ClaudeResumeBinaryPath"
        static let fallbackPolicy = "ClaudeResumeFallbackPolicy"
        static let defaultWorkingDirectory = "ClaudeResumeDefaultWorkingDirectory"
        static let preferITerm = "ClaudeResumePreferITerm"
    }

    @Published var binaryPath: String
    @Published var fallbackPolicy: ClaudeFallbackPolicy
    @Published var defaultWorkingDirectory: String
    @Published var preferITerm: Bool

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let v = ClaudeFallbackPolicy(rawValue: raw) {
            fallbackPolicy = v
        } else {
            fallbackPolicy = .resumeThenContinue
        }
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = defaults.object(forKey: Keys.preferITerm) as? Bool ?? false
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
    }

    func setFallbackPolicy(_ policy: ClaudeFallbackPolicy) {
        fallbackPolicy = policy
        defaults.set(policy.rawValue, forKey: Keys.fallbackPolicy)
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        defaults.set(path, forKey: Keys.defaultWorkingDirectory)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func effectiveWorkingDirectory(for session: Session) -> URL? {
        if let s = session.cwd, !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        if !defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: defaultWorkingDirectory)
        }
        return nil
    }
}

extension ClaudeResumeSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "ClaudeResumeTests") ?? .standard) -> ClaudeResumeSettings {
        ClaudeResumeSettings(defaults: defaults)
    }
}
