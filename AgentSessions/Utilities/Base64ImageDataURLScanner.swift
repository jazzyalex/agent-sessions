import Foundation

/// Streaming scanner for embedded base64 `data:image/*;base64,...` URLs inside session logs.
///
/// Design goals:
/// - Do not load entire session files into memory.
/// - Support extremely large JSONL lines (images can exceed newline/line-buffer limits).
/// - Provide a fast "presence" check for toolbar affordances.
enum Base64ImageDataURLScanner {
    struct Span: Identifiable, Hashable, Sendable {
        public let startOffset: UInt64
        /// End offset *exclusive* (the byte immediately after the last base64 character).
        public let endOffset: UInt64
        public let mediaType: String
        public let base64PayloadOffset: UInt64
        public let base64PayloadLength: Int
        public let approxBytes: Int

        public var id: String { "\(startOffset)-\(endOffset)" }
    }

    /// A located span with a 0-based line index (counting `\n` bytes, 0x0A).
    struct LocatedSpan: Identifiable, Hashable, Sendable {
        public let span: Span
        public let lineIndex: Int

        public var id: String { span.id }
    }

    /// Returns true if the file contains at least one base64 image data URL.
    ///
    /// This is optimized for "presence only": it stops as soon as it confirms a `data:image` start
    /// and a `;base64,` marker and then reads only a small prefix of the base64 payload.
    static func fileContainsBase64ImageDataURL(at url: URL,
                                               minimumBase64PayloadLength: Int = 64,
                                               shouldCancel: () -> Bool = { false }) -> Bool {
        do {
            let minLen = max(1, minimumBase64PayloadLength)
            return try scanInternal(at: url,
                                    mode: .presenceOnly(minimumPayloadChars: UInt64(minLen)),
                                    maxMatches: 1,
                                    shouldCancel: shouldCancel).isEmpty == false
        } catch {
            return false
        }
    }

    /// Scans the file and returns spans for each embedded base64 image data URL.
    ///
    /// - Parameter maxMatches: Upper bound to keep worst-case memory/CPU predictable.
    static func scanFile(at url: URL, maxMatches: Int = 200, shouldCancel: () -> Bool = { false }) throws -> [Span] {
        try scanInternal(at: url, mode: .fullSpans, maxMatches: maxMatches, shouldCancel: shouldCancel)
    }

    /// Scans the file and returns spans with the (0-based) line index where each span begins.
    ///
    /// Line indexes are computed by streaming over bytes and counting newline (0x0A) bytes.
    static func scanFileWithLineIndexes(at url: URL,
                                        maxMatches: Int = 200,
                                        shouldCancel: () -> Bool = { false }) throws -> [LocatedSpan] {
        try scanInternalWithLineIndexes(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
    }

    /// Best-effort filter to ensure a span is inside a JSON `image_url` field.
    /// This avoids false positives from code blocks or tool output that mention data URLs.
    static func isLikelyImageURLContext(at url: URL, startOffset: UInt64) -> Bool {
        let maxLookback = 160
        let lookahead = 64
        let lookback = min(maxLookback, Int(startOffset))
        let readOffset = startOffset &- UInt64(lookback)
        let readCount = lookback + lookahead
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            try fh.seek(toOffset: readOffset)
            let data = try fh.read(upToCount: readCount) ?? Data()
            let bytes = Array(data)
            let center = min(lookback, bytes.count)

            var lineStart = 0
            if center > 0, let lastNL = bytes[..<center].lastIndex(of: 0x0A) {
                lineStart = lastNL + 1
            }

            var lineEnd = bytes.count
            if center < bytes.count, let nextNL = bytes[center...].firstIndex(of: 0x0A) {
                lineEnd = nextNL
            }

            guard lineStart < lineEnd else { return false }
            let lineData = Data(bytes[lineStart..<lineEnd])
            guard let s = String(data: lineData, encoding: .utf8) else { return false }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let regex = imageURLContextRegex else { return false }
            return regex.firstMatch(in: s, options: [], range: range) != nil
        } catch {
            return false
        }
    }

