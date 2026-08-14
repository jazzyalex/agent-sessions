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

/// Reconciles Grok's two coordinate spaces for image placement.
///
/// Image scanners report a *physical transcript line index*; both surfaces that
/// place images otherwise compare that against positions in `session.events`. For
/// Grok those are not the same number: one record is not one event, because an
/// assistant reply carrying both `content` text and `tool_calls` emits an
/// `.assistant` event plus one `.tool_call` per call (and an unparseable record
/// emits none). Event positions therefore drift ahead of line numbers, and once the
/// drift exceeds the gap between a user turn and a later image, "last user event
/// index <= line index" resolves that image to an *earlier* prompt than the one it
/// belongs to.
///
/// This lives in one type because two callers need it — `SessionInlineImageMapper`
/// for inline images in the transcript and `ImageBrowserViewModel` for the browser's
/// prompt label — and those two already carry lookalike copies of the generic
/// nearest-user rule that have drifted apart once. Duplicating the Grok correction
/// into both would guarantee the same thing happens again.
///
/// Constructing this for a non-Grok session is free and yields an empty set, so
/// `userEventIndex(forFileLineIndex:)` returns nil and every other provider keeps
/// whatever placement its caller already did. That is the same shape as the OpenClaw
/// escape hatch in `SessionInlineImageMapper`: opt in by returning a value, opt out
/// by returning nil.
struct GrokImageUserTurns {
    /// Each Grok user turn as (transcript line it was parsed from, its position in
    /// `session.events`). Non-decreasing in both components.
    private let turns: [(lineIndex: Int, eventIndex: Int)]

    init(session: Session) {
        guard session.source == .grok else {
            turns = []
            return
        }
        var built: [(lineIndex: Int, eventIndex: Int)] = []
        for (idx, ev) in session.events.enumerated() where ev.kind == .user {
            // A Grok event id is "<line>-<suffix>"; see
            // `GrokSessionParser.sourceLineIndex(forEventID:)`, which owns that format
            // and is pinned by `InlineSessionImageMappingTests` so a rename fails a
            // test rather than silently returning images to the wrong prompt.
            guard let line = GrokSessionParser.sourceLineIndex(forEventID: ev.id) else { continue }
            built.append((lineIndex: line, eventIndex: idx))
        }
        turns = built
    }

    /// The same rule both generic paths use — last user turn at or before the image,
    /// else the first one after it — evaluated in line space instead of event space.
    ///
    /// There is nothing else to reproduce: the transcript mapper's preamble
    /// preference is gated to Codex/Droid/Claude/OpenCode and Grok transcripts carry
    /// no AGENTS preamble turn, so that preference is already a no-op here.
    ///
    /// Returns nil for a non-Grok session, or for a Grok session whose ids no longer
    /// carry a line — callers then fall back to their existing behaviour rather than
    /// dropping the image.
    func userEventIndex(forFileLineIndex fileLineIndex: Int) -> Int? {
        guard !turns.isEmpty else { return nil }
        if let prior = turns.last(where: { $0.lineIndex <= fileLineIndex }) {
            return prior.eventIndex
        }
        return turns.first?.eventIndex
    }
}

/// The rule deciding which user turn an image belongs to, shared by the two surfaces
/// that place images: `SessionInlineImageMapper` (inline images in the transcript) and
/// `ImageBrowserViewModel.buildItems` (the browser's prompt label).
///
/// It was duplicated, and the copies drifted: the browser's is the older one and never
/// received the preamble preference, so an image whose nearest preceding user record was
/// injected scaffolding was filed under the scaffolding in the browser and under the real
/// prompt in the transcript — the same image, two answers, with nothing to catch it. They
/// were aligned by hand first and are now one implementation so they cannot separate
/// again.
///
/// The one genuine difference between the two call sites is preserved as
/// `antigravityFallsBackToFirstEvent` rather than smoothed away: the transcript reaches
/// this code for Antigravity sessions and needs a target when such a session has no user
/// record at all, while the browser handles Antigravity in its own branch and never gets
/// here for it.
///
/// Callers compose the two lookups themselves rather than getting one merged entry point,
/// because they genuinely differ on what they hand the generic path — the browser passes
/// an OpenClaw-resolved event index where the transcript passes a file line — and folding
/// that in would change OpenClaw placement to tidy up an unrelated duplication.
struct ImageUserTurnResolver {
    /// Positions of every `.user` event in `session.events`.
    let userEventIndices: [Int]

