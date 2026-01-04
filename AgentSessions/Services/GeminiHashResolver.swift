import Foundation
import CryptoKit

/// Maps Gemini hashed project directories back to real working directories by
/// hashing known candidate paths (e.g., from Codex/Claude sessions).
///
/// Hashing rule matched in the wild: SHA-256 of the full absolute path string
/// without a trailing slash. Example:
/// sha256("/Users/alexm/Repository/Codex-History")
///   = 205016864bd110904e9ad8314192344ab398d043e779da15bedbb9ee9be00da2
final class GeminiHashResolver: @unchecked Sendable {
    static let shared = GeminiHashResolver()

    private let queue = DispatchQueue(label: "GeminiHashResolver", qos: .utility)
    private var map: [String: String] = [:] // hash -> absolute path

    private init() {}

    func resolve(_ hash: String) -> String? {
        queue.sync { map[hash] }
    }

    func registerCandidate(path raw: String) {
        let p = Self.normalize(raw)
        guard !p.isEmpty, p.first == "/" else { return }
        let h = Self.sha256(p)
        queue.async { self.map[h] = p }
    }

    func registerCandidates(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.async {
            for raw in paths {
                let p = Self.normalize(raw)
                guard !p.isEmpty, p.first == "/" else { continue }
                let h = Self.sha256(p)
                self.map[h] = p
            }
        }
    }

    private static func normalize(_ raw: String) -> String {
        var s = (raw as NSString).expandingTildeInPath
        while s.hasSuffix("/") && s.count > 1 { s.removeLast() }
        return URL(fileURLWithPath: s).path // standardize
    }

    private static func sha256(_ s: String) -> String {
        let data = s.data(using: .utf8) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
