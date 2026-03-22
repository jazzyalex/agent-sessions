import Foundation
import SwiftUI

@MainActor
final class CopilotSettings: ObservableObject {
    static let shared = CopilotSettings()

    enum Keys {
        static let binaryPath = "CopilotBinaryPath"
        static let preferITerm = "CopilotPreferITerm"
        static let fallbackPolicy = "CopilotFallbackPolicy"
        static let defaultWorkingDirectory = "CopilotDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var preferITerm: Bool
    @Published var fallbackPolicy: CopilotFallbackPolicy
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let v = CopilotFallbackPolicy(rawValue: raw) {
            fallbackPolicy = v
        } else {
            fallbackPolicy = .resumeThenContinue
        }
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func setFallbackPolicy(_ policy: CopilotFallbackPolicy) {
        fallbackPolicy = policy
        defaults.set(policy.rawValue, forKey: Keys.fallbackPolicy)
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        defaults.set(path, forKey: Keys.defaultWorkingDirectory)
    }

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

extension CopilotSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "CopilotTests") ?? .standard) -> CopilotSettings {
        CopilotSettings(defaults: defaults)
    }
}

