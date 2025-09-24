import Foundation

enum CodexVersion: Comparable, CustomStringConvertible {
    case semantic(major: Int, minor: Int, patch: Int)
    case unknown(String)

    var description: String {
        switch self {
        case let .semantic(major, minor, patch):
            return "\(major).\(minor).\(patch)"
        case let .unknown(raw):
            return raw
        }
    }

    var supportsResumeByID: Bool {
        switch self {
        case let .semantic(major, minor, _):
            if major > 0 { return true }
            return major == 0 && minor >= 39
        case .unknown:
            return false
        }
    }

    static func < (lhs: CodexVersion, rhs: CodexVersion) -> Bool {
        switch (lhs, rhs) {
        case let (.semantic(lMajor, lMinor, lPatch), .semantic(rMajor, rMinor, rPatch)):
            if lMajor != rMajor { return lMajor < rMajor }
            if lMinor != rMinor { return lMinor < rMinor }
            return lPatch < rPatch
        case (.semantic, .unknown):
            return false
        case (.unknown, .semantic):
            return true
        case let (.unknown(lRaw), .unknown(rRaw)):
            return lRaw < rRaw
        }
    }

    static func parse(from raw: String) -> CodexVersion {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Common format: "codex 0.40.1" or just "0.40.1"
        let components = trimmed.split(whereSeparator: { !$0.isNumber && $0 != "." })
        if let token = components.last,
           token.contains("."),
           let semver = Self.parseSemver(String(token)) {
            return semver
        }

        if let semver = Self.parseSemver(trimmed) {
            return semver
        }

        return .unknown(trimmed)
    }

    private static func parseSemver(_ candidate: String) -> CodexVersion? {
        let parts = candidate.split(separator: ".").map(String.init)
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch = parts.count == 3 ? Int(parts[2]) ?? 0 : 0
        return .semantic(major: major, minor: minor, patch: patch)
    }
}
