import Foundation
import SwiftUI

@MainActor
final class CopilotSettings: ObservableObject {
    static let shared = CopilotSettings()

    enum Keys {
        static let binaryPath = "CopilotBinaryPath"
    }

    @Published var binaryPath: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Keys.binaryPath) ?? ""
    }

    func setBinaryPath(_ path: String) {
        binaryPath = path
        defaults.set(path, forKey: Keys.binaryPath)
    }

    func hasCustomBinary() -> Bool {
        !binaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension CopilotSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "CopilotTests") ?? .standard) -> CopilotSettings {
        CopilotSettings(defaults: defaults)
    }
}

