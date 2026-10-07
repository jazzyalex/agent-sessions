import Foundation

/// Reads one immutable DSH generation without recovering a partial tail.
/// Physical sequences are zero-based and dense, matching the pinned codecs:
/// the first event carries `seq` 0 and every later row continues without gaps.
/// Released v0/v1 packed assistant rows (`text-chunks`, `reasoning-chunks`,
/// `tool-call-chunks`) occupy one sequence position per member and are
/// preserved as runs for the normalizer to fold exactly once.
enum DeepSeekHarnessArtifactReader {
    static let maxBytes = 128 * 1024 * 1024
    static let maxRecords = 1_000_000
    private static let maxHeaderBytes = 1 * 1024 * 1024
#if DEBUG
    static var testReadChunkObserver: (() -> Void)?
    static var testBeforeReadOpenObserver: (() -> Void)?
    static var testAfterReadOpenObserver: (() -> Void)?
#endif

    static func read(url: URL, compression: DeepSeekHarnessCompression) throws -> DeepSeekHarnessParseResult {
        var lastData: Data?
        for attempt in 0..<2 {
            guard !Task.isCancelled else { throw CancellationError() }
            let before = try stat(url)
            guard before.size >= 0, before.size <= Int64(maxBytes) else {
                throw DeepSeekHarnessFormatError.limitsExceeded("artifact bytes")
            }
            do {
                let data = try readAll(url: url, expectedStat: before)
                let after = try stat(url)
                if before != after {
                    if attempt == 0 { continue }
                    throw DeepSeekHarnessFormatError.staleAnchor
                }
                lastData = data
                break
            } catch let error as DeepSeekHarnessFormatError {
                if case .staleAnchor = error, attempt == 0 { continue }
                throw error
            }
        }
        guard let bytes = lastData else { throw DeepSeekHarnessFormatError.staleAnchor }

        switch compression {
        case .plain:
            return try parsePlain(bytes)
        case .zstd:
            return try parseZstd(bytes)
        }
    }

    static func readHeader(url: URL, compression: DeepSeekHarnessCompression) throws -> DeepSeekHarnessHeader {
        for attempt in 0..<2 {
            try checkCancellation()
            let before = try stat(url)
            guard before.size >= 0, before.size <= Int64(maxBytes) else {
                throw DeepSeekHarnessFormatError.limitsExceeded("artifact bytes")
            }

            do {
                let handle = try openReadHandle(url: url)
                defer { try? handle.close() }
                let descriptor = handle.fileDescriptor
                guard SessionFileStat.precise(fromFileDescriptor: descriptor) == before else {
                    throw DeepSeekHarnessFormatError.staleAnchor
                }
                let headerData: Data
                switch compression {
                case .plain:
                    headerData = try readFirstLine(from: handle)
                case .zstd:
                    let frame = try DeepSeekHarnessZstdFrameReader.readFirstFrame(
                        from: handle, decodedByteLimit: maxHeaderBytes + 1)
                    let records = try splitLines(frame.decoded, requireSingleHeaderFrame: true,
                                                 maxRecords: 1)
                    guard let record = records.first else {
                        throw DeepSeekHarnessFormatError.invalidHeader
                    }
                    headerData = record.data
                }
                let (header, _) = try decodeHeader(headerData, offset: 0)
                guard SessionFileStat.precise(fromFileDescriptor: descriptor) == before,
                      try stat(url) == before else {
                    throw DeepSeekHarnessFormatError.staleAnchor
                }
                return header
            } catch let error as DeepSeekHarnessFormatError {
                if case .staleAnchor = error, attempt == 0 { continue }
                throw error
            }
        }
        throw DeepSeekHarnessFormatError.staleAnchor
    }

    private static func parsePlain(_ bytes: Data) throws -> DeepSeekHarnessParseResult {
        let records = try splitLines(bytes, requireSingleHeaderFrame: false,
                                     maxRecords: maxRecords + 1)
        guard let first = records.first else { throw DeepSeekHarnessFormatError.invalidHeader }
        let (header, physicalCut) = try decodeHeader(first.data, offset: first.offset)
        let rows = try decodeRows(Array(records.dropFirst()), version: header.version)
        return try assemble(header: header, rows: rows, physicalCut: physicalCut)
    }

