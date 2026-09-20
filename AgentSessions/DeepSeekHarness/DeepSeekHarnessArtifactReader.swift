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

    static func read(url: URL, compression: DeepSeekHarnessCompression) throws -> DeepSeekHarnessParseResult {
        var lastData: Data?
        for attempt in 0..<2 {
            let before = try stat(url)
            guard before.size >= 0, before.size <= Int64(maxBytes) else {
                throw DeepSeekHarnessFormatError.limitsExceeded("artifact bytes")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maxBytes else {
                throw DeepSeekHarnessFormatError.limitsExceeded("artifact bytes")
            }
            let after = try stat(url)
            if before != after {
                if attempt == 0 { continue }
                throw DeepSeekHarnessFormatError.staleAnchor
            }
            lastData = data
            break
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
        try read(url: url, compression: compression).header
    }

    private static func parsePlain(_ bytes: Data) throws -> DeepSeekHarnessParseResult {
        let records = try splitLines(bytes, requireSingleHeaderFrame: false)
        guard let first = records.first else { throw DeepSeekHarnessFormatError.invalidHeader }
        let (header, physicalCut) = try decodeHeader(first.data, offset: first.offset)
        let rows = try decodeRows(Array(records.dropFirst()), version: header.version)
        return try assemble(header: header, rows: rows, physicalCut: physicalCut)
    }

    private static func parseZstd(_ bytes: Data) throws -> DeepSeekHarnessParseResult {
        let frames = try DeepSeekHarnessZstdFrameReader.readFrames(from: bytes)
        guard let firstFrame = frames.first else { throw DeepSeekHarnessFormatError.invalidHeader }
        let firstLines = try splitLines(firstFrame.decoded, requireSingleHeaderFrame: true)
        guard firstLines.count == 1 else { throw DeepSeekHarnessFormatError.firstFrameHeaderViolation }
        let (header, physicalCut) = try decodeHeader(firstLines[0].data, offset: firstLines[0].offset)
        var rawRecords: [Record] = []
        for frame in frames.dropFirst() {
            let records = try splitLines(frame.decoded, requireSingleHeaderFrame: false)
            for record in records {
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
        let envelopes = rows.compactMap { row -> DeepSeekHarnessEnvelope? in
            if case .event(let envelope) = row { return envelope }
            return nil
        }
        let skipped = envelopes.filter(\.ignorable).map {
            DeepSeekHarnessIgnorableDiagnostic(type: $0.type, sequence: $0.sequence)
        }
        let logicalEventCount = rows.reduce(into: 0) { count, row in
            switch row {
            case .event: count += 1
            case .packed(let run): count += run.eventCount
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
            for envelope in envelopes where envelope.type == "session/end-seed" {
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
                                          incompleteTurn: hasOpenTurn(envelopes))
    }

    struct Record {
        let data: Data
        let offset: Int

        init(data: Data, offset: Int) {
            self.data = data
            self.offset = offset
        }
    }

    private static func splitLines(_ data: Data, requireSingleHeaderFrame: Bool) throws -> [Record] {
        guard !data.isEmpty else { return [] }
        var records: [Record] = []
        var lineStart = 0
        for index in data.indices where data[index] == 0x0A {
            let line = data[lineStart..<index]
            guard !line.isEmpty else { throw DeepSeekHarnessFormatError.invalidJSON(offset: lineStart) }
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

    private static func decodeHeader(_ data: Data, offset: Int) throws -> (DeepSeekHarnessHeader, Int?) {
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
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modified = values.contentModificationDate else { throw DeepSeekHarnessFormatError.staleAnchor }
        let nanoseconds = Int64(modified.timeIntervalSince1970 * 1_000_000_000)
        return SessionFileStat(mtime: nanoseconds, size: Int64(values.fileSize ?? 0))
    }

    private static func hasOpenTurn(_ envelopes: [DeepSeekHarnessEnvelope]) -> Bool {
        var depth = 0
        for envelope in envelopes {
            if envelope.type == "turn/start" { depth += 1 }
            if envelope.type == "turn/end" { depth = max(0, depth - 1) }
        }
        return depth > 0
    }
}
