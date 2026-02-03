import Foundation

/// Streaming scanner for Gemini session JSON files that contain inline base64 images under `inlineData`.
///
/// Observed shape (nested anywhere within a message item):
/// `{ "inlineData": { "data": "<base64>", "mimeType": "image/png" } }`
enum GeminiInlineDataImageScanner {
    struct LocatedSpan: Identifiable, Hashable, Sendable {
        let itemIndex: Int
        let span: Base64ImageDataURLScanner.Span
        var id: String { "\(itemIndex)-\(span.id)" }
    }

    static func fileContainsInlineDataImage(at url: URL, shouldCancel: () -> Bool = { false }) -> Bool {
        do {
            return try scanInternal(at: url, maxMatches: 1, shouldCancel: shouldCancel).isEmpty == false
        } catch {
            return false
        }
    }

    static func scanFile(at url: URL, maxMatches: Int = 200, shouldCancel: () -> Bool = { false }) throws -> [LocatedSpan] {
        try scanInternal(at: url, maxMatches: maxMatches, shouldCancel: shouldCancel)
    }
}

private extension GeminiInlineDataImageScanner {
    enum Container {
        case object(ObjectFrame)
        case array(ArrayFrame)
    }

    struct ObjectFrame {
        enum State {
            case expectKeyOrEnd
            case expectValue
            case expectCommaOrEnd
        }

        var state: State = .expectKeyOrEnd
        var currentKey: String? = nil

        var messageIndex: Int? = nil

        // inlineData state
        var isInlineDataObject: Bool = false
        var inlineMimeType: String? = nil
    }

    struct ArrayFrame {
        enum State {
            case expectValueOrEnd
            case expectCommaOrEnd
        }

        var state: State = .expectValueOrEnd
        var isMessagesArray: Bool = false
        var messageIndex: Int? = nil
    }

    enum StringMode {
        case ignored
        case key
        case valueSmall(key: String)
        case valueLargeData
    }

