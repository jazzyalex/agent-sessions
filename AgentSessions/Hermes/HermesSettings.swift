import Foundation
import SwiftUI

@MainActor
final class HermesSettings: ObservableObject {
    static let shared = HermesSettings()

    enum Keys {
        static let binaryPath = "HermesBinaryPath"
        static let preferITerm = "HermesPreferITerm"
        static let fallbackPolicy = "HermesFallbackPolicy"
        static let defaultWorkingDirectory = "HermesDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var preferITerm: Bool
    @Published var fallbackPolicy: HermesFallbackPolicy
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let policy = HermesFallbackPolicy(rawValue: raw) {
            fallbackPolicy = policy
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

    func setFallbackPolicy(_ policy: HermesFallbackPolicy) {
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

    func effectiveWorkingDirectory(for _: Session) -> URL? {
        guard !defaultWorkingDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: defaultWorkingDirectory)
    }
}