    private let session: Session
    private let grokTurns: GrokImageUserTurns
    private let antigravityFallsBackToFirstEvent: Bool

    init(session: Session, antigravityFallsBackToFirstEvent: Bool) {
        self.session = session
        self.userEventIndices = session.events.enumerated().compactMap { (idx, ev) in
            ev.kind == .user ? idx : nil
        }
        self.grokTurns = GrokImageUserTurns(session: session)
        self.antigravityFallsBackToFirstEvent = antigravityFallsBackToFirstEvent
    }

    /// Whether a user record is injected scaffolding rather than something the person
    /// typed — an AGENTS.md preamble, `<environment_context>`, a `<system-reminder>`.
    /// Gated to the providers known to inject them.
    func isPreambleUserEventIndex(_ idx: Int) -> Bool {
        guard session.source == .codex || session.source == .droid || session.source == .claude || session.source == .opencode else { return false }
        guard session.events.indices.contains(idx) else { return false }
        guard session.events[idx].kind == .user else { return false }
        return Session.isAgentsPreambleText(session.events[idx].text ?? "")
    }

    /// Grok's line-space lookup. Nil for every other source, and for a Grok session whose
    /// ids no longer decode — callers then fall through to `nearestUserEventIndex(for:)`.
    func grokUserEventIndex(forFileLineIndex fileLineIndex: Int) -> Int? {
        grokTurns.userEventIndex(forFileLineIndex: fileLineIndex)
    }

    /// Last user turn at or before `index`, else the first one after it, preferring a real
    /// prompt over scaffolding in both directions.
    ///
    /// `index` is compared against positions in `session.events` while callers pass a
    /// physical file line, which only holds while a provider emits about one event per
    /// line. That conflation is deliberate and unchanged: the providers reaching this path
    /// have shipped with it, and the ones where it plainly fails get their own branch —
    /// Grok above, OpenClaw at the call sites.
    func nearestUserEventIndex(for index: Int) -> Int? {
        if antigravityFallsBackToFirstEvent, session.source == .antigravity, userEventIndices.isEmpty {
            return session.events.indices.first
        }
        guard !userEventIndices.isEmpty else { return nil }

        let prior = userEventIndices.filter { $0 <= index }
        if let preferred = prior.last(where: { !isPreambleUserEventIndex($0) }) ?? prior.last {
            return preferred
        }

        let after = userEventIndices.filter { $0 > index }
        return after.first(where: { !isPreambleUserEventIndex($0) }) ?? after.first
    }
}

