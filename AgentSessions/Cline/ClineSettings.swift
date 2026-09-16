import Foundation
import SwiftUI

struct ClineProbeRequest: Equatable, Sendable {
    let generation: UInt64
    let binaryOverride: String?
}

enum ClineProbeCompletionAcceptance: Equatable {
    case accepted
    case stale(reprobe: ClineProbeRequest)
}

/// Preferences backing the Cline pane.
///
/// Cline claims no resume command, so this stores only the custom binary path
/// (for detection/provenance) and leaves command planning to sources that
/// advertise resume flags. Mirrors the minimal `DroidSettings` shape.
@MainActor
final class ClineSettings: ObservableObject {
    static let shared = ClineSettings()

    enum Keys {
        static let binaryPath = ClinePreferencesKey.binaryPath
        static let resolvedBinaryPath = ClinePreferencesKey.resolvedBinaryPath
    }

    @Published var binaryPath: String
    @Published private(set) var resolvedBinaryPath: String

    private let defaults: UserDefaults
    private var probeSelectionGeneration: UInt64 = 0

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
        resolvedBinaryPath = defaults.string(forKey: Keys.resolvedBinaryPath) ?? ""
        if !resolvedBinaryPath.isEmpty,
           !FileManager.default.isExecutableFile(atPath: resolvedBinaryPath) {
            clearResolvedBinaryPath()
        }
    }

    func setBinaryPath(_ path: String) {
        let oldPath = Self.normalizedBinaryOverride(binaryPath)
        let newPath = Self.normalizedBinaryOverride(path)
        if oldPath != newPath {
            probeSelectionGeneration &+= 1
        }
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
        if oldPath != newPath {
            clearResolvedBinaryPath()
            defaults.set(false, forKey: ClinePreferencesKey.cliAvailable)
        }
    }

    func currentProbeRequest() -> ClineProbeRequest {
        ClineProbeRequest(
            generation: probeSelectionGeneration,
            binaryOverride: Self.normalizedBinaryOverride(binaryPath)
        )
    }

    @discardableResult
    func acceptProbeCompletion(
        _ result: Result<ClineCLIEnvironment.ProbeResult, ClineCLIEnvironment.ProbeError>,
        for request: ClineProbeRequest
    ) -> ClineProbeCompletionAcceptance {
        let currentRequest = currentProbeRequest()
        guard request == currentRequest else {
            return .stale(reprobe: currentRequest)
        }

        switch result {
        case .success(let resolved):
            setResolvedBinaryPath(resolved.binaryURL.path)
        case .failure:
            clearResolvedBinaryPath()
        }
        return .accepted
    }

    func setResolvedBinaryPath(_ path: String?) {
        resolvedBinaryPath = path ?? ""
        if let path, !path.isEmpty {
            defaults.set(path, forKey: Keys.resolvedBinaryPath)
        } else {
            defaults.removeObject(forKey: Keys.resolvedBinaryPath)
        }
    }

    func clearResolvedBinaryPath() {
        setResolvedBinaryPath(nil)
    }

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedBinaryOverride(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ClineSessionsRootPreference {
    static func isValid(_ rawPath: String,
                        fileProbe: any FileProbing = DefaultFileProbe(),
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let expanded = UserPathExpansion.expand(trimmed, relativeTo: homeDirectory)
        return fileProbe.directoryExists(atPath: expanded)
    }

    @discardableResult
    static func commit(_ rawPath: String,
                       defaults: UserDefaults = .standard,
                       fileProbe: any FileProbing = DefaultFileProbe(),
                       homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard isValid(rawPath, fileProbe: fileProbe, homeDirectory: homeDirectory) else {
            return false
        }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: ClinePreferencesKey.sessionsRootOverride)
        } else {
            defaults.set(trimmed, forKey: ClinePreferencesKey.sessionsRootOverride)
        }
        return true
    }
}

extension ClineSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "ClineTests") ?? .standard) -> ClineSettings {
        ClineSettings(defaults: defaults)
    }
}
