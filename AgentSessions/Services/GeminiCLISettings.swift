
import Foundation

@MainActor
final class GeminiCLISettings: ObservableObject {
    static let shared = GeminiCLISettings()

    enum Keys {
        static let binaryOverride = "GeminiCLIBinaryOverride"
        static let preferITerm = "GeminiCLIPreferITerm"
    }

    @Published var binaryOverride: String
    @Published var preferITerm: Bool

    private let defaults: UserDefaults

    fileprivate init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryOverride = defaults.string(forKey: Keys.binaryOverride) ?? ""
        preferITerm = ResumePreferenceHelpers.resolvePreferITerm(ownKey: Keys.preferITerm, defaults: defaults)
    }

    func setBinaryOverride(_ path: String) {
        binaryOverride = path
        defaults.set(path, forKey: Keys.binaryOverride)
    }

    func setPreferITerm(_ value: Bool) {
        preferITerm = value
        defaults.set(value, forKey: Keys.preferITerm)
    }

    func effectiveWorkingDirectory(for session: Session) -> URL? {
        if let s = session.cwd, !s.isEmpty {
            return URL(fileURLWithPath: s)
        }
        return nil
    }
}
