import Foundation

struct ImageBrowserStoredSpan: Codable, Hashable, Sendable {
    let startOffset: UInt64
    let endOffset: UInt64
    let mediaType: String
    let base64PayloadOffset: UInt64
    let base64PayloadLength: Int
    let approxBytes: Int
    let lineIndex: Int
}

struct ImageBrowserStoredOpenCodeImage: Codable, Hashable, Sendable {
    let messageID: String
    let partFilePath: String
    let startOffset: UInt64
    let endOffset: UInt64
    let mediaType: String
    let base64PayloadOffset: UInt64
    let base64PayloadLength: Int
    let approxBytes: Int
    let fileLineIndex: Int
}

struct ImageBrowserStoredCopilotAttachment: Codable, Hashable, Sendable {
    let eventSequenceIndex: Int
    let filePath: String
    let mediaType: String
    let fileSizeBytes: Int64
}

struct ImageBrowserStoredAntigravityImage: Codable, Hashable, Sendable {
    let lineIndex: Int
    let filePath: String
    let mediaType: String
    let fileSizeBytes: Int64
}

struct ImageBrowserStoredIndex: Codable, Sendable {
    let signature: ImageBrowserFileSignature
    let spans: [ImageBrowserStoredSpan]
    let openCodeImages: [ImageBrowserStoredOpenCodeImage]?
    let copilotAttachments: [ImageBrowserStoredCopilotAttachment]?
    let antigravityImages: [ImageBrowserStoredAntigravityImage]?
    let createdAtUnixSeconds: Int64
}

