import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum SessionImagePayload: Hashable, Sendable {
    case base64(sourceURL: URL, span: Base64ImageDataURLScanner.Span)
    case file(fileURL: URL, mediaType: String, fileSizeBytes: Int64)

    var mediaType: String {
        switch self {
        case .base64(_, let span):
            return span.mediaType
        case .file(_, let mediaType, _):
            return mediaType
        }
    }

    var approxBytes: Int {
        switch self {
        case .base64(_, let span):
            return span.approxBytes
        case .file(_, _, let sizeBytes):
            if sizeBytes > Int64(Int.max) { return Int.max }
            return max(0, Int(sizeBytes))
        }
    }

    var stableID: String {
        switch self {
        case .base64(let sourceURL, let span):
            return sha256Hex(sourceURL.path) + "-" + span.id
        case .file(let fileURL, let mediaType, let sizeBytes):
            var s = "file|"
            s.append(fileURL.path)
            s.append("|")
            s.append(mediaType)
            s.append("|")
            s.append(String(sizeBytes))
            return sha256Hex(s)
        }
    }
}

enum CodexSessionImagePayload {
    enum DecodeError: Error {
        case invalidBase64
        case tooLarge
    }

    static func decodeImageData(payload: SessionImagePayload,
                                maxDecodedBytes: Int,
                                shouldCancel: () -> Bool = { false }) throws -> Data {
        switch payload {
        case .base64(let sourceURL, let span):
            return try decodeImageData(url: sourceURL, span: span, maxDecodedBytes: maxDecodedBytes, shouldCancel: shouldCancel)
        case .file(let fileURL, _, let sizeBytes):
            if shouldCancel() { throw CancellationError() }
            if sizeBytes > Int64(maxDecodedBytes) { throw DecodeError.tooLarge }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? sizeBytes
            if actualSize > Int64(maxDecodedBytes) { throw DecodeError.tooLarge }
            return try Data(contentsOf: fileURL)
        }
    }

    static func decodeImageData(url: URL,
                                span: Base64ImageDataURLScanner.Span,
                                maxDecodedBytes: Int,
                                shouldCancel: () -> Bool = { false }) throws -> Data {
        if shouldCancel() { throw CancellationError() }
        if span.approxBytes > maxDecodedBytes {
            throw DecodeError.tooLarge
        }

        let payload = try readFileSlice(url: url,
                                        offset: span.base64PayloadOffset,
                                        length: span.base64PayloadLength,
                                        shouldCancel: shouldCancel)
        if shouldCancel() { throw CancellationError() }
        guard let decoded = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            throw DecodeError.invalidBase64
        }
        if shouldCancel() { throw CancellationError() }

        if decoded.count > maxDecodedBytes {
            throw DecodeError.tooLarge
        }

        return decoded
    }

    static func makeThumbnail(from imageData: Data, maxPixelSize: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func suggestedUTType(for mediaType: String) -> UTType {
        UTType(mimeType: mediaType) ?? .image
    }

    static func suggestedFileExtension(for mediaType: String) -> String {
        let normalized = mediaType.lowercased()
        switch normalized {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/tiff", "image/tif":
            return "tiff"
        case "image/heic":
            return "heic"
        case "image/heif":
            return "heif"
        default:
            if normalized.hasPrefix("image/") {
                return String(normalized.dropFirst("image/".count))
            }
            return "img"
        }
    }

    private static func readFileSlice(url: URL,
                                      offset: UInt64,
                                      length: Int,
                                      shouldCancel: () -> Bool = { false }) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)

        var remaining = max(0, length)
        var out = Data()
        out.reserveCapacity(min(remaining, 256 * 1024))

        let chunkSize = 64 * 1024
        while remaining > 0 {
            if shouldCancel() { throw CancellationError() }
            let n = min(chunkSize, remaining)
            let chunk = try fh.read(upToCount: n) ?? Data()
            if chunk.isEmpty { break }
            out.append(chunk)
            remaining -= chunk.count
        }

        return out
    }
}
