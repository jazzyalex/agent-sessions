import Foundation

final class JSONLReader {
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
        defer { reportBytesRead?(bytesRead) }
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
                buffer.append(data)
                // If we're currently skipping an oversize line, keep discarding until newline
                if skippingOversizeLine {
                    if let nlRange = buffer.range(of: nl) {
                        if !didEmitSkipStub {
                            if !shouldContinue("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}") {
                                stoppedEarly = true
                                return false
                            }
                            didEmitSkipStub = true
                        }
                        buffer = Data(buffer[nlRange.upperBound..<buffer.endIndex])
                        skippingOversizeLine = false
                        didEmitSkipStub = false
                    } else {
                        buffer.removeAll()
                        return true
                    }
                }
                // Safety check: if buffer is getting huge (>10MB) without finding newline, skip ahead
                if !skippingOversizeLine && buffer.count > maxLineBytes {
                    if let nlRange = buffer.range(of: nl) {
                        if !shouldContinue("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}") {
                            stoppedEarly = true
                            return false
                        }
                        buffer = Data(buffer[nlRange.upperBound..<buffer.endIndex])
                    } else {
                        skippingOversizeLine = true
                        didEmitSkipStub = false
                        buffer.removeAll()
                        return true
                    }
                }

                var range = buffer.startIndex..<buffer.endIndex
                while let nlRange = buffer.range(of: Data([0x0A]), options: [], in: range) { // \n
                    let lineData = buffer.subdata(in: range.lowerBound..<nlRange.lowerBound)

                    if let line = String(data: lineData, encoding: .utf8) {
                        let trimmed = line.trimmingCharacters(in: .newlines)
                        if trimmed.isEmpty {
                            range = nlRange.upperBound..<buffer.endIndex
                            continue
                        }
                        if !shouldContinue(trimmed) {
                            stoppedEarly = true
                            return false
                        }
                    } else {
                        reportMalformedLine?()
                    }
                    range = nlRange.upperBound..<buffer.endIndex
                }
                buffer = Data(buffer[range])
                return true
            } else {
                return false
            }
        }) {}
        if let readError { throw readError }
        if stoppedEarly { return false }
        if skippingOversizeLine {
            if !didEmitSkipStub {
                _ = shouldContinue("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}")
            }
            buffer.removeAll()
        } else if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    _ = shouldContinue(trimmed)
                }
            } else {
                reportMalformedLine?()
            }
        }
        return true
    }
}
