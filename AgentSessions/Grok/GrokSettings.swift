import Foundation
import SwiftUI

/// Preferences backing the Grok pane.
///
/// Mirrors `PiSettings` minus `preferITerm` and `fallbackPolicy`, which Pi
/// persists but never exposes in its own pane -- stored preferences with no
/// writer are the defect class this file exists to avoid. The terminal kind
/// comes from the shared `ResumePreferenceHelpers.resolveTerminalKind()`, and
/// the fallback policy is a `GrokResumeCoordinator` default.
///
/// `defaultWorkingDirectory` is deliberately absent for a different reason:
/// Grok's working directory is authoritative in the `state.json` sidecar, and
/// a user-supplied default would be a *guess* that silently redirects
/// `--continue` at an unrelated session. `GrokResumeCoordinator` refuses that
/// strategy without a known directory instead.
@MainActor
final class GrokSettings: ObservableObject {
    static let shared = GrokSettings()

    enum Keys {
        static let binaryPath = "GrokBinaryPath"
        static let resolvedBinaryPath = "GrokResolvedBinaryPath"
        // Stored string deliberately says "Session", not "Resume". It is a
        // leftover from porting this pane off Kimi, which probes `--session`
        // where Grok probes `--resume`. Do not tidy it to match the constant:
        // the key is already persisted in every existing install, and renaming
        // it silently resets the stored capability, so resume goes quiet until
        // the user reprobes the binary in Preferences.
        static let resolvedSupportsResume = "GrokResolvedSupportsSession"
        static let resolvedSupportsContinue = "GrokResolvedSupportsContinue"
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
            clearResolvedBinary()
            warmResolvedBinaryPathIfNeeded()
        }
    }

    func setResolvedBinary(_ path: String?, supportsResume: Bool, supportsContinue: Bool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A probe that could not execute the CLI reports a real binary
        // with every capability false. Storing that is what let a single
        // failed probe disable resume for good: the cache is only
        // refreshed while the resolved path is empty, so the dead verdict
        // outlived whatever caused it. No shipping build supports none of
        // --resume or --continue, so treat it as nothing learned.
        guard supportsResume || supportsContinue else {
            clearResolvedBinary()
            return
        }
        resolvedBinaryPath = value
        resolvedSupportsResume = !value.isEmpty && supportsResume
        resolvedSupportsContinue = !value.isEmpty && supportsContinue
        defaults.set(value, forKey: Keys.resolvedBinaryPath)
        defaults.set(resolvedSupportsResume, forKey: Keys.resolvedSupportsResume)
        defaults.set(resolvedSupportsContinue, forKey: Keys.resolvedSupportsContinue)
    }

    /// Clears the path *and* the capability flags: leaving the flags set
    /// behind an empty path is a state no probe produces, and anything
    /// reading a flag without first checking the path would see a stale yes.
    func clearResolvedBinary() {
        resolvedBinaryPath = ""
        defaults.set("", forKey: Keys.resolvedBinaryPath)
        resolvedSupportsResume = false
        resolvedSupportsContinue = false
        defaults.set(false, forKey: Keys.resolvedSupportsResume)
        defaults.set(false, forKey: Keys.resolvedSupportsContinue)
    }

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The binary and strategy the copy-resume command should use.
    ///
    /// A custom binary is taken at face value — the user chose it, so we do not
    /// second-guess which flags it supports. Otherwise we prefer the probed
    /// binary's advertised capabilities, and fall back to a bare `grok` on PATH
    /// when nothing has been probed yet.
    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: GrokResumeCommandBuilder.Strategy)? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        // One source of truth for the id-present/id-absent branch.
        let preferredStrategy = GrokResumeCommandBuilder().strategy(forSessionID: trimmedSessionID)
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

        return (GrokCLIEnvironment.binaryName, preferredStrategy)
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let env = GrokCLIEnvironment()
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
        // A Grok build that supports neither --resume nor --continue does not
        // exist; such a cache entry comes from a probe that could not execute
        // the CLI at all. Keeping it silently disables every resume action
        // forever, because the cache is only refreshed while the path is empty.
        let advertisesNothing = !resolvedSupportsResume && !resolvedSupportsContinue
        if FileManager.default.isExecutableFile(atPath: cached), !advertisesNothing {
            return cached
        }
        clearResolvedBinary()
        warmResolvedBinaryPathIfNeeded()
        return nil
    }
}

extension GrokSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "GrokTests") ?? .standard) -> GrokSettings {
        GrokSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
