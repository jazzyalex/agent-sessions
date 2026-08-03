import Foundation
import SwiftUI

/// Preferences backing the Kimi Code pane.
///
/// Mirrors `PiSettings`, minus the terminal-launch fields (`preferITerm`,
/// `fallbackPolicy`, `defaultWorkingDirectory`): Kimi is tier-2, so
/// launch-in-terminal resume is unsupported and only the copy-resume command
/// consumes the resolved binary.
@MainActor
final class KimiSettings: ObservableObject {
    static let shared = KimiSettings()

    enum Keys {
        static let binaryPath = "KimiBinaryPath"
        static let resolvedBinaryPath = "KimiResolvedBinaryPath"
        static let resolvedSupportsSession = "KimiResolvedSupportsSession"
        static let resolvedSupportsContinue = "KimiResolvedSupportsContinue"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsSession: Bool
    @Published var resolvedSupportsContinue: Bool

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsSession = defaults.bool(forKey: Keys.resolvedSupportsSession)
        resolvedSupportsContinue = defaults.bool(forKey: Keys.resolvedSupportsContinue)
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
        setResolvedBinary(path, supportsSession: path != nil, supportsContinue: path != nil)
    }

    func setResolvedBinary(_ path: String?, supportsSession: Bool, supportsContinue: Bool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        resolvedBinaryPath = value
        resolvedSupportsSession = !value.isEmpty && supportsSession
        resolvedSupportsContinue = !value.isEmpty && supportsContinue
        defaults.set(value, forKey: Keys.resolvedBinaryPath)
        defaults.set(resolvedSupportsSession, forKey: Keys.resolvedSupportsSession)
        defaults.set(resolvedSupportsContinue, forKey: Keys.resolvedSupportsContinue)
    }

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The binary and strategy the copy-resume command should use.
    ///
    /// A custom binary is taken at face value — the user chose it, so we do not
    /// second-guess which flags it supports. Otherwise we prefer the probed
    /// binary's advertised capabilities, and fall back to a bare `kimi` on PATH
    /// when nothing has been probed yet.
    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: KimiResumeCommandBuilder.Strategy)? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return (custom, trimmedSessionID.isEmpty ? .continueMostRecent : .sessionByID(id: trimmedSessionID))
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            if !trimmedSessionID.isEmpty, resolvedSupportsSession {
                return (cached, .sessionByID(id: trimmedSessionID))
            }
            if resolvedSupportsContinue {
                return (cached, .continueMostRecent)
            }
            return nil
        }

        return (KimiCLIEnvironment.binaryName,
                trimmedSessionID.isEmpty ? .continueMostRecent : .sessionByID(id: trimmedSessionID))
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = KimiCLIEnvironment()
            let result = env.probe(customPath: nil)
            if case let .success(resolved) = result {
                DispatchQueue.main.async { [weak self] in
                    self?.setResolvedBinary(resolved.binaryURL.path,
                                            supportsSession: resolved.supportsSession,
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

extension KimiSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "KimiTests") ?? .standard) -> KimiSettings {
        KimiSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
