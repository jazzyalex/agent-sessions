import Foundation

/// Semantic version following semver.org (major.minor.patch)
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parse from "1.2.3", "v1.2.3", "1.2", or "v1.2" (missing patch defaults to 0)
    init?(string: String) {
        let normalized = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count == 3 ? parts[2] : 0
    }

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
