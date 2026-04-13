import Foundation
import SwiftUI

@MainActor
final class CursorSettings: ObservableObject {
    static let shared = CursorSettings()

    enum Keys {
        static let binaryPath = "CursorBinaryPath"
        static let resolvedBinaryPath = "CursorResolvedBinaryPath"
        static let resolvedSupportsResume = "CursorResolvedSupportsResume"
        static let resolvedSupportsContinue = "CursorResolvedSupportsContinue"
        static let preferITerm = "CursorPreferITerm"
        static let fallbackPolicy = "CursorFallbackPolicy"
        static let defaultWorkingDirectory = "CursorDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsResume: Bool
    @Published var resolvedSupportsContinue: Bool
    @Published var preferITerm: Bool
    @Published var fallbackPolicy: CursorFallbackPolicy
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsResume = defaults.bool(forKey: Keys.resolvedSupportsResume)
        resolvedSupportsContinue = defaults.bool(forKey: Keys.resolvedSupportsContinue)
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let policy = CursorFallbackPolicy(rawValue: raw) {
            fallbackPolicy = policy
        } else {
            fallbackPolicy = .resumeThenContinue
        }
        if warmResolvedBinaryCache {
            warmResolvedBinaryPathIfNeeded()
        }
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setResolvedBinaryPath(nil)
            warmResolvedBinaryPathIfNeeded()
        }
    }

    func setResolvedBinaryPath(_ path: String?) {
        setResolvedBinary(path, supportsResume: path != nil, supportsContinue: path != nil)
    }

    func setResolvedBinary(_ path: String?, supportsResume: Bool, supportsContinue: Bool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedBinaryPath = value
        resolvedSupportsResume = !value.isEmpty && supportsResume
        resolvedSupportsContinue = !value.isEmpty && supportsContinue
        defaults.set(value, forKey: Keys.resolvedBinaryPath)
        defaults.set(resolvedSupportsResume, forKey: Keys.resolvedSupportsResume)
        defaults.set(resolvedSupportsContinue, forKey: Keys.resolvedSupportsContinue)
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

    func binaryPathForCopyCommand() -> String {
        copyCommandPlan(sessionID: "").binary
    }

    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: CursorResumeCommandBuilder.Strategy) {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return (custom, trimmedSessionID.isEmpty ? .continueMostRecent : .resumeByID(id: trimmedSessionID))
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            if !trimmedSessionID.isEmpty, resolvedSupportsResume {
                return (cached, .resumeByID(id: trimmedSessionID))
            }
            if fallbackPolicy == .resumeThenContinue, resolvedSupportsContinue {
                return (cached, .continueMostRecent)
            }
            if trimmedSessionID.isEmpty, resolvedSupportsContinue {
                return (cached, .continueMostRecent)
            }
        }

        return ("agent", trimmedSessionID.isEmpty ? .continueMostRecent : .resumeByID(id: trimmedSessionID))
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

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = CursorCLIEnvironment()
            let result = env.probe(customPath: nil)
            if case let .success(resolved) = result {
                DispatchQueue.main.async { [weak self] in
                    self?.setResolvedBinary(resolved.binaryURL.path,
                                            supportsResume: resolved.supportsResume,
                                            supportsContinue: resolved.supportsContinue)
                }
            }
        }
    }

    private func validatedCachedResolvedBinaryPath() -> String? {
        let cached = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cached.isEmpty else { return nil }
        if FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        setResolvedBinaryPath(nil)
        warmResolvedBinaryPathIfNeeded()
        return nil
    }
}

extension CursorSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "CursorTests") ?? .standard) -> CursorSettings {
        CursorSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
