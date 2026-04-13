import Foundation
import SwiftUI

@MainActor
final class CursorSettings: ObservableObject {
    static let shared = CursorSettings()

    enum Keys {
        static let binaryPath = "CursorBinaryPath"
        static let preferITerm = "CursorPreferITerm"
        static let fallbackPolicy = "CursorFallbackPolicy"
        static let defaultWorkingDirectory = "CursorDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var preferITerm: Bool
    @Published var fallbackPolicy: CursorFallbackPolicy
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let policy = CursorFallbackPolicy(rawValue: raw) {
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

    func setFallbackPolicy(_ policy: CursorFallbackPolicy) {
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
        if let sessionCwd = session.cwd, !sessionCwd.isEmpty {
            return URL(fileURLWithPath: sessionCwd)
        }
        if let inferredCwd = CursorSessionParser.inferCWDBestEffort(from: URL(fileURLWithPath: session.filePath)),
           !inferredCwd.isEmpty {
            return URL(fileURLWithPath: inferredCwd)
        }
        if !defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: defaultWorkingDirectory)
        }
        return nil
    }
}

extension CursorSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "CursorTests") ?? .standard) -> CursorSettings {
        CursorSettings(defaults: defaults)
    }
}
