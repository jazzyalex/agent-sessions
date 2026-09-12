import Foundation

final class JSONLReader {
    private let url: URL
    private let chunkSize: Int
    private let maximumBytes: UInt64?
    private let propagatesReadErrors: Bool

    init(url: URL,
         chunkSize: Int = 64 * 1024,
         maximumBytes: UInt64? = nil,
         propagatesReadErrors: Bool = false) {
        self.url = url
        self.chunkSize = chunkSize
        self.maximumBytes = maximumBytes
        self.propagatesReadErrors = propagatesReadErrors
    }

    func readLines() throws -> [String] {
        var lines: [String] = []
        try forEachLine { line in
            lines.append(line)
        }
        return lines
    }

    func forEachLine(_ handleLine: (String) -> Void) throws {
        _ = try forEachLineCore { line in
            handleLine(line)
            return true
        }
    }

    /// Streaming line reader that can stop early by returning `false`.
    /// Useful for lightweight preview scans without reading the full file.
    @discardableResult
    func forEachLineWhile(_ shouldContinue: (String) -> Bool) throws -> Bool {
        try forEachLineCore(shouldContinue)
    }

    // Core implementation shared by both APIs.
    @discardableResult
    private func forEachLineCore(_ shouldContinue: (String) -> Bool) throws -> Bool {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var buffer = Data()
        let nl = Data([0x0A]) // \n
        var stoppedEarly = false
        // Oversize-line handling
        let maxLineBytes = 8_388_608 // 8 MB
        var skippingOversizeLine = false
        var didEmitSkipStub = false
        var bytesRead: UInt64 = 0
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
                data = try fh.read(upToCount: requestedCount) ?? Data()
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
            }
        }
        return true
    }
}
