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
}
