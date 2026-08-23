import Foundation
import SwiftUI

struct DevinProbeRequest: Equatable, Sendable {
    let generation: UInt64
    let binaryOverride: String?
}

enum DevinProbeCompletionAcceptance: Equatable {
    case accepted
    case stale(reprobe: DevinProbeRequest)
}

/// Preferences backing the Devin pane.
///
/// Mirrors `QwenSettings`, including the August 2026 probe fixes: a probe that
/// could not execute the CLI is treated as nothing learned rather than as a
/// CLI with no features, and a custom binary is validated against its own
/// probed capabilities instead of being taken at face value. The terminal kind
/// comes from the shared `ResumePreferenceHelpers.resolveTerminalKind()`, and
/// the fallback policy is a `DevinResumeCoordinator` default.
///
/// `defaultWorkingDirectory` is deliberately absent: Devin records each
/// session's directory in the `sessions.working_directory` column of
/// `sessions.db`, so resume resolves per session and a user-supplied default
/// would only be a guess that silently redirects `--continue` at an unrelated
/// session. `DevinResumeCoordinator` refuses that strategy without a known
/// directory instead.
@MainActor
final class DevinSettings: ObservableObject {
    static let shared = DevinSettings()

    enum Keys {
        static let binaryPath = "DevinBinaryPath"
        static let resolvedBinaryPath = "DevinResolvedBinaryPath"
        static let resolvedSupportsResume = "DevinResolvedSupportsResume"
        static let resolvedSupportsContinue = "DevinResolvedSupportsContinue"
    }

    @Published var binaryPath: String
    @Published var resolvedBinaryPath: String
    @Published var resolvedSupportsResume: Bool
    @Published var resolvedSupportsContinue: Bool

    private let defaults: UserDefaults
    private var probeSelectionGeneration: UInt64 = 0

