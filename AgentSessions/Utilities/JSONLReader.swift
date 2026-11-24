import Foundation

final class JSONLReader {
    private enum ReadError: Error { case incompletePrefix }
    private let url: URL
    private let chunkSize: Int
    private let maximumBytes: UInt64?
    private let propagatesReadErrors: Bool
    private let readChunk: ((FileHandle, Int) throws -> Data)?

    init(url: URL,
         chunkSize: Int = 64 * 1024,
         maximumBytes: UInt64? = nil,
         propagatesReadErrors: Bool = false,
         readChunk: ((FileHandle, Int) throws -> Data)? = nil) {
        self.url = url
        self.chunkSize = chunkSize
        self.maximumBytes = maximumBytes
        self.propagatesReadErrors = propagatesReadErrors
        self.readChunk = readChunk
    }

    func readLines() throws -> [String] {
        var lines: [String] = []
        try forEachLine { line in
            lines.append(line)
        }
        return lines
    }

    func forEachLine(_ handleLine: (String) -> Void) throws {
        _ = try forEachLineCore({ line in
            handleLine(line)
            return true
        }, reportBytesRead: nil)
    }

    /// Also reports 0-based physical line indexes, including gaps for blank
    /// or invalid UTF-8 records, without changing the regular event numbering.
    func forEachLocatedLine(requireCompletePrefix: Bool,
                            reportLineCount: @escaping (Int) -> Void,
                            _ handleLine: (String, Int) -> Void) throws {
        var index = 0
        _ = try forEachLineCore({ line in
            handleLine(line, index)
            return true
        }, reportBytesRead: nil, reportSourceLine: { index = $0 },
           reportLineCount: reportLineCount, requireCompletePrefix: requireCompletePrefix)
    }

    /// Read from a caller-owned descriptor. The descriptor stays open and is
    /// positioned by this reader; callers can therefore capture descriptor
    /// metadata before and after the exact bytes consumed by the parser.
    func forEachLine(using fileHandle: FileHandle,
                     _ handleLine: (String) -> Void) throws {
        _ = try forEachLineCore({ line in
            handleLine(line)
            return true
        }, reportBytesRead: nil, fileHandle: fileHandle)
    }

    /// Streaming line reader that can stop early by returning `false`.
    /// Useful for lightweight preview scans without reading the full file.
    @discardableResult
    func forEachLineWhile(_ shouldContinue: (String) -> Bool) throws -> Bool {
        try forEachLineCore(shouldContinue, reportBytesRead: nil)
    }

    /// Streaming line reader using a caller-owned descriptor. The caller can
    /// capture descriptor metadata before and after a bounded preview scan.
    @discardableResult
    func forEachLineWhile(using fileHandle: FileHandle,
                          _ shouldContinue: (String) -> Bool) throws -> Bool {
        try forEachLineCore(
            shouldContinue,
            reportBytesRead: nil,
            fileHandle: fileHandle)
    }

    /// Streaming line reader using a caller-owned descriptor and reporting the
    /// exact physical bytes consumed from that descriptor.
    @discardableResult
    func forEachLineWhile(using fileHandle: FileHandle,
                          _ shouldContinue: (String) -> Bool,
                          reportBytesRead: @escaping (UInt64) -> Void,
                          reportMalformedLine: (() -> Void)? = nil) throws -> Bool {
        try forEachLineCore(
            shouldContinue,
            reportBytesRead: reportBytesRead,
            reportMalformedLine: reportMalformedLine,
            fileHandle: fileHandle)
    }

    /// Streaming line reader with the number of physical bytes consumed by the
    /// bounded read. The callback runs once on every exit path, including a
    /// reader error or an early stop.
    @discardableResult
    func forEachLineWhile(_ shouldContinue: (String) -> Bool,
                          reportBytesRead: @escaping (UInt64) -> Void,
                          reportMalformedLine: (() -> Void)? = nil) throws -> Bool {
        try forEachLineCore(shouldContinue,
                            reportBytesRead: reportBytesRead,
                            reportMalformedLine: reportMalformedLine)
    }

