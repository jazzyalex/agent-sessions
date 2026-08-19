import Foundation
import SwiftUI

/// Preferences backing the Devin pane.
///
/// Mirrors `PiSettings` minus `preferITerm` and `fallbackPolicy`, which Pi
/// persists but never exposes in its own pane -- stored preferences with no
/// writer are the defect class this file exists to avoid. The terminal kind
/// comes from the shared `ResumePreferenceHelpers.resolveTerminalKind()`, and
/// the fallback policy is a `DevinResumeCoordinator` default.
///
/// `defaultWorkingDirectory` is deliberately absent for a different reason:
/// Devin's working directory is authoritative in the `state.json` sidecar, and
/// a user-supplied default would be a *guess* that silently redirects
/// `--continue` at an unrelated session. `DevinResumeCoordinator` refuses that
/// strategy without a known directory instead.
@MainActor
final class DevinSettings: ObservableObject {
    static let shared = DevinSettings()

    enum Keys {
        static let binaryPath = "DevinBinaryPath"
        static let resolvedBinaryPath = "DevinResolvedBinaryPath"
        static let resolvedSupportsResume = "DevinResolvedSupportsSession"
        static let resolvedSupportsContinue = "DevinResolvedSupportsContinue"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsResume: Bool
    @Published var resolvedSupportsContinue: Bool

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsResume = defaults.bool(forKey: Keys.resolvedSupportsResume)
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

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The binary and strategy the copy-resume command should use.
    ///
    /// A custom binary is taken at face value — the user chose it, so we do not
    /// second-guess which flags it supports. Otherwise we prefer the probed
    /// binary's advertised capabilities, and fall back to a bare `devin` on PATH
    /// when nothing has been probed yet.
    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: DevinResumeCommandBuilder.Strategy)? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        // One source of truth for the id-present/id-absent branch.
        let preferredStrategy = DevinResumeCommandBuilder().strategy(forSessionID: trimmedSessionID)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return (custom, preferredStrategy)
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            if !trimmedSessionID.isEmpty, resolvedSupportsResume {
                return (cached, .sessionByID(id: trimmedSessionID))
            }
            if resolvedSupportsContinue {
                return (cached, .continueMostRecent)
            }
            return nil
        }

        return (DevinCLIEnvironment.binaryName, preferredStrategy)
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = DevinCLIEnvironment()
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

extension DevinSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "DevinTests") ?? .standard) -> DevinSettings {
        DevinSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
