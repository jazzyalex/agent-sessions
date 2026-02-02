import Foundation
import CryptoKit

struct ImageBrowserFileSignature: Codable, Hashable, Sendable {
    let filePath: String
    let fileSizeBytes: Int64
    let modifiedAtUnixSeconds: Int64
}

struct ImageBrowserImageKey: Codable, Hashable, Sendable {
    let signature: ImageBrowserFileSignature
    let base64PayloadOffset: UInt64
    let base64PayloadLength: Int
    let mediaType: String
    let thumbnailMaxPixelSize: Int

    var stableID: String {
        var s = signature.filePath
        s.append("|")
        s.append(String(signature.modifiedAtUnixSeconds))
        s.append("|")
        s.append(String(signature.fileSizeBytes))
        s.append("|")
        s.append(String(base64PayloadOffset))
        s.append("|")
        s.append(String(base64PayloadLength))
        s.append("|")
        s.append(mediaType)
        s.append("|")
        s.append(String(thumbnailMaxPixelSize))
        return sha256Hex(s)
    }
}

func sha256Hex(_ input: String) -> String {
    let data = Data(input.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