    // Core implementation shared by both APIs.
    @discardableResult
    private func forEachLineCore(_ shouldContinue: (String) -> Bool,
                                 reportBytesRead: ((UInt64) -> Void)?,
                                 reportMalformedLine: (() -> Void)? = nil,
                                 reportSourceLine: ((Int) -> Void)? = nil,
                                 reportLineCount: ((Int) -> Void)? = nil,
                                 requireCompletePrefix: Bool = false,
                                 fileHandle: FileHandle? = nil) throws -> Bool {
        let fh: FileHandle
        let ownsFileHandle: Bool
        if let fileHandle {
            fh = fileHandle
            ownsFileHandle = false
        } else {
            fh = try FileHandle(forReadingFrom: url)
            ownsFileHandle = true
        }
        defer {
            if ownsFileHandle {
                try? fh.close()
            }
        }
        var buffer = Data()
        let nl = Data([0x0A]) // \n
        var stoppedEarly = false
        // Oversize-line handling
        let maxLineBytes = 8_388_608 // 8 MB
        var skippingOversizeLine = false
        var didEmitSkipStub = false
        var bytesRead: UInt64 = 0
        var sourceLine = 0
        var lastByte: UInt8?
        defer {
            reportBytesRead?(bytesRead)
            reportLineCount?(sourceLine)
        }
        func emit(_ line: String, at index: Int) -> Bool {
            reportSourceLine?(index)
            return shouldContinue(line)
        }
        var readError: Error?
        while autoreleasepool(invoking: {
            let requestedCount: Int
            if let maximumBytes {
                guard bytesRead < maximumBytes else { return false }
                requestedCount = Int(min(UInt64(chunkSize), maximumBytes - bytesRead))
            } else {
                requestedCount = chunkSize
            }
            let data: Data
            do {
                if let readChunk {
                    data = try readChunk(fh, requestedCount)
                } else {
                    data = try fh.read(upToCount: requestedCount) ?? Data()
                }
            } catch {
                if propagatesReadErrors { readError = error }
                return false
            }
            if !data.isEmpty {
                bytesRead += UInt64(data.count)
                lastByte = data.last
                // The buffered prefix was already searched for a newline on
                // the previous read. Long records only need to scan new bytes.
                var searchStart = buffer.endIndex
                buffer.append(data)
                // If we're currently skipping an oversize line, keep discarding until newline
                if skippingOversizeLine {
                    if let nlRange = buffer.range(of: nl, in: searchStart..<buffer.endIndex) {
                        if !didEmitSkipStub {
                            if !emit("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}", at: sourceLine) {
                                stoppedEarly = true
                                return false
                            }
                            didEmitSkipStub = true
                        }
                        sourceLine += 1
                        buffer = Data(buffer[nlRange.upperBound..<buffer.endIndex])
                        searchStart = buffer.startIndex
                        skippingOversizeLine = false
                        didEmitSkipStub = false
                    } else {
                        buffer.removeAll()
                        return true
                    }
                }
                // Skip records that exceed the line-size limit.
                if !skippingOversizeLine && buffer.count > maxLineBytes {
                    if let nlRange = buffer.range(of: nl, in: searchStart..<buffer.endIndex) {
                        if !emit("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}", at: sourceLine) {
                            stoppedEarly = true
                            return false
                        }
                        sourceLine += 1
                        buffer = Data(buffer[nlRange.upperBound..<buffer.endIndex])
                        searchStart = buffer.startIndex
                    } else {
                        skippingOversizeLine = true
                        didEmitSkipStub = false
                        buffer.removeAll()
                        return true
                    }
                }

                var lineStart = buffer.startIndex
                while let nlRange = buffer.range(of: nl, in: searchStart..<buffer.endIndex) {
                    let index = sourceLine
                    sourceLine += 1
                    let lineData = buffer.subdata(in: lineStart..<nlRange.lowerBound)
                    lineStart = nlRange.upperBound
                    searchStart = lineStart

                    if let line = String(data: lineData, encoding: .utf8) {
                        let trimmed = line.trimmingCharacters(in: .newlines)
                        if !trimmed.isEmpty, !emit(trimmed, at: index) {
                            stoppedEarly = true
                            return false
                        }
                    } else {
                        reportMalformedLine?()
                    }
                }
                if lineStart != buffer.startIndex {
                    buffer = Data(buffer[lineStart..<buffer.endIndex])
                }
                return true
            } else {
                return false
            }
        }) {}
        if let readError { throw readError }
        if stoppedEarly { return false }
        if requireCompletePrefix, bytesRead != maximumBytes || lastByte != 0x0A {
            throw ReadError.incompletePrefix
        }
        if skippingOversizeLine {
            if !didEmitSkipStub {
                _ = emit("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}", at: sourceLine)
            }
            buffer.removeAll()
        } else if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    _ = emit(trimmed, at: sourceLine)
                }
            } else {
                reportMalformedLine?()
            }
        }
        return true
    }
}
