import Foundation

/// Stable identity keys used by the Git Inspector module
struct SessionKey: Hashable, Equatable, CustomStringConvertible {
    let id: String
    let source: String
    init(id: String, source: String) {
        self.id = id
        self.source = source
    }
    init(_ session: Session) {
        self.id = session.id
        self.source = session.source.rawValue
    }
    var rawValue: String { "\(id)|\(source)" }
    var description: String { rawValue }
}

struct RepoKey: Hashable, Equatable, CustomStringConvertible {
    /// Canonical repository root path
    let root: String
    var description: String { root }
}

struct SnapshotKey: Hashable, Equatable, CustomStringConvertible {
    /// Session identity
    let sessionKey: SessionKey
    /// Lightweight fingerprint of the JSONL head (or file mtime+size fallback)
    let fingerprint: String
    var description: String { "\(sessionKey.rawValue)#\(fingerprint)" }
}

/// Utility to compute a simple fingerprint string from file attributes
enum InspectorFingerprint {
    static func fileFingerprint(path: String) -> String {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date,
           let size = attrs[.size] as? NSNumber {
            return "mtime=\(Int(mtime.timeIntervalSince1970));size=\(size.intValue)"
        }
        return "unknown"
    }
}

