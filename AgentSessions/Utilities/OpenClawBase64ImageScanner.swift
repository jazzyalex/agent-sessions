import Foundation

/// Streaming scanner for OpenClaw (and legacy Clawdbot) user-attached base64 image blocks:
/// { "type":"image", "data":"...", "mimeType":"image/jpeg" }
///
/// This is line-oriented (JSONL): it resets state on each '\n' byte and reports a 0-based line index.
///
/// Design goals:
/// - Do not load entire lines into memory (base64 can be very large).
/// - Do not match JSON-looking text embedded inside string values (e.g., tool output).
enum OpenClawBase64ImageScanner {
    static func fileContainsUserBase64Image(at url: URL, shouldCancel: () -> Bool = { false }) -> Bool {
        do {
            return try !scanFileWithLineIndexes(at: url, maxMatches: 1, shouldCancel: shouldCancel).isEmpty
        } catch {
            return false
        }
    }

    static func scanFileWithLineIndexes(at url: URL,
                                        maxMatches: Int = 200,
                                        shouldCancel: () -> Bool = { false }) throws -> [Base64ImageDataURLScanner.LocatedSpan] {
        let chunkSize = 64 * 1024
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var results: [Base64ImageDataURLScanner.LocatedSpan] = []
        results.reserveCapacity(min(maxMatches, 32))

        var lineIndex = 0
        var fileOffset: UInt64 = 0
        var cancelCheckCounter = 0

        struct PendingLargeString: Hashable, Sendable {
            let startOffset: UInt64
            let endOffsetExclusive: UInt64
            let length: Int
        }

        struct ObjectFrame {
            var state: ObjectState = .expectKeyOrEnd
            var currentKey: String? = nil
            var isImage: Bool = false
            var mediaType: String? = nil
            var base64Data: PendingLargeString? = nil
        }

        enum Container {
            case object(ObjectFrame)
            case array(ArrayState)
        }

        enum ObjectState { case expectKeyOrEnd, expectColon, expectValue, expectCommaOrEnd }
        enum ArrayState { case expectValueOrEnd, expectCommaOrEnd }

        var stack: [Container] = []

        // Per-line gating: only report user-attached images (message.role == "user").
        var lineRole: String? = nil
        var lineSpans: [Base64ImageDataURLScanner.Span] = []
        lineSpans.reserveCapacity(2)

        // String parsing
        var inString = false
        var stringEscaped = false
        var stringContentStartOffset: UInt64 = 0
        var stringMode: StringMode = .ignored
        var smallStringBytes: [UInt8] = []
        smallStringBytes.reserveCapacity(64)
        var largeStringLength: Int = 0
        var largeStringInvalid: Bool = false

        enum StringMode {
            case key
            case valueSmall(key: String)
            case valueLarge(key: String) // e.g. base64 data; do not buffer
            case ignored
        }

        func flushCurrentLineIfNeeded() {
            guard lineRole == "user" else { return }
            guard !lineSpans.isEmpty else { return }

            for span in lineSpans {
                results.append(.init(span: span, lineIndex: lineIndex))
                if results.count >= maxMatches { break }
            }
        }

        func resetForNewLine() {
            stack.removeAll(keepingCapacity: true)
            lineRole = nil
            lineSpans.removeAll(keepingCapacity: true)
            inString = false
            stringEscaped = false
            stringMode = .ignored
            smallStringBytes.removeAll(keepingCapacity: true)
            largeStringLength = 0
            largeStringInvalid = false
        }

        func currentObjectIndexInStack() -> Int? {
            for i in stride(from: stack.count - 1, through: 0, by: -1) {
                if case .object = stack[i] { return i }
            }
            return nil
        }

        func beginStringToken(at quoteOffset: UInt64) {
            stringContentStartOffset = quoteOffset &+ 1
            smallStringBytes.removeAll(keepingCapacity: true)
            largeStringLength = 0
            largeStringInvalid = false

            guard let objIndex = currentObjectIndexInStack() else {
                stringMode = .ignored
                return
            }
            guard case let .object(frame) = stack[objIndex] else {
                stringMode = .ignored
                return
            }

            switch frame.state {
            case .expectKeyOrEnd:
                stringMode = .key
            case .expectValue:
                let key = frame.currentKey ?? ""
                if key == "data" {
                    stringMode = .valueLarge(key: key)
                } else if key == "role" || key == "type" || key == "mimeType" {
                    stringMode = .valueSmall(key: key)
                } else {
                    stringMode = .ignored
                }
            default:
                stringMode = .ignored
            }
        }

        func finishValueStringToken(endOffsetExclusive: UInt64) {
            guard let objIndex = currentObjectIndexInStack(), case .object(var frame) = stack[objIndex] else { return }

            guard case .valueSmall(let key) = stringMode else { return }
            let value = String(bytes: smallStringBytes, encoding: .utf8) ?? ""

            if key == "role", lineRole == nil {
                lineRole = value
            }
            if key == "type" {
                frame.isImage = (value == "image")
            }
            if key == "mimeType", !value.isEmpty {
                frame.mediaType = value
            }

            frame.currentKey = nil
            frame.state = .expectCommaOrEnd
            stack[objIndex] = .object(frame)
        }

        func finishLargeStringToken(endOffsetExclusive: UInt64) {
            guard let objIndex = currentObjectIndexInStack(), case .object(var frame) = stack[objIndex] else { return }
            guard case .valueLarge(let key) = stringMode, key == "data" else { return }

            if !largeStringInvalid, largeStringLength > 0 {
                frame.base64Data = PendingLargeString(startOffset: stringContentStartOffset,
                                                     endOffsetExclusive: endOffsetExclusive,
                                                     length: largeStringLength)
            }

            frame.currentKey = nil
            frame.state = .expectCommaOrEnd
            stack[objIndex] = .object(frame)
        }

        func consumeIgnoredValueString() {
            guard let objIndex = currentObjectIndexInStack(), case .object(var frame) = stack[objIndex] else { return }
            frame.currentKey = nil
            frame.state = .expectCommaOrEnd
            stack[objIndex] = .object(frame)
        }

        func handleNonStringStructuralByte(_ byte: UInt8) {
            if byte == 0x0A { // '\n'
                flushCurrentLineIfNeeded()
                lineIndex += 1
                resetForNewLine()
                return
            }

            // Ignore whitespace.
            if byte == 0x20 || byte == 0x09 || byte == 0x0D { return } // space, tab, '\r'

            if byte == 0x7B { // '{'
                // If parent expects a value, consume it now.
                if let objIndex = currentObjectIndexInStack() {
                    if case .object(var frame) = stack[objIndex], frame.state == .expectValue {
                        frame.state = .expectCommaOrEnd
                        frame.currentKey = nil
                        stack[objIndex] = .object(frame)
                    }
                } else if let top = stack.last, case .array(.expectValueOrEnd) = top {
                    stack[stack.count - 1] = .array(.expectCommaOrEnd)
                }
                stack.append(.object(ObjectFrame()))
                return
            }

            if byte == 0x7D { // '}'
                if let top = stack.last, case let .object(frame) = top {
                    if frame.isImage, let payload = frame.base64Data, payload.length > 0 {
                        let media = frame.mediaType?.isEmpty == false ? frame.mediaType! : "image"
                        let approxBytes = max(0, (payload.length * 3) / 4)
                        let span = Base64ImageDataURLScanner.Span(
                            startOffset: payload.startOffset,
                            endOffset: payload.endOffsetExclusive,
                            mediaType: media,
                            base64PayloadOffset: payload.startOffset,
                            base64PayloadLength: payload.length,
                            approxBytes: approxBytes
                        )
                        lineSpans.append(span)
                    }
                }
                if !stack.isEmpty { _ = stack.popLast() }
                return
            }

            if byte == 0x5B { // '['
                if let objIndex = currentObjectIndexInStack() {
                    if case .object(var frame) = stack[objIndex], frame.state == .expectValue {
                        frame.state = .expectCommaOrEnd
                        frame.currentKey = nil
                        stack[objIndex] = .object(frame)
                    }
                } else if let top = stack.last, case .array(.expectValueOrEnd) = top {
                    stack[stack.count - 1] = .array(.expectCommaOrEnd)
                }
                stack.append(.array(.expectValueOrEnd))
                return
            }

            if byte == 0x5D { // ']'
                if !stack.isEmpty { _ = stack.popLast() }
                return
            }

            if byte == 0x3A { // ':'
                if let objIndex = currentObjectIndexInStack() {
                    if case .object(var frame) = stack[objIndex], frame.state == .expectColon {
                        frame.state = .expectValue
                        stack[objIndex] = .object(frame)
                    }
                }
                return
            }

            if byte == 0x2C { // ','
                if let objIndex = currentObjectIndexInStack() {
                    if case .object(var frame) = stack[objIndex], frame.state == .expectCommaOrEnd {
                        frame.state = .expectKeyOrEnd
                        stack[objIndex] = .object(frame)
                    }
                } else if let top = stack.last, case .array(.expectCommaOrEnd) = top {
                    stack[stack.count - 1] = .array(.expectValueOrEnd)
                }
                return
            }

            // Primitive values (numbers, true/false/null): mark value consumed where applicable.
            if let objIndex = currentObjectIndexInStack() {
                if case .object(var frame) = stack[objIndex], frame.state == .expectValue {
                    frame.state = .expectCommaOrEnd
                    frame.currentKey = nil
                    stack[objIndex] = .object(frame)
                }
            } else if let top = stack.last, case .array(.expectValueOrEnd) = top {
                stack[stack.count - 1] = .array(.expectCommaOrEnd)
            }
        }

        resetForNewLine()

        while true {
            if shouldCancel() { break }
            let chunk = try fh.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            for (i, byte) in chunk.enumerated() {
                cancelCheckCounter += 1
                if cancelCheckCounter >= 32_768 {
                    cancelCheckCounter = 0
                    if shouldCancel() { return results }
                }

                let pos = fileOffset + UInt64(i)

                if inString {
                    if stringEscaped {
                        stringEscaped = false
                        switch stringMode {
                        case .valueLarge:
                            // Base64 should not have escapes; abort this value.
                            largeStringInvalid = true
                        case .key, .valueSmall:
                            smallStringBytes.append(byte)
                        case .ignored:
                            break
                        }
                        continue
                    }

                    if byte == 0x5C { // '\\'
                        stringEscaped = true
                        switch stringMode {
                        case .key, .valueSmall:
                            smallStringBytes.append(byte)
                        case .valueLarge:
                            // Unexpected in base64; mark invalid.
                            largeStringInvalid = true
                        case .ignored:
                            break
                        }
                        continue
                    }

                    if byte == 0x22 { // '"'
                        // End of string token
                        inString = false
                        stringEscaped = false

                        if let objIndex = currentObjectIndexInStack(), case .object(var frame) = stack[objIndex] {
                            if case .key = stringMode, frame.state == .expectKeyOrEnd {
                                let key = String(bytes: smallStringBytes, encoding: .utf8) ?? ""
                                frame.currentKey = key
                                frame.state = .expectColon
                                stack[objIndex] = .object(frame)
                            } else if frame.state == .expectValue {
                                switch stringMode {
                                case .valueSmall:
                                    finishValueStringToken(endOffsetExclusive: pos)
                                case .valueLarge:
                                    finishLargeStringToken(endOffsetExclusive: pos)
                                default:
                                    consumeIgnoredValueString()
                                }
                            }
                        }

                        continue
                    }

                    // Content byte
                    switch stringMode {
                    case .key, .valueSmall:
                        if smallStringBytes.count < 512 {
                            smallStringBytes.append(byte)
                        }
                    case .valueLarge:
                        if !largeStringInvalid {
                            largeStringLength += 1
                        }
                    case .ignored:
                        break
                    }
                    continue
                }

                if byte == 0x22 { // '"'
                    // Begin string token
                    inString = true
                    stringEscaped = false
                    beginStringToken(at: pos)
                    continue
                }

                handleNonStringStructuralByte(byte)

                if results.count >= maxMatches {
                    return results
                }
            }

            fileOffset += UInt64(chunk.count)
        }

        flushCurrentLineIfNeeded()

        return results
    }
}
