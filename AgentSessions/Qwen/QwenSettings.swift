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
            setResolvedBinaryPath(nil)
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
            setResolvedBinaryPath(nil)
        }
        return .accepted
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
        guard resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = currentProbeRequest()
        DispatchQueue.global(qos: .utility).async {
            if case .success(let result) = QwenCLIEnvironment().probe(customPath: nil) {
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
        setResolvedBinaryPath(nil)
        warmResolvedBinaryPathIfNeeded()
        return nil
    }

    private func validatedCustomResolvedBinaryPath(_ custom: String) -> String? {
        let resolved = resolvedBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty, pathsReferToSameBinary(custom, resolved),
              FileManager.default.isExecutableFile(atPath: resolved) else {
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
