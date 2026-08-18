import Foundation
import SwiftUI

struct QwenProbeRequest: Equatable, Sendable {
    let generation: UInt64
    let binaryOverride: String?
}

enum QwenProbeCompletionAcceptance: Equatable {
    case accepted
    case stale(reprobe: QwenProbeRequest)
}

@MainActor
final class QwenSettings: ObservableObject {
    static let shared = QwenSettings()

    enum Keys {
        static let binaryPath = "QwenBinaryPath"
        static let resolvedBinaryPath = "QwenResolvedBinaryPath"
        static let resolvedSupportsResume = "QwenResolvedSupportsResume"
        static let resolvedSupportsContinue = "QwenResolvedSupportsContinue"
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
        // Heal a cache written before the writer guard existed: an entry naming a
        // binary that advertises neither flag came from a probe that could not
        // execute the CLI. Dropping it here rather than at the first read is what
        // lets the warm below rebuild it — including for a custom path, which has
        // nothing else that would ever reprobe it.
        if !resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !resolvedSupportsResume, !resolvedSupportsContinue {
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

    func currentProbeRequest() -> QwenProbeRequest {
        QwenProbeRequest(
            generation: probeSelectionGeneration,
            binaryOverride: normalizedBinaryOverride(binaryPath)
        )
    }

    @discardableResult
    func acceptProbeCompletion(
        _ result: Result<QwenCLIEnvironment.ProbeResult, QwenCLIEnvironment.ProbeError>,
        for request: QwenProbeRequest
    ) -> QwenProbeCompletionAcceptance {
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

    func copyCommandPlan(sessionID: String) -> (binary: String, strategy: QwenResumeCommandBuilder.Strategy)? {
        let trimmedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            guard let resolved = validatedCustomResolvedBinaryPath(custom) else { return nil }
            return capabilityAwarePlan(binary: resolved, sessionID: trimmedID)
        }

        if let cached = validatedCachedResolvedBinaryPath() {
            return capabilityAwarePlan(binary: cached, sessionID: trimmedID)
        }
        return (QwenCLIEnvironment.binaryName,
                QwenResumeCommandBuilder().strategy(forSessionID: trimmedID))
    }

    private func warmResolvedBinaryPathIfNeeded() {
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A custom path is warmed too, using itself as the override. Preferences
        // probes only while the user has that pane open, so without this a
        // cleared custom entry leaves every resume action off until they go
        // looking for the button that fixes it.
        let request = currentProbeRequest()
        let override = request.binaryOverride
        DispatchQueue.global(qos: .utility).async {
            if case .success(let result) = QwenCLIEnvironment().probe(customPath: override) {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.acceptProbeCompletion(.success(result), for: request)
                }
            }
        }
    }

    private func validatedCachedResolvedBinaryPath() -> String? {
        let cached = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cached.isEmpty else { return nil }
        // A Qwen build that supports neither --resume nor --continue does not
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
        // `qwen`, so keeping the dead entry disables resume with no way out.
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
    ) -> (binary: String, strategy: QwenResumeCommandBuilder.Strategy)? {
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

extension QwenSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "QwenTests") ?? .standard) -> QwenSettings {
        QwenSettings(defaults: defaults, warmResolvedBinaryCache: false)
    }
}
