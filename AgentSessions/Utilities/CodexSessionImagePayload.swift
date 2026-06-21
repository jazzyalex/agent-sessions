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

struct InlineSessionImage: Identifiable, Hashable, Sendable {
    let sessionID: String
    let imageEventID: String
    let userPromptIndex: Int?
    let sessionImageIndex: Int
    let payload: SessionImagePayload

    var id: String { "\(sessionID)-\(payload.stableID)" }
}

enum SessionInlineImageMapper {
    static func imagesByUserBlockIndex(for session: Session,
                                       maxMatches: Int = 400,
                                       shouldCancel: () -> Bool = { false }) -> [Int: [InlineSessionImage]] {
        let sessionFileURL = URL(fileURLWithPath: session.filePath)
        guard FileManager.default.fileExists(atPath: sessionFileURL.path) else { return [:] }

        struct InlineScanResult: Hashable, Sendable {
            let payload: SessionImagePayload
            let lineIndex: Int
        }

        let hasAny: Bool = {
            switch session.source {
            case .codex:
                return Base64ImageDataURLScanner.fileContainsBase64ImageDataURL(at: sessionFileURL,
                                                                               minimumBase64PayloadLength: 1,
                                                                               shouldCancel: shouldCancel)
            case .claude:
                return ClaudeBase64ImageScanner.fileContainsUserBase64Image(at: sessionFileURL, shouldCancel: shouldCancel)
            case .opencode:
                let messageIDs = Array(Set(session.events.compactMap(\.messageID)).filter { $0.hasPrefix("msg_") })
                return OpenCodeBase64ImageScanner.fileContainsBase64ImageDataURL(sessionFileURL: sessionFileURL,
                                                                                messageIDs: messageIDs,
                                                                                shouldCancel: shouldCancel)
            case .copilot:
                do {
                    return try CopilotAttachmentScanner.scanFile(at: sessionFileURL, maxMatches: 1, shouldCancel: shouldCancel).isEmpty == false
                } catch {
                    return false
                }
            case .openclaw:
                return OpenClawBase64ImageScanner.fileContainsUserBase64Image(at: sessionFileURL, shouldCancel: shouldCancel)
            default:
                return false
            }
        }()
        guard hasAny, !shouldCancel() else { return [:] }

        let located: [InlineScanResult] = {
            do {
                switch session.source {
                case .codex:
                    return try Base64ImageDataURLScanner
                        .scanFileWithLineIndexes(at: sessionFileURL, maxMatches: maxMatches, shouldCancel: shouldCancel)
                        .map { InlineScanResult(payload: .base64(sourceURL: sessionFileURL, span: $0.span), lineIndex: $0.lineIndex) }
                case .claude:
                    return try ClaudeBase64ImageScanner
                        .scanFileWithLineIndexes(at: sessionFileURL, maxMatches: maxMatches, shouldCancel: shouldCancel)
                        .map { InlineScanResult(payload: .base64(sourceURL: sessionFileURL, span: $0.span), lineIndex: $0.lineIndex) }
                case .opencode:
                    let messageIDs = Array(Set(session.events.compactMap(\.messageID)).filter { $0.hasPrefix("msg_") })

                    var messageToUserEventIndex: [String: Int] = [:]
                    var messageToFirstEventIndex: [String: Int] = [:]
                    for (idx, ev) in session.events.enumerated() {
                        guard let mid = ev.messageID, mid.hasPrefix("msg_") else { continue }
                        if messageToFirstEventIndex[mid] == nil { messageToFirstEventIndex[mid] = idx }
                        if ev.kind == .user, messageToUserEventIndex[mid] == nil { messageToUserEventIndex[mid] = idx }
                    }

                    let parts = try OpenCodeBase64ImageScanner.scanSessionPartFiles(sessionFileURL: sessionFileURL,
                                                                                   messageIDs: messageIDs,
                                                                                   maxMatches: maxMatches,
                                                                                   shouldCancel: shouldCancel)
                    return parts.map { part in
                        let mid = part.messageID
                        let eventIndex = messageToUserEventIndex[mid] ?? messageToFirstEventIndex[mid] ?? 0
                        return InlineScanResult(payload: .base64(sourceURL: part.partFileURL, span: part.span), lineIndex: eventIndex)
                    }
                case .copilot:
                    let located = try CopilotAttachmentScanner.scanFile(at: sessionFileURL, maxMatches: maxMatches, shouldCancel: shouldCancel)
                    var eventIndexByID: [String: Int] = [:]
                    eventIndexByID.reserveCapacity(min(session.events.count, 512))
                    for (idx, ev) in session.events.enumerated() {
                        eventIndexByID[ev.id] = idx
                    }
                    return located.compactMap { att in
                        let baseID = session.id + String(format: "-%04d", att.eventSequenceIndex)
                        let eventIndex = eventIndexByID[baseID] ?? 0
                        return InlineScanResult(payload: .file(fileURL: att.fileURL, mediaType: att.mediaType, fileSizeBytes: att.fileSizeBytes),
                                                lineIndex: eventIndex)
                    }
                case .openclaw:
                    return try OpenClawBase64ImageScanner
                        .scanFileWithLineIndexes(at: sessionFileURL, maxMatches: maxMatches, shouldCancel: shouldCancel)
                        .map { InlineScanResult(payload: .base64(sourceURL: sessionFileURL, span: $0.span), lineIndex: $0.lineIndex) }
                default:
                    return []
                }
            } catch {
                return []
            }
        }()

        let filtered: [InlineScanResult] = {
            switch session.source {
            case .codex:
                return located.filter { item in
                    guard case .base64(_, let span) = item.payload else { return false }
                    return Base64ImageDataURLScanner.isLikelyImageURLContext(at: sessionFileURL, startOffset: span.startOffset)
                }
            case .claude, .opencode, .copilot, .openclaw:
                return located
            default:
                return []
            }
        }()
        guard !filtered.isEmpty, !shouldCancel() else { return [:] }

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        var userEventIDToBlockIndex: [String: Int] = [:]
        userEventIDToBlockIndex.reserveCapacity(64)
        for (idx, block) in blocks.enumerated() where block.kind == .user {
            userEventIDToBlockIndex[block.eventID] = idx
        }

        let userEventIndices: [Int] = session.events.enumerated().compactMap { (idx, ev) in
            ev.kind == .user ? idx : nil
        }

        let openClawEventBase: String? = {
            guard session.source == .openclaw else { return nil }
            return sha256Hex(sessionFileURL.path)
        }()

        func openClawUserEventID(forFileLineIndex fileLineIndex: Int) -> String? {
            guard let openClawEventBase else { return nil }
            return openClawEventBase + String(format: "-%06d", fileLineIndex + 1)
        }

        func isPreambleUserEventIndex(_ idx: Int) -> Bool {
            guard session.source == .codex || session.source == .droid || session.source == .claude || session.source == .opencode else { return false }
            guard session.events.indices.contains(idx) else { return false }
            guard session.events[idx].kind == .user else { return false }
            return Session.isAgentsPreambleText(session.events[idx].text ?? "")
        }

        func nearestUserEventIndex(for lineIndex: Int) -> Int? {
            guard !userEventIndices.isEmpty else { return nil }

            let prior = userEventIndices.filter { $0 <= lineIndex }
            if let preferred = prior.last(where: { !isPreambleUserEventIndex($0) }) ?? prior.last {
                return preferred
            }

            let after = userEventIndices.filter { $0 > lineIndex }
            if let preferred = after.first(where: { !isPreambleUserEventIndex($0) }) ?? after.first {
                return preferred
            }
            return nil
        }

        func userPromptIndexForLineIndex(_ lineIndex: Int) -> Int? {
            guard lineIndex >= 0 else { return nil }
            var userIndex: Int? = nil
            var seenUsers = 0
            for (idx, event) in session.events.enumerated() {
                if event.kind == .user {
                    if idx <= lineIndex {
                        userIndex = seenUsers
                    } else if userIndex == nil {
                        userIndex = seenUsers
                    }
                    seenUsers += 1
                }
                if idx > lineIndex, userIndex != nil { break }
            }
            return userIndex
        }

        var out: [Int: [InlineSessionImage]] = [:]
        out.reserveCapacity(min(16, userEventIDToBlockIndex.count))
        var sessionImageIndex = 1

        for item in filtered {
            if shouldCancel() { break }

            let openClawEventID = openClawUserEventID(forFileLineIndex: item.lineIndex)
            let resolved: (String, Int?, Int)? = {
                if let openClawEventID, let blockIndex = userEventIDToBlockIndex[openClawEventID] {
                    let eventIndex = session.events.firstIndex(where: { $0.id == openClawEventID })
                    return (openClawEventID,
                            eventIndex.flatMap { userPromptIndexForLineIndex($0) },
                            blockIndex)
                }

                guard let targetUserEventIndex = nearestUserEventIndex(for: item.lineIndex) else { return nil }
                let targetUserEventID = session.events[targetUserEventIndex].id
                guard let blockIndex = userEventIDToBlockIndex[targetUserEventID] else { return nil }
                return (targetUserEventID, userPromptIndexForLineIndex(targetUserEventIndex), blockIndex)
            }()
            guard let (imageEventID, userPromptIndex, targetUserBlockIndex) = resolved else { continue }

            let image = InlineSessionImage(
                sessionID: session.id,
                imageEventID: imageEventID,
                userPromptIndex: userPromptIndex,
                sessionImageIndex: sessionImageIndex,
                payload: item.payload
            )
            out[targetUserBlockIndex, default: []].append(image)
            sessionImageIndex += 1
        }

        return out
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
