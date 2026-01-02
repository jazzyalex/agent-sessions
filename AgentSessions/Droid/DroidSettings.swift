import Foundation
import SwiftUI

@MainActor
final class DroidSettings: ObservableObject {
    static let shared = DroidSettings()

    enum Keys {
        static let binaryPath = "DroidBinaryPath"
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

extension DroidSettings {
    static func makeForTesting(defaults: UserDefaults = UserDefaults(suiteName: "DroidTests") ?? .standard) -> DroidSettings {
        DroidSettings(defaults: defaults)
    }
}
