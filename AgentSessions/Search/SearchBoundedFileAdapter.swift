import Foundation
import CryptoKit
import SQLite3

extension SearchSourceScanner {
    /// Older/small providers retain their audited parser under a frozen, preflighted input
    /// budget. All participating files are copied through checked descriptors into a private
    /// temporary directory; parsers cannot race a growing original file after preflight.
    static func scanBoundedFiles(session: Session, summary: inout SearchScanSummary,
                                 metadata: ((Session) -> Void)? = nil,
                                 consume: (SearchTextSegment) throws -> Void) throws {
        if session.source == .opencode {
            try scanBoundedOpenCode(session: session, summary: &summary, metadata: metadata, consume: consume)
            return
        }
        let fileManager = FileManager.default
        let primary = URL(fileURLWithPath: session.filePath).standardizedFileURL
        let root: URL
        if session.source == .kimi {
            root = KimiSessionDiscovery.stateFile(forWireFile: primary).deletingLastPathComponent()
        } else {
            root = primary.deletingLastPathComponent()
        }
        var paths = [primary]
        var additionalDirectories: [URL] = []
        func optional(_ name: String) {
            let url = root.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { paths.append(url) }
        }
        switch session.source {
        case .cline: paths.append(ClineSessionDiscovery.messagesFile(forManifest: primary))
        case .kimi: optional("state.json")
        case .grok: optional("summary.json"); optional("meta.json")
        case .copilot: optional("workspace.yaml")
        case .fx:
            for name in ["session.json", "checkpoint.json", "authority.json", "display.json", "recovery.json", "events.jsonl"] { optional(name) }
            let artifacts = root.appendingPathComponent("tool-results")
            if let enumerator = fileManager.enumerator(at: artifacts, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    guard paths.count < 4096 else { throw Failure.resourceLimit }
                    if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { paths.append(file) }
                }
            }
        case .cursor:
            if CursorACPStoreReader.isACPStore(primary) {
                optional("meta.json"); optional("store.db-wal")
            }
        case .opencode: throw Failure.unsupported
        case .codex, .claude, .antigravity, .droid, .pi, .hermes, .qwen, .deepseekHarness: break
        default: throw Failure.unsupported
        }
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0.path).inserted }
        // Nested artifact directories participate in the source proof too: adding a
        // sibling tool-result file must invalidate the frozen snapshot.
        let directories = Set(paths.map { $0.deletingLastPathComponent() } + additionalDirectories + [root] + (session.source == .fx ? [root.appendingPathComponent("tool-results")] : []))
        let directoryProofs = directories.map { ($0, SessionFileStat.precise(from: $0)) }
        let directoryBefore = SessionFileStat.precise(from: root)
        let artifactBefore = session.source.descriptor.artifactRevision?(primary)
        if let artifactBefore, artifactBefore.selectedURL.standardizedFileURL != primary { throw Failure.changed }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("as-search-" + UUID().uuidString)
        // Preserve provider path grammar for canonical path recognizers.
        let temporary = container.appendingPathComponent(root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        var proofs: [SearchSourceRevision.File] = []
        var payloadCharge = chunkBytes * 2
        func checkJSON(_ data: Data) throws -> Int {
            let charge = try validateJSON(data)
            // Allocation bounds are checked before syntax decoding. Providers that skip a
            // malformed line may still emit other witnesses, but cannot certify absence.
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                summary.reasons.insert(.malformedRecord)
            }
            return charge
        }
        for path in paths {
            try Task.checkCancellation()
            let relative = String(path.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !relative.hasPrefix("..") else { throw Failure.unsupported }
            let handle = try FileHandle(forReadingFrom: path)
            let descriptor = handle.fileDescriptor
            defer { try? handle.close() }
            guard let before = SessionFileStat.precise(fromFileDescriptor: descriptor), before.size >= 0 else { throw Failure.changed }
            guard before.size <= recordBytes else { throw Failure.resourceLimit }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                summary.bytesRead += UInt64(chunk.count)
                guard data.count + chunk.count <= recordBytes,
                      payloadCharge + (data.count + chunk.count) * 24 <= payloadBytes else { throw Failure.resourceLimit }
                if chunk.isEmpty { break }; data.append(chunk)
            }
            guard SessionFileStat.precise(fromFileDescriptor: descriptor) == before,
                  SessionFileStat.precise(from: path) == before else { throw Failure.changed }
            proofs.append(.init(path: path.resolvingSymlinksInPath().path, stat: before))
            let target = temporary.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            let compressed = ["zstd", "zst"].contains(path.pathExtension.lowercased())
            var decoded = data
            if compressed {
                let compressedHandle = try FileHandle(forReadingFrom: target)
                defer { try? compressedHandle.close() }
                let decoder = ZstdStreamDecoder(maximumWindowLog: 23, inputChunkSize: chunkBytes)
                decoded = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = try decoder.read(from: compressedHandle, upTo: chunkBytes)
                    guard decoded.count + chunk.count <= recordBytes,
                          payloadCharge + (data.count + decoded.count + chunk.count) * 24 + 9 * 1024 * 1024 <= payloadBytes else { throw Failure.resourceLimit }
                    if chunk.isEmpty { break }; decoded.append(chunk)
                }
                payloadCharge += data.count * 24 + 9 * 1024 * 1024
            }
            summary.decompressedBytes += UInt64(decoded.count)
            let jsonl = path.lastPathComponent.contains(".jsonl")
            if jsonl {
                var start = decoded.startIndex
                for index in decoded.indices where decoded[index] == 10 {
                    if start < index {
                        payloadCharge += try checkJSON(Data(decoded[start..<index])) - chunkBytes * 2
                        summary.records += 1
                    }
                    start = decoded.index(after: index)
                }
                if start < decoded.endIndex {
                    payloadCharge += try checkJSON(Data(decoded[start...])) - chunkBytes * 2
                    summary.records += 1
                }
            } else if path.pathExtension == "json" {
                payloadCharge += try checkJSON(decoded) - chunkBytes * 2
                summary.records += 1
            } else { payloadCharge += decoded.count * 24 }
            guard payloadCharge <= payloadBytes else { throw Failure.resourceLimit }
            summary.peakPayloadCharge = max(summary.peakPayloadCharge, payloadCharge)
        }
        try Task.checkCancellation()
        let snapshot = temporary.appendingPathComponent(String(primary.path.dropFirst(root.path.count + 1)))
        if session.source == .cursor, CursorACPStoreReader.isACPStore(snapshot) {
            let input = Session(id: session.id, source: .cursor, startTime: nil, endTime: nil,
                                model: nil, filePath: snapshot.path, eventCount: 0, events: [])
            let database = try SearchSQLiteReader(session: input)
            try database.rows("SELECT value FROM meta WHERE key = '0';") { statement in
                guard let hex = database.text(statement, 0), hex.utf8.count % 2 == 0 else { throw Failure.malformed }
                var bytes = Data(); bytes.reserveCapacity(hex.utf8.count / 2)
                var index = hex.startIndex
                while index < hex.endIndex {
                    if bytes.count % chunkBytes == 0 { try Task.checkCancellation() }
                    let end = hex.index(index, offsetBy: 2)
                    guard let byte = UInt8(hex[index..<end], radix: 16) else { throw Failure.malformed }
                    bytes.append(byte); index = end
                }
                payloadCharge += try validateJSON(bytes)
                guard payloadCharge <= payloadBytes else { throw Failure.resourceLimit }
            }
            try database.rows("SELECT data FROM blobs;") { statement in
                guard let pointer = sqlite3_column_blob(statement, 0) else { return }
                let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
                if let first = bytes.first(where: { ![UInt8(9), 10, 13, 32].contains($0) }), first == 123 || first == 91 {
                    payloadCharge += try validateJSON(bytes)
                    guard payloadCharge <= payloadBytes else { throw Failure.resourceLimit }
                } else if !CursorACPStoreReader.searchBlobIsBounded(bytes) { throw Failure.unsupported }
            }
        }
        let parsed: Session?
        switch session.source {
        case .cline: parsed = ClineSessionParser.parseFileFull(at: snapshot, forSearch: true)
        case .cursor: parsed = try CursorACPStoreReader.parseSearchSnapshot(at: snapshot, expectedSessionID: session.id, remainingPayloadBytes: payloadBytes - payloadCharge, reportPayload: { expanded in
            summary.peakPayloadCharge = max(summary.peakPayloadCharge, payloadCharge + expanded)
        })
        case .pi: parsed = PiSessionParser.parseFileFull(at: snapshot, forSearch: true)
        case .kimi: parsed = KimiSessionParser.parseFileFull(at: snapshot, forSearch: true)
        case .grok: parsed = GrokSessionParser.parseFileFull(at: snapshot, forSearch: true)
        case .qwen: parsed = QwenSessionParser.parseFileFull(at: snapshot, forSearch: true)
        default: parsed = session.source.descriptor.parseFullByPath?(snapshot)
        }
        guard let parsed else { throw Failure.unsupported }
        metadata?(parsed)
        if parsed.sourceSearchHasOmissions { summary.reasons.insert(.omittedRecord) }
        for event in parsed.events {
            try Task.checkCancellation()
            count(event, into: &summary)
            if session.source == .qwen, event.role == QwenSessionParser.unrecognizedNoticeRole {
                summary.reasons.insert(.unsupportedFormat)
                continue
            }
            var omittedOutput = false
            if session.source == .fx, event.kind == .tool_result,
               let raw = event.rawJSON.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                let payload = object["payload"] as? [String: Any] ?? object
                omittedOutput = (payload["truncated"] as? Bool) == true
                    || (payload["completeness"] as? String).map { $0 != "complete" } == true
                let previewBytes = (payload["preview"] as? String)?.utf8.count ?? 0
                if let stored = payload["stored_bytes"] as? Int, stored > previewBytes {
                    if let name = payload["artifact_ref"] as? String,
                       name.hasPrefix("result-"), name.hasSuffix(".txt"),
                       !name.contains("/"), !name.contains("\\"), !name.contains(".."),
                       let artifact = try? Data(contentsOf: snapshot.deletingLastPathComponent().appendingPathComponent("tool-results").appendingPathComponent(name)),
                       artifact.count == stored, artifact.count <= 2 * 1024 * 1024 {
                        // Parser read its complete supported artifact.
                    } else { omittedOutput = true }
                }
            }
            if omittedOutput { summary.reasons.insert(.omittedRecord) }
            for segment in SearchSourceText.segments(event: event, source: session.source) {
                // The display parser appends synthetic truncation prose. Omission is
                // source metadata, never inferred from a literal phrase in the output.
                if omittedOutput && (segment.kind == .output || segment.kind == .error) {
                    let suffix = "\n[truncated]"
                    let text = segment.text.hasSuffix(suffix) ? String(segment.text.dropLast(suffix.count)) : segment.text
                    try consume(.init(source: segment.source, eventID: segment.eventID, kind: segment.kind,
                                      text: text, provenance: .source))
                } else { try consume(segment) }
            }
        }
        guard SessionFileStat.precise(from: root) == directoryBefore else { throw Failure.changed }
        for (directory, proof) in directoryProofs {
            guard SessionFileStat.precise(from: directory) == proof else { throw Failure.changed }
        }
        for (path, proof) in zip(paths, proofs) {
            guard SessionFileStat.precise(from: path) == proof.stat else { throw Failure.changed }
        }
        if let artifactBefore {
            guard let after = session.source.descriptor.artifactRevision?(primary),
                  after.selectedURL == artifactBefore.selectedURL,
                  after.manifestRevision == artifactBefore.manifestRevision else { throw Failure.changed }
        }
        summary.revision = .init(files: proofs)
    }

    /// OpenCode stores one transcript across session, message, and part files. Freeze the
    /// exact files used by the display parser once, then derive both search text and the
    /// published revision from that private snapshot.
    private static func scanBoundedOpenCode(session: Session, summary: inout SearchScanSummary,
                                            metadata: ((Session) -> Void)?,
                                            consume: (SearchTextSegment) throws -> Void) throws {
        let fileManager = FileManager.default
        let primary = URL(fileURLWithPath: session.filePath).standardizedFileURL
        let root = primary.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let messageRoot = root.appendingPathComponent("message", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
        let partRoot = root.appendingPathComponent("part", isDirectory: true)
        let container = fileManager.temporaryDirectory.appendingPathComponent("as-search-" + UUID().uuidString)
        let temporary = container.appendingPathComponent(root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: container) }

        var directoryProofs: [(url: URL, stat: SessionFileStat?)] = []
        var provedDirectories = Set<String>()
        var proofs: [SearchSourceRevision.File] = []
        var frozenPaths = Set<String>()
        var payloadCharge = chunkBytes * 2
        var visitedEntries = 0
        let maximumVisitedEntries = 65_536
        var legacyLookupBytes = 0
        let maximumLegacyLookupBytes = 256 * 1024 * 1024
        var legacyLookupProofs: [(url: URL, stat: SessionFileStat)] = []
        var legacyLookupDigest = SHA256()
        var unresolvedLegacyIDs = Set<String>()

        func checkInventoryLimit() throws {
            guard proofs.count < 4096 else { throw Failure.resourceLimit }
        }

        func proveDirectory(_ directory: URL) throws {
            let standardized = directory.standardizedFileURL
            guard provedDirectories.insert(standardized.path).inserted else { return }
            guard directoryProofs.count < maximumVisitedEntries else { throw Failure.resourceLimit }
            directoryProofs.append((standardized, SessionFileStat.precise(from: standardized)))
        }

        func walkDirectory(_ directory: URL, recursive: Bool,
                           visit: (URL, URLResourceValues) throws -> Void) throws {
            try proveDirectory(directory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return }
            guard isDirectory.boolValue else { throw Failure.changed }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { throw Failure.changed }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                visitedEntries += 1
                guard visitedEntries <= maximumVisitedEntries else { throw Failure.resourceLimit }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    try proveDirectory(url)
                    if !recursive { enumerator.skipDescendants() }
                }
                try visit(url, values)
            }
        }

        func recordLegacyLookupProof(path: URL, stat: SessionFileStat) {
            let resolved = path.resolvingSymlinksInPath()
            legacyLookupProofs.append((resolved, stat))
            let identity = [resolved.path, String(stat.mtime), String(stat.size),
                            stat.fingerprint ?? "", stat.changeTime.map(String.init) ?? ""]
                .joined(separator: "\u{1f}") + "\n"
            legacyLookupDigest.update(data: Data(identity.utf8))
        }

        func commitFrozen(_ standardized: URL, before: SessionFileStat, data: Data,
                          json: Bool, validatedJSONCharge: Int? = nil) throws {
            if json {
                do {
                    let charge = try validatedJSONCharge ?? validateJSON(data)
                    payloadCharge += charge - chunkBytes * 2
                    if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                        summary.reasons.insert(.malformedRecord)
                    }
                } catch Failure.malformed {
                    summary.reasons.insert(.malformedRecord)
                    payloadCharge += data.count * 24
                }
                summary.records += 1
            } else {
                payloadCharge += data.count * 24
            }
            guard payloadCharge <= payloadBytes else { throw Failure.resourceLimit }
            summary.peakPayloadCharge = max(summary.peakPayloadCharge, payloadCharge)
            let relative = String(standardized.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, !relative.hasPrefix("..") else { throw Failure.unsupported }
            let target = temporary.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            proofs.append(.init(path: standardized.resolvingSymlinksInPath().path, stat: before))
        }

        /// Returns bytes from the same descriptor-backed read that is written into the
        /// snapshot and recorded in `proofs`. Callers may decode this value, but never
        /// reread the live source to build semantic events.
        @discardableResult
        func freeze(_ path: URL, json: Bool) throws -> Data {
            let standardized = path.standardizedFileURL
            guard frozenPaths.insert(standardized.path).inserted else { throw Failure.changed }
            try checkInventoryLimit()

            let handle = try FileHandle(forReadingFrom: standardized)
            let descriptor = handle.fileDescriptor
            defer { try? handle.close() }
            guard let before = SessionFileStat.precise(fromFileDescriptor: descriptor), before.size >= 0 else {
                throw Failure.changed
            }
            guard before.size <= recordBytes else { throw Failure.resourceLimit }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                guard data.count + chunk.count <= recordBytes,
                      payloadCharge + (data.count + chunk.count) * 24 <= payloadBytes else {
                    throw Failure.resourceLimit
                }
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count == Int(before.size),
                  SessionFileStat.precise(fromFileDescriptor: descriptor) == before,
                  SessionFileStat.precise(from: standardized) == before else { throw Failure.changed }
            summary.bytesRead += UInt64(data.count)
            summary.decompressedBytes += UInt64(data.count)
            try commitFrozen(standardized, before: before, data: data, json: json)
            return data
        }

        /// Legacy indexing must inspect the shared part tree, but foreign sessions do
        /// not consume this transcript's retained-payload budget. Each candidate is
        /// descriptor-bounded, decoded one at a time, and retained only as a compact
        /// revision proof.
        func inspectLegacyPart(_ path: URL) throws {
            let standardized = path.standardizedFileURL
            let handle = try FileHandle(forReadingFrom: standardized)
            let descriptor = handle.fileDescriptor
            defer { try? handle.close() }
            guard let before = SessionFileStat.precise(fromFileDescriptor: descriptor), before.size >= 0 else {
                throw Failure.changed
            }
            guard before.size <= recordBytes,
                  legacyLookupBytes + Int(before.size) <= maximumLegacyLookupBytes else {
                throw Failure.resourceLimit
            }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                guard data.count + chunk.count <= recordBytes else { throw Failure.resourceLimit }
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count == Int(before.size),
                  SessionFileStat.precise(fromFileDescriptor: descriptor) == before,
                  SessionFileStat.precise(from: standardized) == before else { throw Failure.changed }
            legacyLookupBytes += data.count
            summary.bytesRead += UInt64(data.count)
            recordLegacyLookupProof(path: standardized, stat: before)

            let projectedOwner = openCodeTopLevelString(in: data, key: "messageID")
            try Task.checkCancellation()
            guard let messageID = projectedOwner,
                  unresolvedLegacyIDs.contains(messageID) else { return }
            let charge = try validateJSON(data)
            guard frozenPaths.insert(standardized.path).inserted else { throw Failure.changed }
            try checkInventoryLimit()
            summary.decompressedBytes += UInt64(data.count)
            try commitFrozen(standardized, before: before, data: data, json: true, validatedJSONCharge: charge)
        }

        try proveDirectory(root)
        _ = try freeze(primary, json: true)

        var usesV2Layout = false
        let migration = root.appendingPathComponent("migration")
        if fileManager.fileExists(atPath: migration.path) {
            let data = try freeze(migration, json: false)
            usesV2Layout = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "2"
        }

        var messageIDs = Set<String>()
        try walkDirectory(messageRoot, recursive: true) { url, values in
            guard values.isRegularFile == true,
                  url.lastPathComponent.hasPrefix("msg_"),
                  url.pathExtension.lowercased() == "json" else { return }
            let data = try freeze(url, json: true)
            guard let message = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                summary.reasons.insert(.malformedRecord)
                return
            }
            guard message.sessionID == nil || message.sessionID == session.id else { return }
            messageIDs.insert(message.id ?? url.deletingPathExtension().lastPathComponent)
        }

        for messageID in messageIDs.sorted() {
            let directory = partRoot.appendingPathComponent(messageID, isDirectory: true)
            var foundDirectPart = false
            try walkDirectory(directory, recursive: false) { url, values in
                guard values.isRegularFile == true,
                      url.pathExtension.lowercased() == "json" else { return }
                foundDirectPart = true
                _ = try freeze(url, json: true)
            }
            if !foundDirectPart, !usesV2Layout { unresolvedLegacyIDs.insert(messageID) }
        }

        // A markerless store falls back to the legacy messageID index only for messages
        // that had no direct part directory. Every inspected candidate participates in
        // the revision so an in-place change cannot turn an ignored record into a match.
        if !unresolvedLegacyIDs.isEmpty {
            try walkDirectory(partRoot, recursive: true) { url, values in
                guard values.isRegularFile == true,
                      url.lastPathComponent.hasPrefix("prt_"),
                      url.pathExtension.lowercased() == "json",
                      !frozenPaths.contains(url.standardizedFileURL.path) else { return }
                try inspectLegacyPart(url)
            }
        }

        try Task.checkCancellation()
        let snapshot = temporary.appendingPathComponent(String(primary.path.dropFirst(root.path.count + 1)))
        guard let parsed = OpenCodeSessionParser.parseFileFull(at: snapshot) else { throw Failure.unsupported }
        metadata?(parsed)
        if parsed.sourceSearchHasOmissions { summary.reasons.insert(.omittedRecord) }
        for event in parsed.events {
            try Task.checkCancellation()
            count(event, into: &summary)
            for segment in SearchSourceText.segments(event: event, source: .opencode) {
                try consume(segment)
            }
        }

        for proof in directoryProofs {
            guard SessionFileStat.precise(from: proof.url) == proof.stat else { throw Failure.changed }
        }
        for proof in proofs {
            guard SessionFileStat.precise(from: URL(fileURLWithPath: proof.path)) == proof.stat else { throw Failure.changed }
        }
        for proof in legacyLookupProofs {
            guard SessionFileStat.precise(from: proof.url) == proof.stat else { throw Failure.changed }
        }
        let lookupRevision = legacyLookupProofs.isEmpty
            ? nil
            : legacyLookupDigest.finalize().map { String(format: "%02x", $0) }.joined()
        summary.revision = .init(files: proofs, logical: lookupRevision)
    }

    /// Extract one top-level JSON string without materializing unrelated values. OpenCode
    /// legacy lookup uses this before semantic preflight so a large foreign output cannot
    /// consume the selected transcript's allocation budget.
    private static func openCodeTopLevelString(in data: Data, key: String) -> String? {
        func decodedString(_ range: Range<Int>, maximumBytes: Int) -> String? {
            guard range.count <= maximumBytes else { return nil }
            let quoted = Data(data[range])
            return try? JSONDecoder().decode(String.self, from: quoted)
        }
        func closingQuote(from start: Int) -> Int? {
            var index = start + 1
            while index < data.count {
                if data[index] == 92 {
                    index += 2
                } else if data[index] == 34 {
                    return index
                } else {
                    index += 1
                }
            }
            return nil
        }
        func skipWhitespace(_ start: Int) -> Int {
            var index = start
            while index < data.count, [UInt8(9), 10, 13, 32].contains(data[index]) { index += 1 }
            return index
        }

        var depth = 0
        var index = 0
        while index < data.count {
            if index % chunkBytes == 0, Task.isCancelled { return nil }
            switch data[index] {
            case 123, 91:
                depth += 1
                index += 1
            case 125, 93:
                depth -= 1
                guard depth >= 0 else { return nil }
                index += 1
            case 34:
                guard let close = closingQuote(from: index) else { return nil }
                if depth == 1 {
                    let afterKey = skipWhitespace(close + 1)
                    if afterKey < data.count, data[afterKey] == 58,
                       decodedString(index..<(close + 1), maximumBytes: 256) == key {
                        let valueStart = skipWhitespace(afterKey + 1)
                        if valueStart < data.count, data[valueStart] == 34,
                           let valueEnd = closingQuote(from: valueStart) {
                            return decodedString(valueStart..<(valueEnd + 1), maximumBytes: 4096)
                        }
                        // Foundation keeps the first semantic duplicate key, including
                        // a non-string value. Do not allow a later duplicate to claim it.
                        return nil
                    }
                }
                index = close + 1
            default:
                index += 1
            }
        }
        return nil
    }
}
