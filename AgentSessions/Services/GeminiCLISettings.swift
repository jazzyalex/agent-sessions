
import Foundation

@MainActor
final class GeminiCLISettings: ObservableObject {
    static let shared = GeminiCLISettings()

    enum Keys {
        static let binaryOverride = "GeminiCLIBinaryOverride"
    }

    @Published var binaryOverride: String

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryOverride = defaults.string(forKey: Keys.binaryOverride) ?? ""
    }

    func setBinaryOverride(_ path: String) {
        binaryOverride = path
        defaults.set(path, forKey: Keys.binaryOverride)
    }
}