enum SessionInlineImageMapper {
    /// Maps each user block's `eventID` to the block identity the terminal renderer
    /// attaches inline images by (i.e. `line.blockIndex`). Keyed by the stable
    /// `globalBlockIndex` so the key matches the renderer regardless of which
    /// window is loaded.
    static func userEventIDToBlockKey(blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(64)
        for block in blocks where block.kind == .user {
            map[block.eventID] = block.globalBlockIndex
        }
        return map
    }

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
            case .codex, .grok, .kimi, .pi, .hermes, .cursor:
                // Same generic data-URI scanner these providers use in
                // `ImageBrowserIndexCache`, so both paths agree on which providers can
                // carry inline images and which scanner finds them.
                //
                // They do not agree on every individual span: the browser additionally
                // drops anything under `base64PayloadLength >= 64 / approxBytes >= 32`
                // and this path has no lower bound, so a very small image (a 1x1 GIF,
                // say) renders inline while the browser omits it. That asymmetry
                // predates Grok and applies to Codex too; tightening it here would
                // change what Codex shows, so it is left alone deliberately.
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
            case .antigravity:
                return AntigravityMarkdownImageScanner.fileContainsLocalMarkdownImage(at: sessionFileURL, shouldCancel: shouldCancel)
            case .droid:
                return false
            }
        }()
        guard hasAny, !shouldCancel() else { return [:] }

        let located: [InlineScanResult] = {
            do {
                switch session.source {
                case .codex, .grok, .kimi, .pi, .hermes, .cursor:
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
                case .antigravity:
                    return try AntigravityMarkdownImageScanner
                        .scanFile(at: sessionFileURL, maxMatches: maxMatches, shouldCancel: shouldCancel)
                        .map { InlineScanResult(payload: .file(fileURL: $0.fileURL, mediaType: $0.mediaType, fileSizeBytes: $0.fileSizeBytes),
                                                lineIndex: $0.lineIndex) }
                case .droid:
                    return []
                }
            } catch {
                return []
            }
        }()

        let filtered: [InlineScanResult] = {
            switch session.source {
            case .codex, .kimi, .pi, .hermes, .cursor:
                return located.filter { item in
                    guard case .base64(_, let span) = item.payload else { return false }
                    return Base64ImageDataURLScanner.isLikelyImageURLContext(at: sessionFileURL, startOffset: span.startOffset)
                }
            case .claude, .opencode, .copilot, .openclaw, .antigravity, .grok:
                return located
            case .droid:
                return []
            }
        }()
        guard !filtered.isEmpty, !shouldCancel() else { return [:] }

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let userEventIDToBlockIndex: [String: Int] = userEventIDToBlockKey(blocks: blocks)

        // Antigravity reaches this path, so it needs the empty-session fallback; the
        // Image Browser handles Antigravity in its own branch and passes false.
        let turns = ImageUserTurnResolver(session: session, antigravityFallsBackToFirstEvent: true)
        let userEventIndices = turns.userEventIndices

        let openClawEventBase: String? = {
            guard session.source == .openclaw else { return nil }
            return sha256Hex(sessionFileURL.path)
        }()

        func openClawUserEventID(forFileLineIndex fileLineIndex: Int) -> String? {
            guard let openClawEventBase else { return nil }
            return openClawEventBase + String(format: "-%06d", fileLineIndex + 1)
        }

        // Counts how many user turns precede `eventIndex`, i.e. the "prompt #N"
        // ordinal carried alongside an image.
        //
        // This was called `userPromptIndexForLineIndex`, which was a lie: every
        // caller already passes an index into `session.events` (the resolved user
        // event), never a file line index, and the body compares against
        // `session.events.enumerated()` positions accordingly. The old name is what
        // made the line/event mismatch above look like it extended here too, so the
        // name now says which space it wants rather than leaving that to be
        // rediscovered.
        func userPromptOrdinal(forEventIndex eventIndex: Int) -> Int? {
            guard eventIndex >= 0 else { return nil }
            var userIndex: Int? = nil
            var seenUsers = 0
            for (idx, event) in session.events.enumerated() {
                if event.kind == .user {
                    if idx <= eventIndex {
                        userIndex = seenUsers
                    } else if userIndex == nil {
                        userIndex = seenUsers
                    }
                    seenUsers += 1
                }
                if idx > eventIndex, userIndex != nil { break }
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
                if session.source == .antigravity, userEventIndices.isEmpty {
                    guard let firstEventIndex = session.events.indices.first else { return nil }
                    let targetEventID = session.events[firstEventIndex].id
                    if let blockIndex = userEventIDToBlockIndex[targetEventID] {
                        return (targetEventID, nil, blockIndex)
                    }
                    if let firstBlock = blocks.first {
                        return (targetEventID, nil, firstBlock.globalBlockIndex)
                    }
                    return nil
                }

                if let openClawEventID, let blockIndex = userEventIDToBlockIndex[openClawEventID] {
                    let eventIndex = session.events.firstIndex(where: { $0.id == openClawEventID })
                    return (openClawEventID,
                            eventIndex.flatMap { userPromptOrdinal(forEventIndex: $0) },
                            blockIndex)
                }

                // Grok resolves in line space. `GrokImageUserTurns` returns nil for
                // every other provider and for a Grok id that no longer carries its
                // line, and falling through then puts the image back where it used to
                // land rather than dropping it — the pinning test in
                // `InlineSessionImageMappingTests` is what makes that fallback loud.
                if let targetGrokUserEventIndex = turns.grokUserEventIndex(forFileLineIndex: item.lineIndex) {
                    let targetGrokUserEventID = session.events[targetGrokUserEventIndex].id
                    if let blockIndex = userEventIDToBlockIndex[targetGrokUserEventID] {
                        return (targetGrokUserEventID,
                                userPromptOrdinal(forEventIndex: targetGrokUserEventIndex),
                                blockIndex)
                    }
                }

                guard let targetUserEventIndex = turns.nearestUserEventIndex(for: item.lineIndex) else { return nil }
                let targetUserEventID = session.events[targetUserEventIndex].id
                guard let blockIndex = userEventIDToBlockIndex[targetUserEventID] else { return nil }
                return (targetUserEventID, userPromptOrdinal(forEventIndex: targetUserEventIndex), blockIndex)
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