actor ImageBrowserIndexCache {
    private let fileManager: FileManager
    private let root: URL
    private let indexDir: URL

    init(fileManager: FileManager = .default, cacheRootOverride: URL? = nil) {
        self.fileManager = fileManager
        let base: URL = cacheRootOverride ?? (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
            .appendingPathComponent("AgentSessions/ImageBrowser", isDirectory: true)
        self.root = base
        self.indexDir = base.appendingPathComponent("Index", isDirectory: true)
    }

    func loadIndexIfValid(for session: Session) -> ImageBrowserStoredIndex? {
        guard let signature = fileSignature(forPath: session.filePath) else { return nil }
        let url = indexURL(forPath: session.filePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ImageBrowserStoredIndex.self, from: data)
            guard decoded.signature == signature else { return nil }
            // Migration/bugfix: early OpenClaw builds cached an empty index because they only scanned for `data:image/...`.
            // If we have a valid cache but it contains zero spans and the session file contains user images, rebuild.
            if session.source == .openclaw, decoded.spans.isEmpty {
                let sessionURL = URL(fileURLWithPath: session.filePath)
                if OpenClawBase64ImageScanner.fileContainsUserBase64Image(at: sessionURL) {
                    invalidateIndex(for: session)
                    return nil
                }
            }
            if session.source == .antigravity, (decoded.antigravityImages ?? []).isEmpty {
                let sessionURL = URL(fileURLWithPath: session.filePath)
                if AntigravityMarkdownImageScanner.fileContainsLocalMarkdownImage(at: sessionURL) {
                    invalidateIndex(for: session)
                    return nil
                }
            }
            return decoded
        } catch {
            return nil
        }
    }

    func getOrBuildIndex(for session: Session,
                         maxMatches: Int,
                         shouldCancel: () -> Bool = { false }) async -> ImageBrowserStoredIndex {
        if shouldCancel() { return emptyIndex(for: session) }
        if let cached = loadIndexIfValid(for: session) { return cached }
        if shouldCancel() { return emptyIndex(for: session) }

        let signature = fileSignature(forPath: session.filePath) ?? ImageBrowserFileSignature(filePath: session.filePath, fileSizeBytes: 0, modifiedAtUnixSeconds: 0)
        let url = URL(fileURLWithPath: session.filePath)

        let createdAt = Int64(Date().timeIntervalSince1970)

        switch session.source {
        case .codex, .claude, .openclaw, .grok, .kimi, .pi, .hermes, .cursor:
            let located: [Base64ImageDataURLScanner.LocatedSpan] = {
                do {
                    switch session.source {
                    case .codex, .grok, .kimi, .pi, .hermes, .cursor:
                        // Grok inlines the whole image as a `data:image/…;base64,…`
                        // value on an `image` content part's `url` key, so the generic
                        // scanner finds it without a provider-specific reader.
                        //
                        // Kimi, Pi, Hermes and Cursor are wired to the same scanner on
                        // the assumption they inline data URIs too — unverified. Their
                        // parsers only ever emit a marker ("[image]", "Image attached")
                        // and never read the payload, and no local session for any of
                        // them contains a `data:image/` URI, so there was nothing to
                        // confirm the shape against. If one of them references images
                        // by path or https URL instead, this scan finds nothing and
                        // that provider needs its own reader rather than this arm.
                        return try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
                    case .claude:
                        return try ClaudeBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
                    case .openclaw:
                        return try OpenClawBase64ImageScanner.scanFileWithLineIndexes(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
                    case .antigravity, .opencode, .copilot, .droid:
                        // Old `default: return []`. Unreachable — the enclosing arm only
                        // admits the eight base64-scanned sources, and these four have
                        // their own arms further down — but explicit so a thirteenth
                        // source added to the outer arm cannot land here and silently
                        // report "no images" instead of being wired to a scanner.
                        return []
                    }
                } catch {
                    return []
                }
            }()

            let filtered: [Base64ImageDataURLScanner.LocatedSpan] = located.filter { item in
                if shouldCancel() { return false }
                let span = item.span
                guard span.base64PayloadLength >= 64, span.approxBytes >= 32 else { return false }
                switch session.source {
                case .codex, .kimi, .pi, .hermes, .cursor:
                    // The conservative filter for the providers whose payload shape is
                    // unconfirmed: require the match to sit in something that reads like
                    // an image URL, so stray base64 in tool output cannot masquerade as
                    // an attachment.
                    return Base64ImageDataURLScanner.isLikelyImageURLContext(at: url, startOffset: span.startOffset)
                case .claude, .openclaw, .grok:
                    // Every Grok match is already an `image` content part's data URI,
                    // so there is no non-image base64 to disambiguate the way Codex has.
                    return true
                case .antigravity, .opencode, .copilot, .droid:
                    // Old `default: return false`. Unreachable for the same reason as the
                    // scanner switch above; explicit so a new source added to the outer
                    // arm must choose between the conservative URL-context filter and
                    // accepting every match, instead of quietly discarding all of them.
                    return false
                }
            }

            let spans: [ImageBrowserStoredSpan] = filtered.map { item in
                let span = item.span
                return ImageBrowserStoredSpan(
                    startOffset: span.startOffset,
                    endOffset: span.endOffset,
                    mediaType: span.mediaType,
                    base64PayloadOffset: span.base64PayloadOffset,
                    base64PayloadLength: span.base64PayloadLength,
                    approxBytes: span.approxBytes,
                    lineIndex: item.lineIndex
                )
            }

            let built = ImageBrowserStoredIndex(signature: signature,
                                                spans: spans,
                                                openCodeImages: nil,
                                                copilotAttachments: nil,
                                                antigravityImages: nil,
                                                createdAtUnixSeconds: createdAt)
            saveIndex(built, forPath: session.filePath)
            return built

        case .opencode:
            let messageIDs = Array(Set(session.events.compactMap(\.messageID)).filter { $0.hasPrefix("msg_") }).sorted()
            let located: [OpenCodeBase64ImageScanner.LocatedSpan] = {
                do {
                    return try OpenCodeBase64ImageScanner.scanSessionPartFiles(sessionFileURL: url,
                                                                              messageIDs: messageIDs,
                                                                              maxMatches: maxMatches,
                                                                              shouldCancel: shouldCancel)
                } catch {
                    return []
                }
            }()

            let images: [ImageBrowserStoredOpenCodeImage] = located.map { item in
                ImageBrowserStoredOpenCodeImage(
                    messageID: item.messageID,
                    partFilePath: item.partFileURL.path,
                    startOffset: item.span.startOffset,
                    endOffset: item.span.endOffset,
                    mediaType: item.span.mediaType,
                    base64PayloadOffset: item.span.base64PayloadOffset,
                    base64PayloadLength: item.span.base64PayloadLength,
                    approxBytes: item.span.approxBytes,
                    fileLineIndex: item.fileLineIndex
                )
            }

            let built = ImageBrowserStoredIndex(signature: signature,
                                                spans: [],
                                                openCodeImages: images,
                                                copilotAttachments: nil,
                                                antigravityImages: nil,
                                                createdAtUnixSeconds: createdAt)
            saveIndex(built, forPath: session.filePath)
            return built

        case .antigravity:
            let located: [AntigravityMarkdownImageScanner.Attachment] = {
                do {
                    return try AntigravityMarkdownImageScanner.scanFile(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
                } catch {
                    return []
                }
            }()

            let images: [ImageBrowserStoredAntigravityImage] = located.map { att in
                ImageBrowserStoredAntigravityImage(lineIndex: att.lineIndex,
                                                   filePath: att.fileURL.path,
                                                   mediaType: att.mediaType,
                                                   fileSizeBytes: att.fileSizeBytes)
            }

            let built = ImageBrowserStoredIndex(signature: signature,
                                                spans: [],
                                                openCodeImages: nil,
                                                copilotAttachments: nil,
                                                antigravityImages: images,
                                                createdAtUnixSeconds: createdAt)
            saveIndex(built, forPath: session.filePath)
            return built

        case .copilot:
            let located: [CopilotAttachmentScanner.Attachment] = {
                do {
                    return try CopilotAttachmentScanner.scanFile(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
                } catch {
                    return []
                }
            }()

            let attachments: [ImageBrowserStoredCopilotAttachment] = located.map { att in
                ImageBrowserStoredCopilotAttachment(
                    eventSequenceIndex: att.eventSequenceIndex,
                    filePath: att.fileURL.path,
                    mediaType: att.mediaType,
                    fileSizeBytes: att.fileSizeBytes
                )
            }

            let built = ImageBrowserStoredIndex(signature: signature,
                                                spans: [],
                                                openCodeImages: nil,
                                                copilotAttachments: attachments,
                                                antigravityImages: nil,
                                                createdAtUnixSeconds: createdAt)
            saveIndex(built, forPath: session.filePath)
            return built

        case .droid:
            // Deliberately no image extraction. Exhaustive on purpose — this used to be
            // a `default:`, which silently gave every unlisted provider an empty index:
            // Grok, Kimi, Pi, Hermes and Cursor all landed here and showed no images,
            // with nothing to distinguish "this format has none" from "nobody wired it
            // up". A new source now has to say which it is.
            let built = ImageBrowserStoredIndex(signature: signature,
                                                spans: [],
                                                openCodeImages: nil,
                                                copilotAttachments: nil,
                                                antigravityImages: nil,
                                                createdAtUnixSeconds: createdAt)
            saveIndex(built, forPath: session.filePath)
            return built
        }

    }

    func saveIndex(_ index: ImageBrowserStoredIndex, forPath filePath: String) {
        do {
            try fileManager.createDirectory(at: indexDir, withIntermediateDirectories: true)
            let url = indexURL(forPath: filePath)
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Ignore.
        }
    }

    func invalidateIndex(for session: Session) {
        let url = indexURL(forPath: session.filePath)
        try? fileManager.removeItem(at: url)
    }
}

private extension ImageBrowserIndexCache {
    func emptyIndex(for session: Session) -> ImageBrowserStoredIndex {
        let sig = fileSignature(forPath: session.filePath) ?? ImageBrowserFileSignature(filePath: session.filePath, fileSizeBytes: 0, modifiedAtUnixSeconds: 0)
        return ImageBrowserStoredIndex(signature: sig,
                                      spans: [],
                                      openCodeImages: nil,
                                      copilotAttachments: nil,
                                      antigravityImages: nil,
                                      createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
    }

    func fileSignature(forPath path: String) -> ImageBrowserFileSignature? {
        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            return ImageBrowserFileSignature(
                filePath: path,
                fileSizeBytes: size,
                modifiedAtUnixSeconds: Int64(modDate.timeIntervalSince1970)
            )
        } catch {
            return nil
        }
    }

    func indexURL(forPath filePath: String) -> URL {
        let key = sha256Hex(filePath)
        return indexDir.appendingPathComponent("\(key).json", isDirectory: false)
    }
}
