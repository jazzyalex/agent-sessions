import Foundation
import SwiftUI

@MainActor
final class OpenCodeSettings: ObservableObject {
    static let shared = OpenCodeSettings()

    enum Keys {
        static let binaryPath = "OpenCodeBinaryPath"
        static let defaultWorkingDirectory = "OpenCodeDefaultWorkingDirectory"
        static let preferITerm = "OpenCodePreferITerm"
        static let fallbackPolicy = "OpenCodeFallbackPolicy"
    }

    @Published var binaryPath: String
    @Published var defaultWorkingDirectory: String
    @Published var preferITerm: Bool
    @Published var fallbackPolicy: OpenCodeFallbackPolicy

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let v = OpenCodeFallbackPolicy(rawValue: raw) {
            fallbackPolicy = v
        } else {
            fallbackPolicy = .resumeThenContinue
        }
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
    }

    func setDefaultWorkingDirectory(_ path: String) {
        defaultWorkingDirectory = path
        defaults.set(path, forKey: Keys.defaultWorkingDirectory)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func setFallbackPolicy(_ policy: OpenCodeFallbackPolicy) {
        fallbackPolicy = policy
        defaults.set(policy.rawValue, forKey: Keys.fallbackPolicy)
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

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension OpenCodeSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "OpenCodeTests") ?? .standard) -> OpenCodeSettings {
        OpenCodeSettings(defaults: defaults)
    }
}