    static func scanInternal(at url: URL, maxMatches: Int, shouldCancel: () -> Bool) throws -> [LocatedSpan] {
        guard maxMatches > 0 else { return [] }

        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        let chunkSize = 64 * 1024
        var fileOffset: UInt64 = 0

        var stack: [Container] = []
        stack.reserveCapacity(16)

        // Messages array tracking (for itemIndex mapping)
        var messagesArrayStackIndex: Int? = nil
        var nextMessageIndex: Int = 0

        // String parsing
        var inString = false
        var stringEscaped = false
        var stringMode: StringMode = .ignored
        var smallStringBytes: [UInt8] = []
        smallStringBytes.reserveCapacity(64)

        var largeStringContentStartOffset: UInt64 = 0
        var largeStringLength: Int = 0
        var largeStringInvalid = false

        func shouldCaptureSmallString(mode: StringMode) -> Bool {
            switch mode {
            case .key, .valueSmall:
                return true
            case .ignored, .valueLargeData:
                return false
            }
        }

        func activeMessageIndex() -> Int? {
            for c in stack.reversed() {
                switch c {
                case let .object(f):
                    if let mi = f.messageIndex { return mi }
                case let .array(f):
                    if let mi = f.messageIndex { return mi }
                }
            }
            return nil
        }

        func currentObjectIndexInStack() -> Int? {
            for i in stride(from: stack.count - 1, through: 0, by: -1) {
                if case .object = stack[i] { return i }
            }
            return nil
        }

        func setTopObject(_ frame: ObjectFrame) {
            guard let idx = currentObjectIndexInStack() else { return }
            stack[idx] = .object(frame)
        }

        func topObject() -> ObjectFrame? {
            guard let idx = currentObjectIndexInStack() else { return nil }
            if case let .object(frame) = stack[idx] { return frame }
            return nil
        }

        func topArrayIndex() -> Int? {
            for i in stride(from: stack.count - 1, through: 0, by: -1) {
                if case .array = stack[i] { return i }
            }
            return nil
        }

        func setTopArray(_ frame: ArrayFrame) {
            guard let idx = topArrayIndex() else { return }
            stack[idx] = .array(frame)
        }

        func topArray() -> ArrayFrame? {
            guard let idx = topArrayIndex() else { return nil }
            if case let .array(frame) = stack[idx] { return frame }
            return nil
        }

        func beginStringToken(at quoteOffset: UInt64) {
            inString = true
            stringEscaped = false
            smallStringBytes.removeAll(keepingCapacity: true)
            largeStringLength = 0
            largeStringInvalid = false
            largeStringContentStartOffset = quoteOffset &+ 1

            guard let objIndex = currentObjectIndexInStack(),
                  case let .object(frame) = stack[objIndex] else {
                stringMode = .ignored
                return
            }

            switch frame.state {
            case .expectKeyOrEnd:
                stringMode = .key
            case .expectValue:
                let key = frame.currentKey ?? ""
                if frame.isInlineDataObject && key == "data" {
                    stringMode = .valueLargeData
                } else if frame.isInlineDataObject && key == "mimeType" {
                    stringMode = .valueSmall(key: key)
                } else if key == "messages" || key == "history" || key == "items" || key == "inlineData" {
                    stringMode = .valueSmall(key: key)
                } else {
                    stringMode = .ignored
                }
            case .expectCommaOrEnd:
                stringMode = .ignored
            }
        }

        func finishStringToken(at endQuoteOffset: UInt64) {
            inString = false
            defer { stringMode = .ignored }

            func decodeSmallString() -> String? {
                guard !smallStringBytes.isEmpty else { return "" }
                return String(bytes: smallStringBytes, encoding: .utf8)
            }

            switch stringMode {
            case .key:
                guard let key = decodeSmallString() else { return }
                guard var obj = topObject() else { return }
                obj.currentKey = key
                obj.state = .expectValue
                setTopObject(obj)

            case let .valueSmall(key: keyName):
                guard let value = decodeSmallString() else { return }
                guard var obj = topObject() else { return }
                if obj.state == .expectValue {
                    if obj.isInlineDataObject, keyName == "mimeType" {
                        obj.inlineMimeType = value
                    }
                    obj.currentKey = nil
                    obj.state = .expectCommaOrEnd
                    setTopObject(obj)
                }

            case .valueLargeData:
                guard var obj = topObject(), obj.isInlineDataObject else { return }
                guard !largeStringInvalid else { return }
                let length = max(0, largeStringLength)
                guard length > 0 else { return }
                let mime = (obj.inlineMimeType ?? "image").trimmingCharacters(in: .whitespacesAndNewlines)
                guard mime.hasPrefix("image/") else {
                    obj.currentKey = nil
                    obj.state = .expectCommaOrEnd
                    setTopObject(obj)
                    return
                }

                let start = largeStringContentStartOffset
                let endExclusive = endQuoteOffset
                let approxBytes = max(0, (length * 3) / 4)
                let span = Base64ImageDataURLScanner.Span(
                    startOffset: start,
                    endOffset: endExclusive,
                    mediaType: mime,
                    base64PayloadOffset: start,
                    base64PayloadLength: length,
                    approxBytes: approxBytes
                )
                // 1-based to match GeminiSessionParser's `sid-0001` style event IDs.
                let idx = (activeMessageIndex() ?? 0) + 1
                // Mark object state advanced
                obj.currentKey = nil
                obj.state = .expectCommaOrEnd
                setTopObject(obj)

                // Append to results
                results.append(LocatedSpan(itemIndex: idx, span: span))

            case .ignored:
                break
            }
        }

        func advanceContainerStateForScalarValue() {
            // When an object expects a value and we see a scalar (number/bool/null), mark it consumed.
            if let objIndex = currentObjectIndexInStack(), case .object(var obj) = stack[objIndex], obj.state == .expectValue {
                obj.state = .expectCommaOrEnd
                obj.currentKey = nil
                stack[objIndex] = .object(obj)
            } else if let arrIndex = topArrayIndex(), case .array(var arr) = stack[arrIndex], arr.state == .expectValueOrEnd {
                arr.state = .expectCommaOrEnd
                stack[arrIndex] = .array(arr)
            }
        }

        var results: [LocatedSpan] = []
        results.reserveCapacity(min(maxMatches, 16))

        while true {
            if shouldCancel() { break }
            let chunk = try fh.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            for (i, byte) in chunk.enumerated() {
                if shouldCancel() { return results }
                let pos = fileOffset &+ UInt64(i)

                if inString {
                    if stringEscaped {
                        // Treat any escaped byte as content (we don't decode escapes for large strings).
                        stringEscaped = false
                        if case .valueLargeData = stringMode {
                            // escaped content still counts
                            largeStringLength += 1
                        } else if shouldCaptureSmallString(mode: stringMode) {
                            if smallStringBytes.count < 256 { smallStringBytes.append(byte) }
                        }
                        continue
                    }

                    if byte == 0x5C { // '\\'
                        stringEscaped = true
                        // For large data, backslash inside base64 is invalid; mark and keep counting minimal.
                        if case .valueLargeData = stringMode { largeStringInvalid = true }
                        continue
                    }

                    if byte == 0x22 { // '"'
                        finishStringToken(at: pos)
                        continue
                    }

                    if case .valueLargeData = stringMode {
                        // Base64 should not contain whitespace; treat as invalid but still count to keep offsets stable.
                        if byte == 0x0A || byte == 0x0D || byte == 0x09 || byte == 0x20 { largeStringInvalid = true }
                        largeStringLength += 1
                    } else if shouldCaptureSmallString(mode: stringMode) {
                        if smallStringBytes.count < 256 { smallStringBytes.append(byte) }
                    }
                    continue
                }

                // Non-string structural bytes.
                if byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A { continue } // whitespace

                if byte == 0x22 { // '"'
                    beginStringToken(at: pos)
                    continue
                }

                if byte == 0x7B { // '{'
                    // Consume a pending value expectation from parent.
                    if let objIndex = currentObjectIndexInStack(), case .object(var obj) = stack[objIndex], obj.state == .expectValue {
                        // inlineData object marker
                        let isInline = obj.currentKey == "inlineData"
                        obj.state = .expectCommaOrEnd
                        obj.currentKey = nil
                        stack[objIndex] = .object(obj)

                        var child = ObjectFrame()
                        child.isInlineDataObject = isInline
                        child.messageIndex = activeMessageIndex()
                        // If this object is a direct element of the messages array, assign a new message index.
                        if let arrIndex = messagesArrayStackIndex,
                           arrIndex == stack.count - 1,
                           case .array(let arr) = stack[arrIndex],
                           arr.isMessagesArray {
                            let mi = nextMessageIndex
                            nextMessageIndex += 1
                            child.messageIndex = mi
                        }
                        stack.append(.object(child))
                    } else if let arrIndex = topArrayIndex(), case .array(var arr) = stack[arrIndex], arr.state == .expectValueOrEnd {
                        // Object inside an array
                        arr.state = .expectCommaOrEnd
                        stack[arrIndex] = .array(arr)

                        var child = ObjectFrame()
                        child.messageIndex = activeMessageIndex()
                        if let miIndex = messagesArrayStackIndex,
                           miIndex == arrIndex,
                           arr.isMessagesArray {
                            let mi = nextMessageIndex
                            nextMessageIndex += 1
                            child.messageIndex = mi
                        }
                        stack.append(.object(child))
                    } else {
                        var child = ObjectFrame()
                        child.messageIndex = activeMessageIndex()
                        stack.append(.object(child))
                    }
                    continue
                }

                if byte == 0x7D { // '}'
                    if !stack.isEmpty { _ = stack.popLast() }
                    continue
                }

                if byte == 0x5B { // '['
                    // If opening an array as the value for messages/history/items, mark it as the messages array.
                    var isMessagesArray = false
                    if let objIndex = currentObjectIndexInStack(), case .object(var obj) = stack[objIndex], obj.state == .expectValue {
                        let key = obj.currentKey ?? ""
                        if key == "messages" || key == "history" || key == "items" {
                            isMessagesArray = true
                        }
                        obj.state = .expectCommaOrEnd
                        obj.currentKey = nil
                        stack[objIndex] = .object(obj)
                    } else if let arrIndex = topArrayIndex(), case .array(var arr) = stack[arrIndex], arr.state == .expectValueOrEnd {
                        arr.state = .expectCommaOrEnd
                        stack[arrIndex] = .array(arr)
                    }

                    var frame = ArrayFrame()
                    frame.isMessagesArray = isMessagesArray
                    frame.messageIndex = activeMessageIndex()
                    stack.append(.array(frame))
                    if isMessagesArray {
                        messagesArrayStackIndex = stack.count - 1
                        nextMessageIndex = 0
                    }
                    continue
                }

                if byte == 0x5D { // ']'
                    if let last = stack.last, case let .array(arr) = last, arr.isMessagesArray {
                        messagesArrayStackIndex = nil
                    }
                    if !stack.isEmpty { _ = stack.popLast() }
                    continue
                }

                if byte == 0x2C { // ','
                    // Comma advances container state
                    if let objIndex = currentObjectIndexInStack(), case .object(var obj) = stack[objIndex], obj.state == .expectCommaOrEnd {
                        obj.state = .expectKeyOrEnd
                        stack[objIndex] = .object(obj)
                    } else if let arrIndex = topArrayIndex(), case .array(var arr) = stack[arrIndex], arr.state == .expectCommaOrEnd {
                        arr.state = .expectValueOrEnd
                        stack[arrIndex] = .array(arr)
                    }
                    continue
                }

                if byte == 0x3A { // ':'
                    // We don't need to handle ':' explicitly; key parsing sets state.
                    continue
                }

                // Scalar values: advance expectation state
                advanceContainerStateForScalarValue()
            }

            fileOffset &+= UInt64(chunk.count)
            if results.count >= maxMatches { break }
        }

        if results.count > maxMatches { results = Array(results.prefix(maxMatches)) }
        return results
    }
}