    private static let imageURLContextRegex: NSRegularExpression? = {
        // Supports both `"image_url":"data:image/...` and `"image_url":{"url":"data:image/...`.
        // Require unescaped quotes so we don't match JSON-looking text inside escaped tool output strings.
        let pattern = "(?<!\\\\\\\\)\"image_url\"\\s*:\\s*(?:\\{\\s*(?<!\\\\\\\\)\"url\"\\s*:\\s*)?(?<!\\\\\\\\)\"data:image"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // MARK: - Internals

    private enum ScanMode {
        case presenceOnly(minimumPayloadChars: UInt64)
        case fullSpans
    }

    private static let startPattern: [UInt8] = Array("data:image".utf8)
    private static let base64Marker: [UInt8] = Array(";base64,".utf8)
    private static let startTable = buildKMPTable(for: startPattern)
    private static let base64Table = buildKMPTable(for: base64Marker)

    private static func scanInternal(at url: URL,
                                     mode: ScanMode,
                                     maxMatches: Int,
                                     shouldCancel: () -> Bool) throws -> [Span] {
        let chunkSize = 64 * 1024
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var results: [Span] = []
        results.reserveCapacity(min(maxMatches, 32))

        // Start-pattern KMP state
        var startMatch = 0

        // Candidate state
        var inCandidate = false
        var candidateStartOffset: UInt64 = 0
        var headerBytes: [UInt8] = []
        headerBytes.reserveCapacity(96)
        let maxHeaderBytes = 512

        // Base64 marker KMP state (used only while parsing candidate header)
        var base64Match = 0
        var sawBase64Marker = false
        var base64PayloadOffset: UInt64 = 0
        var base64Length: UInt64 = 0
        var mediaType: String = "image"

        var fileOffset: UInt64 = 0
        var cancelCheckCounter = 0

        while true {
            if shouldCancel() { break }
            let chunk = try fh.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            for (i, byte) in chunk.enumerated() {
                // Keep cancellation checks infrequent to reduce overhead on large files.
                cancelCheckCounter += 1
                if cancelCheckCounter >= 32_768 {
                    cancelCheckCounter = 0
                    if shouldCancel() { return results }
                }

                let pos = fileOffset + UInt64(i)

                if !inCandidate {
                    // Search for "data:image"
                    startMatch = kmpAdvance(match: startMatch,
                                            byte: byte,
                                            pattern: startPattern,
                                            table: startTable)
                    if startMatch == startPattern.count {
                        inCandidate = true
                        candidateStartOffset = pos &- UInt64(startPattern.count - 1)
                        headerBytes.removeAll(keepingCapacity: true)
                        headerBytes.append(contentsOf: startPattern)
                        base64Match = 0
                        sawBase64Marker = false
                        base64PayloadOffset = 0
                        base64Length = 0
                        mediaType = "image"
                        startMatch = 0
                    }
                    continue
                }

                // Candidate parsing
                if !sawBase64Marker {
                    if isTerminator(byte) {
                        // Not a base64 image URL; abort this candidate.
                        inCandidate = false
                        base64Match = 0
                        sawBase64Marker = false
                        headerBytes.removeAll(keepingCapacity: true)
                        continue
                    }
                    if headerBytes.count < maxHeaderBytes {
                        headerBytes.append(byte)
                    } else {
                        // Header is implausibly long; abort.
                        inCandidate = false
                        base64Match = 0
                        sawBase64Marker = false
                        headerBytes.removeAll(keepingCapacity: true)
                        continue
                    }

                    base64Match = kmpAdvance(match: base64Match,
                                             byte: byte,
                                             pattern: base64Marker,
                                             table: base64Table)
                    if base64Match == base64Marker.count {
                        sawBase64Marker = true
                        base64PayloadOffset = pos &+ 1
                        mediaType = parseMediaType(fromHeaderBytes: headerBytes) ?? "image"
                    }
                    continue
                }

                // Scanning base64 payload until terminator.
                if isTerminator(byte) {
                    if case .fullSpans = mode {
                        let endOffset = pos
                        let payloadLen = Int(min(UInt64(Int.max), base64Length))
                        let approxBytes = Int(min(UInt64(Int.max), (base64Length * 3) / 4))

                        if payloadLen > 0, endOffset > base64PayloadOffset, endOffset > candidateStartOffset {
                            results.append(
                                Span(
                                    startOffset: candidateStartOffset,
                                    endOffset: endOffset,
                                    mediaType: mediaType,
                                    base64PayloadOffset: base64PayloadOffset,
                                    base64PayloadLength: payloadLen,
                                    approxBytes: approxBytes
                                )
                            )
                            if results.count >= maxMatches {
                                return results
                            }
                        }
                    }

                    // Reset for next candidate.
                    inCandidate = false
                    base64Match = 0
                    sawBase64Marker = false
                    headerBytes.removeAll(keepingCapacity: true)
                    continue
                }

                // Count payload characters.
                base64Length &+= 1

                if case .presenceOnly(let minChars) = mode, base64Length >= minChars {
                    // Presence check: stop once we have a plausible payload prefix without scanning to the terminator.
                    return [
                        Span(startOffset: candidateStartOffset,
                             endOffset: pos &+ 1,
                             mediaType: mediaType,
                             base64PayloadOffset: base64PayloadOffset,
                             base64PayloadLength: Int(min(UInt64(Int.max), base64Length)),
                             approxBytes: Int(min(UInt64(Int.max), (base64Length * 3) / 4)))
                    ]
                }
            }

            fileOffset &+= UInt64(chunk.count)
        }

        return results
    }

    private static func scanInternalWithLineIndexes(at url: URL,
                                                    maxMatches: Int,
                                                    shouldCancel: () -> Bool) throws -> [LocatedSpan] {
        let chunkSize = 64 * 1024
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var results: [LocatedSpan] = []
        results.reserveCapacity(min(maxMatches, 32))

        // Start-pattern KMP state
        var startMatch = 0

        // Candidate state
        var inCandidate = false
        var candidateStartOffset: UInt64 = 0
        var candidateStartLineIndex = 0
        var headerBytes: [UInt8] = []
        headerBytes.reserveCapacity(96)
        let maxHeaderBytes = 512

        // Base64 marker KMP state (used only while parsing candidate header)
        var base64Match = 0
        var sawBase64Marker = false
        var base64PayloadOffset: UInt64 = 0
        var base64Length: UInt64 = 0
        var mediaType: String = "image"

        var fileOffset: UInt64 = 0
        var lineIndex = 0
        var cancelCheckCounter = 0

        while true {
            if shouldCancel() { break }
            let chunk = try fh.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            for (i, byte) in chunk.enumerated() {
                // Keep cancellation checks infrequent to reduce overhead on large files.
                cancelCheckCounter += 1
                if cancelCheckCounter >= 32_768 {
                    cancelCheckCounter = 0
                    if shouldCancel() { return results }
                }

                let pos = fileOffset + UInt64(i)

                if byte == 0x0A {
                    lineIndex += 1
                }

                if !inCandidate {
                    // Search for "data:image"
                    startMatch = kmpAdvance(match: startMatch,
                                            byte: byte,
                                            pattern: startPattern,
                                            table: startTable)
                    if startMatch == startPattern.count {
                        inCandidate = true
                        candidateStartOffset = pos &- UInt64(startPattern.count - 1)
                        candidateStartLineIndex = lineIndex
                        headerBytes.removeAll(keepingCapacity: true)
                        headerBytes.append(contentsOf: startPattern)
                        base64Match = 0
                        sawBase64Marker = false
                        base64PayloadOffset = 0
                        base64Length = 0
                        mediaType = "image"
                        startMatch = 0
                    }
                    continue
                }

                // Candidate parsing
                if !sawBase64Marker {
                    if isTerminator(byte) {
                        // Not a base64 image URL; abort this candidate.
                        inCandidate = false
                        base64Match = 0
                        sawBase64Marker = false
                        headerBytes.removeAll(keepingCapacity: true)
                        continue
                    }
                    if headerBytes.count < maxHeaderBytes {
                        headerBytes.append(byte)
                    } else {
                        // Header is implausibly long; abort.
                        inCandidate = false
                        base64Match = 0
                        sawBase64Marker = false
                        headerBytes.removeAll(keepingCapacity: true)
                        continue
                    }

                    base64Match = kmpAdvance(match: base64Match,
                                             byte: byte,
                                             pattern: base64Marker,
                                             table: base64Table)
                    if base64Match == base64Marker.count {
                        sawBase64Marker = true
                        base64PayloadOffset = pos &+ 1
                        mediaType = parseMediaType(fromHeaderBytes: headerBytes) ?? "image"
                    }
                    continue
                }

                // Scanning base64 payload until terminator.
                if isTerminator(byte) {
                    let endOffset = pos
                    let payloadLen = Int(min(UInt64(Int.max), base64Length))
                    let approxBytes = Int(min(UInt64(Int.max), (base64Length * 3) / 4))

                    if payloadLen > 0, endOffset > base64PayloadOffset, endOffset > candidateStartOffset {
                        results.append(
                            LocatedSpan(
                                span: Span(
                                    startOffset: candidateStartOffset,
                                    endOffset: endOffset,
                                    mediaType: mediaType,
                                    base64PayloadOffset: base64PayloadOffset,
                                    base64PayloadLength: payloadLen,
                                    approxBytes: approxBytes
                                ),
                                lineIndex: candidateStartLineIndex
                            )
                        )
                        if results.count >= maxMatches {
                            return results
                        }
                    }

                    // Reset for next candidate.
                    inCandidate = false
                    base64Match = 0
                    sawBase64Marker = false
                    headerBytes.removeAll(keepingCapacity: true)
                    continue
                }

                // Count payload characters.
                base64Length &+= 1
            }

            fileOffset &+= UInt64(chunk.count)
        }

        return results
    }

    private static func isTerminator(_ b: UInt8) -> Bool {
        switch b {
        case 0x22, // "
             0x27, // '
             0x20, // space
             0x09, // tab
             0x0A, // \n
             0x0D, // \r
             0x29, // )
             0x5D, // ]
             0x7D, // }
             0x3E: // >
            return true
        default:
            return false
        }
    }

    private static func parseMediaType(fromHeaderBytes header: [UInt8]) -> String? {
        // Expect something like: data:image/png;base64,
        // Keep this intentionally forgiving.
        let s = String(decoding: header, as: UTF8.self)
        guard let dataRange = s.range(of: "data:") else { return nil }
        guard let semi = s.range(of: ";", range: dataRange.upperBound..<s.endIndex) else { return nil }
        let raw = String(s[dataRange.upperBound..<semi.lowerBound])
        let normalized = raw.replacingOccurrences(of: "\\/", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func buildKMPTable(for pattern: [UInt8]) -> [Int] {
        guard !pattern.isEmpty else { return [] }
        var table = Array(repeating: 0, count: pattern.count)
        var j = 0
        for i in 1..<pattern.count {
            while j > 0, pattern[i] != pattern[j] {
                j = table[j - 1]
            }
            if pattern[i] == pattern[j] {
                j += 1
                table[i] = j
            }
        }
        return table
    }

    private static func kmpAdvance(match: Int, byte: UInt8, pattern: [UInt8], table: [Int]) -> Int {
        var m = match
        while m > 0, byte != pattern[m] {
            m = table[m - 1]
        }
        if byte == pattern[m] {
            m += 1
            if m == pattern.count {
                return m
            }
        }
        return m
    }
}
