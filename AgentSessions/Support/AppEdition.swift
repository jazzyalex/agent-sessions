import Foundation

enum AppEdition {
    static var currentSemanticVersion: SemanticVersion? {
        guard let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(string: raw)
    }

    /// Christmas Edition is enabled only for 2.9.0 (including `2.9` and `2.9.0`).
    /// It should be disabled for patch releases like 2.9.1+.
    static var isChristmasEdition29: Bool {
        guard let v = currentSemanticVersion else { return false }
        return v.major == 2 && v.minor == 9 && v.patch == 0
    }
}

