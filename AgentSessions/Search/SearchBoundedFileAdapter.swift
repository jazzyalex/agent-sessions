import Foundation
import SQLite3

extension SearchSourceScanner {
    /// Older/small providers retain their audited parser under a frozen, preflighted input
    /// budget. All participating files are copied through checked descriptors into a private
    /// temporary directory; parsers cannot race a growing original file after preflight.
    static func scanBoundedFiles(session: Session, summary: inout SearchScanSummary,
                                 metadata: ((Session) -> Void)? = nil,
                                 consume: (SearchTextSegment) throws -> Void) throws {
        let primary = URL(fileURLWithPath: session.filePath).standardizedFileURL
        let root = session.source == .kimi
            ? KimiSessionDiscovery.stateFile(forWireFile: primary).deletingLastPathComponent()
            : primary.deletingLastPathComponent()
        var paths = [primary]
        func optional(_ name: String) {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { paths.append(url) }
        }
        switch session.source {
        case .cline: paths.append(ClineSessionDiscovery.messagesFile(forManifest: primary))
        case .kimi: optional("state.json")
        case .grok: optional("summary.json"); optional("meta.json")
        case .copilot: optional("workspace.yaml")
        case .fx:
            for name in ["session.json", "checkpoint.json", "authority.json", "display.json", "recovery.json", "events.jsonl"] { optional(name) }
            let artifacts = root.appendingPathComponent("tool-results")
            if let enumerator = FileManager.default.enumerator(at: artifacts, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
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
        case .opencode: throw Failure.unsupported // Historical split storage requires a dedicated adapter.
        case .codex, .claude, .antigravity, .droid, .pi, .hermes, .qwen, .deepseekHarness: break
        default: throw Failure.unsupported
        }
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0.path).inserted }
        // Nested artifact directories participate in the source proof too: adding a
        // sibling tool-result file must invalidate the frozen snapshot.
        let directories = Set(paths.map { $0.deletingLastPathComponent() } + [root] + (session.source == .fx ? [root.appendingPathComponent("tool-results")] : []))
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
}
