import Foundation

/// Semantic version following semver.org (major.minor.patch)
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parse from "1.2.3", "v1.2.3", "1.2", or "v1.2" (missing patch defaults to 0)
    init?(string: String) {
        let normalized = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let rawParts = normalized.split(separator: ".")
        let parts: [Int] = rawParts.compactMap { part in
            let digits = part.prefix(while: { $0.isNumber })
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count == 3 ? parts[2] : 0
    }

    /// Strict parser for stable versions only (digits and dots, with optional leading "v").
    /// - Accepts: "1.2", "1.2.3", "v1.2.3"
    /// - Rejects: "1.2.3-beta1", "2.9.0x"
    init?(stableString: String) {
        let normalized = stableString.hasPrefix("v") ? String(stableString.dropFirst()) : stableString
        let rawParts = normalized.split(separator: ".")
        guard rawParts.count >= 2 && rawParts.count <= 3 else { return nil }

        var ints: [Int] = []
        ints.reserveCapacity(rawParts.count)
        for part in rawParts {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let value = Int(part) else { return nil }
            ints.append(value)
        }

        self.major = ints[0]
        self.minor = ints[1]
        self.patch = ints.count == 3 ? ints[2] : 0
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
