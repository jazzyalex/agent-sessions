import Foundation

final class JSONLReader {
    private let url: URL
    private let chunkSize: Int

    init(url: URL, chunkSize: Int = 64 * 1024) {
        self.url = url
        self.chunkSize = chunkSize
    }

    func readLines() throws -> [String] {
        var lines: [String] = []
        try forEachLine { line in
            lines.append(line)
        }
        return lines
    }

    func forEachLine(_ handleLine: (String) -> Void) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var buffer = Data()
        let nl = Data([0x0A]) // \n
        // Oversize-line handling
        let maxLineBytes = 8_388_608 // 8 MB
        var skippingOversizeLine = false
        var didEmitSkipStub = false
        #if DEBUG
        var chunks = 0
        var longest = 0
        var totalBytes = 0
        var totalLines = 0
        #endif
        while autoreleasepool(invoking: {
            let data = try? fh.read(upToCount: chunkSize) ?? Data()
            if let data, !data.isEmpty {
                buffer.append(data)
                #if DEBUG
                chunks += 1
                totalBytes += data.count
                #endif
                // If we're currently skipping an oversize line, keep discarding until newline
                if skippingOversizeLine {
                    if let nlRange = buffer.range(of: nl) {
                        if !didEmitSkipStub {
                            #if DEBUG
                            totalLines += 1
                            #endif
                            handleLine("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}")
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
                        #if DEBUG
                        totalLines += 1
                        #endif
                        handleLine("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}")
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
                    #if DEBUG
                    totalLines += 1
                    longest = max(longest, lineData.count)
                    #endif

                    if let line = String(data: lineData, encoding: .utf8) {
                        handleLine(line.trimmingCharacters(in: .newlines))
                    }
                    range = nlRange.upperBound..<buffer.endIndex
                }
                buffer = Data(buffer[range])
                return true
            } else {
                return false
            }
        }) {}
        if skippingOversizeLine {
            if !didEmitSkipStub {
                #if DEBUG
                totalLines += 1
                #endif
                handleLine("{\"type\":\"omitted\",\"text\":\"[Oversize line omitted]\"}")
            }
            buffer.removeAll()
        } else if !buffer.isEmpty {
            #if DEBUG
            totalLines += 1
            longest = max(longest, buffer.count)
            #endif
            if let line = String(data: buffer, encoding: .utf8) {
                handleLine(line.trimmingCharacters(in: .newlines))
            }
        }
        #if DEBUG
        let avg = totalLines > 0 ? (totalBytes / max(totalLines,1)) : 0
        print("[READER] stats path=\(url.lastPathComponent) chunks=\(chunks) longestLine=\(longest) avgChunk=\(chunkSize) avgLine=\(avg)")
        #endif
    }

    /// Strip base64 image data at the byte level (before String conversion) for maximum performance.
    /// This is 100x faster than string operations on huge lines.
    private static func sanitizeBinaryData(_ data: Data) -> Data {
        // For small data (<500KB), return as-is - string operations will be fast enough
        if data.count < 500_000 { return data }

        // For very large data (>5MB), just return a stub to avoid any processing
        if data.count > 5_000_000 {
            #if DEBUG
            print("  🚫 Skipping huge line: \(data.count) bytes (\(data.count/1_000_000)MB)")
            #endif
            let stub = "{\"type\":\"omitted\",\"text\":\"[Large event \(data.count/1_000_000)MB omitted]\"}".data(using: .utf8)!
            return stub
        }

        #if DEBUG
        print("  🔪 Sanitizing medium line: \(data.count) bytes (\(data.count/1_000)KB)")
        #endif

        // For medium data (500KB-5MB), strip base64 images at byte level
        // Pattern: "data:image/..." followed by base64 chars until quote
        let dataImageBytes: [UInt8] = [0x64, 0x61, 0x74, 0x61, 0x3A, 0x69, 0x6D, 0x61, 0x67, 0x65] // "data:image"
        let quoteBytes: UInt8 = 0x22 // "

        var result = Data()
        result.reserveCapacity(data.count / 2) // Assume images are ~50% of data

        // Use withUnsafeBytes to avoid copying the entire data to array
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            let count = bytes.count

            var i = 0
            while i < count {
                // Check if we're at "data:image"
                if i + dataImageBytes.count < count {
                    var match = true
                    for j in 0..<dataImageBytes.count {
                        if ptr[i + j] != dataImageBytes[j] {
                            match = false
                            break
                        }
                    }

                    if match {
                        // Found "data:image" - skip until next quote
                        result.append(contentsOf: [0x5B, 0x49, 0x4D, 0x47, 0x5D]) // "[IMG]"
                        i += dataImageBytes.count

                        // Scan forward to find closing quote
                        while i < count && ptr[i] != quoteBytes {
                            i += 1
                        }
                        continue
                    }
                }

                // Not a match, copy byte as-is
                result.append(ptr[i])
                i += 1
            }
        }

        return result
    }
}