    private static func parseZstd(_ bytes: Data) throws -> DeepSeekHarnessParseResult {
        let frames = try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)
        guard let firstFrame = frames.first else { throw DeepSeekHarnessFormatError.invalidHeader }
        let firstLines = try splitLines(firstFrame.decoded, requireSingleHeaderFrame: true,
                                        maxRecords: 1)
        guard firstLines.count == 1 else { throw DeepSeekHarnessFormatError.firstFrameHeaderViolation }
        let (header, physicalCut) = try decodeHeader(firstLines[0].data, offset: firstLines[0].offset)
        var rawRecords: [Record] = []
        var remainingRecords = maxRecords
        for frame in frames.dropFirst() {
            try checkCancellation()
            let records = try splitLines(frame.decoded, requireSingleHeaderFrame: false,
                                         maxRecords: remainingRecords)
            remainingRecords -= records.count
            for record in records {
                try checkCancellation()
                rawRecords.append(Record(data: record.data,
                                         offset: frame.compressedOffset + record.offset))
            }
        }
        let rows = try decodeRows(rawRecords, version: header.version)
        return try assemble(header: header, rows: rows, physicalCut: physicalCut)
    }

    /// Decodes physical rows with zero-based dense sequence enforcement.
    /// Packed runs are admitted only for v0/v1; later generations embed
    /// assistant streams inside `assistant/message` and `assistant/attempt`.
    static func decodeRows(_ records: [Record], version: Int) throws -> [DeepSeekHarnessPhysicalRow] {
        var rows: [DeepSeekHarnessPhysicalRow] = []
        var expected = 0
        var expandedCount = 0
        for record in records {
            try checkCancellation()
            guard expandedCount < maxRecords else {
                throw DeepSeekHarnessFormatError.limitsExceeded("JSONL records")
            }
            let object = try decodeObject(record.data, offset: record.offset)
            if let type = object["type"] as? String,
               DeepSeekHarnessVocabulary.packedTypes.contains(type) {
                guard version <= 1 else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "packed \(type) row is not a released v\(version) shape")
                }
                let run = try DeepSeekHarnessPackedRun.decode(object)
                guard run.firstSeq == expected else {
                    throw DeepSeekHarnessFormatError.sequence(expected: expected, actual: run.firstSeq)
                }
                guard run.eventCount <= maxRecords - expandedCount else {
                    throw DeepSeekHarnessFormatError.limitsExceeded("JSONL records")
                }
                expected += run.eventCount
                expandedCount += run.eventCount
                rows.append(.packed(run))
                continue
            }
            let envelope = try DeepSeekHarnessEnvelope.decode(object)
            guard envelope.sequence == expected else {
                throw DeepSeekHarnessFormatError.sequence(expected: expected, actual: envelope.sequence)
            }
            expected += 1
            expandedCount += 1
            rows.append(.event(envelope))
        }
        return rows
    }

    private static func assemble(header: DeepSeekHarnessHeader, rows: [DeepSeekHarnessPhysicalRow],
                                 physicalCut: Int?) throws -> DeepSeekHarnessParseResult {
        var envelopes: [DeepSeekHarnessEnvelope] = []
        envelopes.reserveCapacity(rows.count)
        var skipped: [DeepSeekHarnessIgnorableDiagnostic] = []
        var logicalEventCount = 0
        for row in rows {
            try checkCancellation()
            switch row {
            case .event(let envelope):
                envelopes.append(envelope)
                if envelope.ignorable {
                    skipped.append(DeepSeekHarnessIgnorableDiagnostic(
                        type: envelope.type, sequence: envelope.sequence))
                }
                logicalEventCount += 1
            case .packed(let run):
                logicalEventCount += run.eventCount
            }
        }
        let cut: Int
        if let physicalCut {
            if !header.isSeeded && physicalCut != 0 {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            if physicalCut > logicalEventCount {
                throw DeepSeekHarnessFormatError.invalidHeader
            }
            cut = physicalCut
        } else {
            var lastMarker: Int?
            for envelope in envelopes {
                try checkCancellation()
                guard envelope.type == "session/end-seed" else { continue }
                if (envelope.data["inherited"] as? Bool) == true {
                    lastMarker = envelope.sequence
                } else if envelope.data["inherited"] != nil {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "session/end-seed \(envelope.sequence) inherited must be true when present")
                }
            }
            if header.isSeeded {
                guard let marker = lastMarker else {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "seeded session lacks an inherited end-seed marker")
                }
                cut = marker
            } else {
                if lastMarker != nil {
                    throw DeepSeekHarnessFormatError.invalidPayload(
                        "unseeded session contains an inherited end-seed marker")
                }
                cut = 0
            }
        }
        return DeepSeekHarnessParseResult(header: header, rows: rows,
                                          inheritedEventCount: cut,
                                          skippedIgnorableEvents: skipped,
                                          incompleteTurn: try hasOpenTurn(envelopes))
    }

    struct Record {
        let data: Data
        let offset: Int

        init(data: Data, offset: Int) {
            self.data = data
            self.offset = offset
        }
    }

    private static func splitLines(_ data: Data, requireSingleHeaderFrame: Bool,
                                   maxRecords: Int? = nil) throws -> [Record] {
        guard !data.isEmpty else { return [] }
        var records: [Record] = []
        var lineStart = 0
        var bytesSinceCancellationCheck = 0
        for index in data.indices {
            bytesSinceCancellationCheck += 1
            if bytesSinceCancellationCheck >= 65_536 {
                try checkCancellation()
                bytesSinceCancellationCheck = 0
            }
            guard data[index] == 0x0A else { continue }
            let line = data[lineStart..<index]
            guard !line.isEmpty else { throw DeepSeekHarnessFormatError.invalidJSON(offset: lineStart) }
            if requireSingleHeaderFrame, !records.isEmpty {
                throw DeepSeekHarnessFormatError.firstFrameHeaderViolation
            }
            if let maxRecords, records.count >= maxRecords {
                throw DeepSeekHarnessFormatError.limitsExceeded("JSONL records")
            }
            records.append(Record(data: Data(line), offset: lineStart))
            lineStart = index + 1
        }
        guard lineStart == data.count else {
            throw DeepSeekHarnessFormatError.tornLine(offset: lineStart)
        }
        if requireSingleHeaderFrame && records.count != 1 {
            throw DeepSeekHarnessFormatError.firstFrameHeaderViolation
        }
        return records
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private static func readAll(url: URL, expectedStat: SessionFileStat) throws -> Data {
        let handle = try openReadHandle(url: url)
        defer { try? handle.close() }
        let descriptor = handle.fileDescriptor
        guard SessionFileStat.precise(fromFileDescriptor: descriptor) == expectedStat else {
            throw DeepSeekHarnessFormatError.staleAnchor
        }
        var data = Data(capacity: min(Int(expectedStat.size), maxBytes))
        var bytesRead = 0
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            guard bytesRead <= maxBytes else {
                throw DeepSeekHarnessFormatError.limitsExceeded("artifact bytes")
            }
            data.append(chunk)
#if DEBUG
            testReadChunkObserver?()
#endif
        }
        guard SessionFileStat.precise(fromFileDescriptor: descriptor) == expectedStat else {
            throw DeepSeekHarnessFormatError.staleAnchor
        }
        return data
    }

    private static func readFirstLine(from handle: FileHandle) throws -> Data {
        var line = Data()
        while true {
            try checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty {
                throw DeepSeekHarnessFormatError.tornLine(offset: line.count)
            }
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk.prefix(upTo: newline))
                guard !line.isEmpty else {
                    throw DeepSeekHarnessFormatError.invalidJSON(offset: 0)
                }
                guard line.count <= maxHeaderBytes else {
                    throw DeepSeekHarnessFormatError.limitsExceeded("header bytes")
                }
                return line
            }
            line.append(chunk)
            guard line.count <= maxHeaderBytes else {
                throw DeepSeekHarnessFormatError.limitsExceeded("header bytes")
            }
        }
    }

    private static func openReadHandle(url: URL) throws -> FileHandle {
#if DEBUG
        testBeforeReadOpenObserver?()
#endif
        let handle = try FileHandle(forReadingFrom: url)
#if DEBUG
        testAfterReadOpenObserver?()
#endif
        return handle
    }

    private static func decodeHeader(_ data: Data, offset: Int) throws -> (DeepSeekHarnessHeader, Int?) {
        guard data.count <= maxHeaderBytes else {
            throw DeepSeekHarnessFormatError.limitsExceeded("header bytes")
        }
        let object = try decodeObject(data, offset: offset)
        return try DeepSeekHarnessHeader.decodePhysical(object)
    }

    private static func decodeObject(_ data: Data, offset: Int) throws -> [String: Any] {
        guard let string = String(data: data, encoding: .utf8) else {
            throw DeepSeekHarnessFormatError.invalidUTF8(offset: offset)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8), options: []),
              let dictionary = object as? [String: Any] else {
            throw DeepSeekHarnessFormatError.invalidJSON(offset: offset)
        }
        return dictionary
    }

    private static func stat(_ url: URL) throws -> SessionFileStat {
        guard let stat = SessionFileStat.precise(from: url) else {
            throw DeepSeekHarnessFormatError.staleAnchor
        }
        return stat
    }

    private static func hasOpenTurn(_ envelopes: [DeepSeekHarnessEnvelope]) throws -> Bool {
        var depth = 0
        for envelope in envelopes {
            try checkCancellation()
            if envelope.type == "turn/start" { depth += 1 }
            if envelope.type == "turn/end" { depth = max(0, depth - 1) }
        }
        return depth > 0
    }
}
