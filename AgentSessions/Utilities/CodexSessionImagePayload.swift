import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CodexSessionImagePayload {
    enum DecodeError: Error {
        case invalidBase64
        case tooLarge
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

