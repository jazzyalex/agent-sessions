import Foundation

/// Streaming scanner for Claude Code user-attached base64 image blocks:
/// { "type":"image", "source": { "type":"base64", "media_type":"image/jpeg", "data":"..." } }
///
/// This is line-oriented (JSONL): it resets state on each '\n' byte and reports a 0-based line index.
///
/// Design goals:
/// - Do not load entire lines into memory (base64 can be very large).
/// - Do not match JSON-looking text embedded inside string values (e.g., tool output).
enum ClaudeBase64ImageScanner {
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

        struct ObjectFrame {
            var state: ObjectState = .expectKeyOrEnd
            var currentKey: String? = nil
            var isImage: Bool = false
            var isBase64Source: Bool = false
            var mediaType: String? = nil
        }

        enum Container {
            case object(ObjectFrame)
            case array(ArrayState)
        }

        enum ObjectState { case expectKeyOrEnd, expectColon, expectValue, expectCommaOrEnd }
        enum ArrayState { case expectValueOrEnd, expectCommaOrEnd }

        var stack: [Container] = []

        // Per-line gating: only report user-attached images (role=user/human or top-level type=user-like).
        var isUserLine = false

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

        func resetForNewLine() {
            stack.removeAll(keepingCapacity: true)
            isUserLine = false
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

        func isUnderImageObject() -> Bool {
            for c in stack {
                if case let .object(frame) = c, frame.isImage { return true }
            }
            return false
        }

        func finishStringToken(endOffsetExclusive: UInt64) {
            guard let objIndex = currentObjectIndexInStack() else {
                // In arrays or invalid JSON: we don't care about value strings.
                return
            }

            switch stack[objIndex] {
            case .object(var frame):
                switch frame.state {
                case .expectKeyOrEnd:
                    // Shouldn't happen: key state becomes expectColon after parsing the key string.
                    break
                case .expectColon:
                    // We just parsed a key string.
                    if case .key = stringMode {
                        let key = String(bytes: smallStringBytes, encoding: .utf8) ?? ""
                        frame.currentKey = key
                    }
                    frame.state = .expectColon
                    stack[objIndex] = .object(frame)
                case .expectValue:
                    // Value string for currentKey.
                    let key = frame.currentKey ?? ""
                    let value: String? = {
                        switch stringMode {
                        case .valueSmall:
                            return String(bytes: smallStringBytes, encoding: .utf8)
                        case .valueLarge:
                            return nil
                        default:
                            return nil
                        }
                    }()

                    if key == "role" {
                        if let v = value?.lowercased(), v == "user" || v == "human" {
                            isUserLine = true
                        }
                    }

                    // Top-level type can indicate a user line in some formats.
                    if key == "type", stack.count == 1 {
                        if let v = value?.lowercased() {
                            let userTypes: Set<String> = ["user", "user_input", "user-input", "input", "prompt", "human"]
                            if userTypes.contains(v) { isUserLine = true }
                        }
                    }

                    if key == "type" {
                        if let v = value?.lowercased() {
                            if v == "image" {
                                frame.isImage = true
                            } else if v == "base64" {
                                frame.isBase64Source = true
                            }
                        }
                    }

                    if key == "media_type" {
                        if let v = value, !v.isEmpty {
                            frame.mediaType = v
                        }
                    }

                    if key == "data" {
                        // Base64 payload string (potentially very large). Only record if:
                        // - This line is a user message
                        // - We're inside a base64 source object under an image object
                        if isUserLine, frame.isBase64Source, isUnderImageObject(), !largeStringInvalid {
                            let start = stringContentStartOffset
                            let end = endOffsetExclusive
                            let length = max(0, largeStringLength)
                            if length > 0 {
                                let media = frame.mediaType ?? "image"
                                let approxBytes = max(0, (length * 3) / 4)
                                let span = Base64ImageDataURLScanner.Span(
                                    startOffset: start,
                                    endOffset: end,
                                    mediaType: media,
                                    base64PayloadOffset: start,
                                    base64PayloadLength: length,
                                    approxBytes: approxBytes
                                )
                                results.append(.init(span: span, lineIndex: lineIndex))
                            }
                        }
                    }

                    frame.currentKey = nil
                    frame.state = .expectCommaOrEnd
                    stack[objIndex] = .object(frame)
                case .expectCommaOrEnd:
                    // Stray string value; ignore.
                    break
                }
            case .array:
                break
            }
        }

        func beginStringToken(at quoteOffset: UInt64) {
            // Determine string mode based on container state.
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
                } else if key == "role" || key == "type" || key == "media_type" {
                    stringMode = .valueSmall(key: key)
                } else {
                    stringMode = .ignored
                }
            default:
                stringMode = .ignored
            }
        }

        func handleNonStringStructuralByte(_ byte: UInt8) {
            // Reset per-line state at newline boundaries (JSONL).
            if byte == 0x0A { // '\n'
                lineIndex += 1
                resetForNewLine()
                return
            }

            // Ignore whitespace.
            if byte == 0x20 || byte == 0x09 || byte == 0x0D { return } // space, tab, '\r'

            // Update stack + state.
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
                            // Base64 should not have escapes; abort this value by treating it as empty.
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
                            // Unexpected in base64; mark invalid (length=0).
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

                        // Update object state based on whether this was a key or a value string.
                        if let objIndex = currentObjectIndexInStack(), case .object(var frame) = stack[objIndex] {
                            if case .key = stringMode, frame.state == .expectKeyOrEnd {
                                let key = String(bytes: smallStringBytes, encoding: .utf8) ?? ""
                                frame.currentKey = key
                                frame.state = .expectColon
                                stack[objIndex] = .object(frame)
                            } else if case .valueSmall = stringMode, frame.state == .expectValue {
                                finishStringToken(endOffsetExclusive: pos)
                            } else if case .valueLarge = stringMode, frame.state == .expectValue {
                                // Base64 data string value: we counted its length.
                                finishStringToken(endOffsetExclusive: pos)
                            }
                        }

                        continue
                    }

                    // Content byte
                    switch stringMode {
                    case .key, .valueSmall:
                        // Bound the amount of buffered content for safety.
                        if smallStringBytes.count < 512 {
                            smallStringBytes.append(byte)
                        }
                    case .valueLarge:
                        // Base64 string length only.
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

        return results
    }
}