    fileprivate init(defaults: UserDefaults = .standard, warmResolvedBinaryCache: Bool = true) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        resolvedSupportsResume = defaults.bool(forKey: Keys.resolvedSupportsResume)
        resolvedSupportsContinue = defaults.bool(forKey: Keys.resolvedSupportsContinue)
        // Heal a stale cache here, at launch, because this is now the only place
        // that does. Two entries are stale:
        //
        //   1. One naming a binary that advertises neither flag — it came from a
        //      probe that could not execute the CLI at all.
        //   2. One naming a binary that is no longer executable, because the CLI
        //      was moved, upgraded to a different path, or uninstalled.
        //
        // Both used to be repaired lazily by `validatedCachedResolvedBinaryPath`,
        // which `canCopyResumeCommand` reached on every context-menu render. That
        // call is now the pure `canBuildCopyCommandPlan`, so nothing repairs them
        // mid-session — and case 2 would otherwise survive a relaunch too, since
        // `warmResolvedBinaryPathIfNeeded` only rebuilds an *empty* path. For a
        // custom binary that meant no way out but retyping the path.
        let cached = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cached.isEmpty,
           (!resolvedSupportsResume && !resolvedSupportsContinue)
            || !FileManager.default.isExecutableFile(atPath: cached) {
            clearResolvedBinary()
        }
        if warmResolvedBinaryCache { warmResolvedBinaryPathIfNeeded() }
    }

    func setBinaryPath(_ path: String) {
        if normalizedBinaryOverride(path) != normalizedBinaryOverride(binaryPath) {
            probeSelectionGeneration &+= 1
        }
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
        let custom = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.isEmpty {
            clearResolvedBinary()
            warmResolvedBinaryPathIfNeeded()
        } else if !pathsReferToSameBinary(custom, resolvedBinaryPath) {
            // Capabilities belong to the probed executable. A newly typed
            // custom path must not inherit flags cached for auto or an older path.
            setResolvedBinary(nil, supportsResume: false, supportsContinue: false)
        }
    }

    func currentProbeRequest() -> DevinProbeRequest {
        DevinProbeRequest(
            generation: probeSelectionGeneration,
            binaryOverride: normalizedBinaryOverride(binaryPath)
        )
    }

    @discardableResult
    func acceptProbeCompletion(
        _ result: Result<DevinCLIEnvironment.ProbeResult, DevinCLIEnvironment.ProbeError>,
        for request: DevinProbeRequest
    ) -> DevinProbeCompletionAcceptance {
        let currentRequest = currentProbeRequest()
        guard request == currentRequest else {
            return .stale(reprobe: currentRequest)
        }

        switch result {
        case .success(let resolved):
            setResolvedBinary(
                resolved.binaryURL.path,
                supportsResume: resolved.supportsResume,
                supportsContinue: resolved.supportsContinue
            )
        case .failure:
            clearResolvedBinary()
        }
        return .accepted
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
    /// A custom binary is used only when the probe resolved *that* binary and
    /// advertised a flag; otherwise we prefer the auto-probed binary's
    /// advertised capabilities, and fall back to a bare `devin` on PATH when
    /// nothing has been probed yet.
    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: DevinResumeCommandBuilder.Strategy)? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            guard let resolved = validatedCustomResolvedBinaryPath(custom) else { return nil }
            return capabilityAwarePlan(binary: resolved, sessionID: trimmedSessionID)
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            return capabilityAwarePlan(binary: cached, sessionID: trimmedSessionID)
        }
        return (DevinCLIEnvironment.binaryName,
                DevinResumeCommandBuilder().strategy(forSessionID: trimmedSessionID))
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A custom path is warmed too, using itself as the override. Preferences
        // probes only while the user has that pane open, so without this a
        // cleared custom entry leaves every resume action off until they go
        // looking for the button that fixes it.
        let request = currentProbeRequest()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = DevinCLIEnvironment().probe(customPath: request.binaryOverride)
            DispatchQueue.main.async { [weak self] in
                _ = self?.acceptProbeCompletion(result, for: request)
            }
        }
    }

    /// Whether `copyCommandPlan` would return a plan — decided without touching
    /// anything.
    ///
    /// `copyCommandPlan` is not a predicate: on a stale cache entry it calls
    /// `clearResolvedBinary()`, which writes three `@Published` properties, and
    /// `warmResolvedBinaryPathIfNeeded()`, which spawns a probe. SwiftUI
    /// evaluates the menu's `.disabled(...)` inside a ViewBuilder, and
    /// `PreferencesView` observes this object — so calling it from there mutates
    /// observed state during view update and can kick a background probe once per
    /// row rendered. This mirrors the same decision with no writes and no I/O
    /// beyond the executable check the cached path already implies.
    ///
    /// Deliberately duplicates rather than shares the branch structure below:
    /// factoring out the common core would mean threading a "may I mutate" flag
    /// through the healing paths, and a healing routine that sometimes does not
    /// heal is a worse thing to own than eight lines of parallel logic.
    func canBuildCopyCommandPlan(sessionID: String) -> Bool {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)

        let usableBinary: Bool
        if !custom.isEmpty {
            usableBinary = !resolved.isEmpty
                && pathsReferToSameBinary(custom, resolved)
                && FileManager.default.isExecutableFile(atPath: resolved)
                && (resolvedSupportsResume || resolvedSupportsContinue)
        } else if !resolved.isEmpty {
            usableBinary = FileManager.default.isExecutableFile(atPath: resolved)
                && (resolvedSupportsResume || resolvedSupportsContinue)
        } else {
            // Nothing probed yet: `copyCommandPlan` falls back to a bare `devin`
            // and always yields a strategy.
            return true
        }

        guard usableBinary else {
            // The auto branch heals and retries with a bare `devin`; the custom
            // branch has no fallback, so a dead custom entry means no plan.
            return custom.isEmpty
        }
        return (!trimmedSessionID.isEmpty && resolvedSupportsResume) || resolvedSupportsContinue
    }

    private func validatedCachedResolvedBinaryPath() -> String? {
        let cached = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cached.isEmpty else { return nil }
        // A Devin build that supports neither --resume nor --continue does not
        // exist; such a cache entry comes from a probe that could not execute
        // the CLI at all. Keeping it silently disables every resume action
        // forever, because the cache is only refreshed while the path is empty.
        let advertisesNothing = !resolvedSupportsResume && !resolvedSupportsContinue
        if FileManager.default.isExecutableFile(atPath: cached), !advertisesNothing { return cached }
        clearResolvedBinary()
        warmResolvedBinaryPathIfNeeded()
        return nil
    }

    private func validatedCustomResolvedBinaryPath(_ custom: String) -> String? {
        let resolved = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty, pathsReferToSameBinary(custom, resolved),
              FileManager.default.isExecutableFile(atPath: resolved) else {
            return nil
        }
        // The auto-detected branch discards a capability-free entry; this one has
        // to as well, and for a sharper reason: nothing here falls back to a bare
        // `devin`, so keeping the dead entry disables resume with no way out.
        guard resolvedSupportsResume || resolvedSupportsContinue else {
            clearResolvedBinary()
            warmResolvedBinaryPathIfNeeded()
            return nil
        }
        return resolved
    }

    private func capabilityAwarePlan(
        binary: String,
        sessionID: String
    ) -> (binary: String, strategy: DevinResumeCommandBuilder.Strategy)? {
        if !sessionID.isEmpty, resolvedSupportsResume {
            return (binary, .sessionByID(id: sessionID))
        }
        if resolvedSupportsContinue {
            return (binary, .continueMostRecent)
        }
        return nil
    }

    private func pathsReferToSameBinary(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        func normalized(_ value: String) -> String {
            URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        return normalized(lhs) == normalized(rhs)
    }

    private func normalizedBinaryOverride(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DevinSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "DevinTests") ?? .standard) -> DevinSettings {
        DevinSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
