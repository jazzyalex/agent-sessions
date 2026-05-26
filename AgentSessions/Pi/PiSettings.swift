import Foundation
import SwiftUI

@MainActor
final class PiSettings: ObservableObject {
    static let shared = PiSettings()

    enum Keys {
        static let binaryPath = "PiBinaryPath"
        static let resolvedBinaryPath = "PiResolvedBinaryPath"
        static let resolvedSupportsSession = "PiResolvedSupportsSession"
        static let resolvedSupportsResume = "PiResolvedSupportsResume"
        static let resolvedSupportsContinue = "PiResolvedSupportsContinue"
        static let preferITerm = "PiPreferITerm"
        static let fallbackPolicy = "PiFallbackPolicy"
        static let defaultWorkingDirectory = "PiDefaultWorkingDirectory"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsSession: Bool
    @Published var resolvedSupportsResume: Bool
    @Published var resolvedSupportsContinue: Bool
    @Published var preferITerm: Bool

    var terminalKind: TerminalKind {
        ResumePreferenceHelpers.resolveTerminalKind()
    }

    @Published var fallbackPolicy: PiFallbackPolicy
    @Published var defaultWorkingDirectory: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsSession = defaults.bool(forKey: Keys.resolvedSupportsSession)
        resolvedSupportsResume = defaults.bool(forKey: Keys.resolvedSupportsResume)
        resolvedSupportsContinue = defaults.bool(forKey: Keys.resolvedSupportsContinue)
        defaultWorkingDirectory = defaults.string(forKey: Keys.defaultWorkingDirectory) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
        if let raw = defaults.string(forKey: Keys.fallbackPolicy), let policy = PiFallbackPolicy(rawValue: raw) {
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
        setResolvedBinary(path, supportsSession: path != nil, supportsResume: path != nil, supportsContinue: path != nil)
    }

    func setResolvedBinary(_ path: String?, supportsSession: Bool, supportsResume: Bool, supportsContinue: Bool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedBinaryPath = value
        resolvedSupportsSession = !value.isEmpty && supportsSession
        resolvedSupportsResume = !value.isEmpty && supportsResume
        resolvedSupportsContinue = !value.isEmpty && supportsContinue
        defaults.set(value, forKey: Keys.resolvedBinaryPath)
        defaults.set(resolvedSupportsSession, forKey: Keys.resolvedSupportsSession)
        defaults.set(resolvedSupportsResume, forKey: Keys.resolvedSupportsResume)
        defaults.set(resolvedSupportsContinue, forKey: Keys.resolvedSupportsContinue)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func setFallbackPolicy(_ policy: PiFallbackPolicy) {
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

    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: PiResumeCommandBuilder.Strategy, sessionDirectory: URL?)? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionDirectory = configuredSessionDirectory()
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return (custom, trimmedSessionID.isEmpty ? .continueMostRecent : .sessionByID(id: trimmedSessionID), sessionDirectory)
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            if !trimmedSessionID.isEmpty, resolvedSupportsSession {
                return (cached, .sessionByID(id: trimmedSessionID), sessionDirectory)
            }
            if !trimmedSessionID.isEmpty, resolvedSupportsResume {
                return (cached, .resumeByID(id: trimmedSessionID), sessionDirectory)
            }
            if fallbackPolicy == .resumeThenContinue, resolvedSupportsContinue {
                return (cached, .continueMostRecent, sessionDirectory)
            }
            if trimmedSessionID.isEmpty, resolvedSupportsContinue {
                return (cached, .continueMostRecent, sessionDirectory)
            }
            return nil
        }

        return ("pi", trimmedSessionID.isEmpty ? .continueMostRecent : .sessionByID(id: trimmedSessionID), sessionDirectory)
    }

    func effectiveWorkingDirectory(for session: Session) -> URL? {
        if let sessionCwd = session.cwd, !sessionCwd.isEmpty {
            return URL(fileURLWithPath: sessionCwd)
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
            let env = PiCLIEnvironment()
            let result = env.probe(customPath: nil)
            if case let .success(resolved) = result {
                DispatchQueue.main.async { [weak self] in
                    self?.setResolvedBinary(resolved.binaryURL.path,
                                            supportsSession: resolved.supportsSession,
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

    private func configuredSessionDirectory() -> URL? {
        let raw = defaults.string(forKey: PreferencesKey.Paths.piSessionsRootOverride)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return PiSessionDiscovery(customRoot: expanded).sessionsRoot()
    }
}

extension PiSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "PiTests") ?? .standard) -> PiSettings {
        PiSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
