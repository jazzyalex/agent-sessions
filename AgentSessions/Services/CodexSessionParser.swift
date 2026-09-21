import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// DEBUG logging helper (no-ops in Release)
#if DEBUG
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always) private func DBG(_ message: @autoclosure () -> String) {}
#endif

/// Codex rollout JSONL parsing: lightweight metadata, full, tail, and incremental append
/// parses plus per-line event decoding. Stateless and UI-free so the macOS app and the
/// Linux `as-core` CLI share one implementation; `SessionIndexer` forwards to it.
enum CodexSessionParser {
    struct CodexAppendCursor: Equatable {
        let path: String
        let systemNumber: UInt64
        let fileNumber: UInt64
        let byteOffset: UInt64
        let lastLineIndex: Int
        let modifiedAt: Date
    }

    enum CodexAppendParseResult {
        case appended(Session, CodexAppendCursor)
        case incompleteTail
        case unchanged
        case fallbackToFullParse
    }

    struct FullParseResult {
        let session: Session
        let lastLineIndex: Int
        let snapshotByteCount: UInt64?
        let snapshotSystemNumber: UInt64?
        let snapshotFileNumber: UInt64?
        let readSucceeded: Bool
    }

    private struct CodexSurfaceMetadata {
        let originator: String?
        let source: String?
        let surface: CodexSessionSurface
    }

    private static func codexSurfaceMetadata(from payload: [String: Any]) -> CodexSurfaceMetadata {
        let originator = nonEmptyString(payload["originator"] as? String)
        let rawSource = payload["source"]
        let sourceString = codexSourceString(from: rawSource)
        return CodexSurfaceMetadata(
            originator: originator,
            source: sourceString,
            surface: classifyCodexSurface(originator: originator, source: rawSource, sourceString: sourceString)
        )
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func codexSourceString(from source: Any?) -> String? {
        if let string = nonEmptyString(source as? String) {
            return string
        }
        guard let source else { return nil }
        guard JSONSerialization.isValidJSONObject(source),
              let data = try? JSONSerialization.data(withJSONObject: source, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              !json.isEmpty else {
            return nil
        }
        return json
    }

    /// Not private: `CodexSideChatLogReader` classifies a side chat's parent
    /// rollout through this, so both paths stay on one rule.
    static func classifyCodexSurface(originator: String?, source: Any?, sourceString: String?) -> CodexSessionSurface {
        if let sourceDict = source as? [String: Any], sourceDict["subagent"] != nil {
            return .subagent
        }

        let originLower = originator?.lowercased()
        let sourceLower = sourceString?.lowercased()

        // `source` wins for cli/exec, and only for those.
        //
        // From ~0.126 Codex pins `originator` to "Codex Desktop" on every
        // surface, so testing originator first made the `source` branches below
        // unreachable and stamped Desktop on genuine CLI sessions -- 161 of them
        // in the owner's 1,735-rollout corpus, spread across ten cli_versions,
        // so this is the norm on modern builds rather than a blip.
        //
        // `source == "vscode"` is deliberately NOT promoted the same way. It is
        // not a surface: 76 rollouts carrying it sit in Codex Desktop's own
        // generated `~/Documents/Codex/<date>/<name>` chat workspaces, so
        // Desktop writes it too. Trusting it would relabel real Desktop sessions
        // as VS Code and strip them from the Desktop Chats grouping -- swapping
        // one wrong answer for another. Settling that needs a controlled Desktop
        // session and a VS Code session on the same ordinary folder; until then
        // vscode-source rows keep falling through to the originator rules.
        if sourceLower == "cli" || sourceLower == "exec" {
            return .cli
        }
        if originLower == "codex desktop" ||
            originLower?.contains("desktop") == true ||
            originLower?.contains("app") == true {
            return .desktop
        }
        if originLower == "codex_vscode" {
            return .vscode
        }
        if originLower == "codex_cli_rs" || originLower == "codex-tui" {
            return .cli
        }
        if sourceLower == "vscode" {
            return .vscode
        }
        if originator != nil || sourceString != nil {
            return .other
        }
        return .unknown
    }

    static func parseFile(at url: URL) -> Session? {
        parseLightweight(at: url) ?? parseFileFull(at: url)
    }

    static func parseLightweight(at url: URL) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        // Prefer lightweight metadata-first parsing for all files at launch.
        // This avoids full JSONL scans during Stage 1 and keeps launch bounded
        // even when many sessions are present.
        if let light = lightweightSession(from: url, size: size, mtime: mtime) {
            DBG("✅ LIGHTWEIGHT: \(url.lastPathComponent) estEvents=\(light.eventCount) messageCount=\(light.messageCount)")
            return light
        }
        return nil
    }

    // Full parse (no lightweight check)
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        parseFileFullResult(at: url, forcedID: forcedID)?.session
    }

    static func parseFileFullResult(at url: URL, forcedID: String? = nil) -> FullParseResult? {
        let _span = Perf.begin("transcriptParseFull", thresholdMs: 100, "path=\(url.lastPathComponent)")
        defer { Perf.end(_span) }
        DBG("    📖 parseFileFull: Getting file attrs...")
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let snapshotSize = (attrs[.size] as? NSNumber)?.uint64Value
        let snapshotSystemNumber = (attrs[.systemNumber] as? NSNumber)?.uint64Value
        let snapshotFileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        DBG("    📖 parseFileFull: File size = \(size) bytes")

        DBG("    📖 parseFileFull: Creating JSONLReader...")
        let reader = JSONLReader(url: url,
                                 maximumBytes: snapshotSize,
                                 propagatesReadErrors: true)
        var events: [SessionEvent] = []
        var modelSeen: String? = nil
        var parentSessionID: String? = nil
        var subagentType: String? = nil
        var codexSurfaceMetadata: CodexSurfaceMetadata? = nil
        var reasoningEffort: String? = nil
        var idx = 0
        var readSucceeded = true
        let eventIDBase = Self.hash(path: url.path)
        DBG("    📖 parseFileFull: Starting forEachLine...")
        do {
            try reader.forEachLine { rawLine in
                idx += 1
                // Only sanitize very large lines (>100KB) - sanitizeLargeLine has its own guards for smaller lines
                let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeLargeLine(rawLine) : rawLine
                let (event, maybeModel) = Self.parseLine(safeLine, eventID: Self.eventID(base: eventIDBase, index: idx))
                if let m = maybeModel, modelSeen == nil { modelSeen = m }

                // Extract subagent info and turn_context model from early lines
                if idx <= 20, let data = safeLine.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let objType = obj["type"] as? String
                    let payload = obj["payload"] as? [String: Any]

                    if parentSessionID == nil, objType == "session_meta", let payload {
                        if codexSurfaceMetadata == nil {
                            codexSurfaceMetadata = Self.codexSurfaceMetadata(from: payload)
                        }
                        if let source = payload["source"],
                           let sourceDict = source as? [String: Any],
                           let subagentInfo = sourceDict["subagent"] {
                            if let subStr = subagentInfo as? String {
                                subagentType = subStr
                            } else if let subDict = subagentInfo as? [String: Any] {
                                if let threadSpawn = subDict["thread_spawn"] as? [String: Any] {
                                    parentSessionID = threadSpawn["parent_thread_id"] as? String
                                    subagentType = threadSpawn["agent_role"] as? String
                                } else if let other = subDict["other"] as? String {
                                    // Codex's catch-all variant, e.g. {"other":"guardian"}
                                    // (approval-reviewer subagents; 70 on disk as of 2026-07-19).
                                    subagentType = other
                                } else if let variant = subDict.keys.sorted().first {
                                    // Unknown future struct variant: keep the variant name so
                                    // the session still classifies as a subagent instead of
                                    // silently reading as a root session.
                                    subagentType = variant
                                }
                            }
                            if parentSessionID == nil {
                                // Newer Codex builds (0.145+) also stamp the parent link at
                                // payload top level; guardian rollouts have ONLY this form
                                // (thread_spawn_edges has no row for them).
                                parentSessionID = payload["parent_thread_id"] as? String
                            }
                        }
                    }

                    if objType == "turn_context", let payload {
                        if let turnModel = payload["model"] as? String, !turnModel.isEmpty {
                            modelSeen = turnModel
                        }
                        if reasoningEffort == nil,
                           let effort = payload["effort"] as? String, !effort.isEmpty {
                            reasoningEffort = effort
                        }
                    }
                }

                events.append(event)
            }
        } catch {
            readSucceeded = false
            // If file can't be read, emit a single error meta event
            let event = SessionEvent(id: Self.eventID(base: eventIDBase, index: 0), timestamp: Date(), kind: .error, role: "system", text: "Failed to read: \(error.localizedDescription)", toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
            events.append(event)
        }

        let times = events.compactMap { $0.timestamp }
        var start = times.min()
        var end = times.max()
        if start == nil || end == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if start == nil { start = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) }
                if end == nil { end = (attrs[.modificationDate] as? Date) ?? start }
            }
        }
        let id = forcedID ?? Self.hash(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let isHousekeeping = Session.computeIsHousekeeping(source: .codex, events: events)
        let internalSessionIDHint = Session.deriveCodexInternalSessionID(from: events)
        let subagentReasoningEffort = (parentSessionID != nil || subagentType != nil) ? reasoningEffort : nil
        let session = Session(id: id,
                              source: .codex,
                              startTime: start,
                              endTime: end,
                              model: modelSeen,
                              filePath: url.path,
                              fileSizeBytes: snapshotSize.flatMap(Int.init(exactly:)),
                              eventCount: nonMetaCount,
                              events: events,
                              isHousekeeping: isHousekeeping,
                              codexInternalSessionIDHint: internalSessionIDHint,
                              parentSessionID: parentSessionID,
                              subagentType: subagentType,
                              codexOriginator: codexSurfaceMetadata?.originator,
                              codexSource: codexSurfaceMetadata?.source,
                              codexSurface: codexSurfaceMetadata?.surface ?? .unknown,
                              reasoningEffort: subagentReasoningEffort)

        if size > 5_000_000 {  // Log full parse of files >5MB
            DBG("  ⚠️ FULL PARSE: \(url.lastPathComponent) size=\(size/1_000_000)MB events=\(events.count) nonMeta=\(session.nonMetaCount)")
        }

        return FullParseResult(session: session,
                               lastLineIndex: idx,
                               snapshotByteCount: snapshotSize,
                               snapshotSystemNumber: snapshotSystemNumber,
                               snapshotFileNumber: snapshotFileNumber,
                               readSucceeded: readSucceeded)
    }

    static func makeAppendCursor(at url: URL,
                          lastLineIndex: Int,
                          byteOffset requestedByteOffset: UInt64? = nil) -> CodexAppendCursor? {
        guard lastLineIndex >= 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let systemNumber = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modifiedAt = attrs[.modificationDate] as? Date else {
            return nil
        }
        let byteOffset = requestedByteOffset ?? size
        guard
              byteOffset > 0,
              byteOffset <= size,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: byteOffset - 1)
            guard try handle.read(upToCount: 1)?.first == 0x0A else { return nil }
            return CodexAppendCursor(path: url.path,
                                     systemNumber: systemNumber,
                                     fileNumber: fileNumber,
                                     byteOffset: byteOffset,
                                     lastLineIndex: lastLineIndex,
                                     modifiedAt: modifiedAt)
        } catch {
            return nil
        }
    }

    static func parseFileAppend(at url: URL,
                         existing: Session,
                         cursor: CodexAppendCursor) -> CodexAppendParseResult {
        guard cursor.path == url.path,
              existing.filePath == url.path,
              existing.source == .codex,
              !existing.isPartiallyHydrated,
              !existing.events.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let systemNumber = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modifiedAt = attrs[.modificationDate] as? Date,
              systemNumber == cursor.systemNumber,
              fileNumber == cursor.fileNumber,
              size >= cursor.byteOffset else {
            return .fallbackToFullParse
        }
        if size == cursor.byteOffset {
            return modifiedAt == cursor.modifiedAt ? .unchanged : .fallbackToFullParse
        }

        let byteCount = size - cursor.byteOffset
        guard byteCount <= UInt64(Int.max), let handle = try? FileHandle(forReadingFrom: url) else {
            return .fallbackToFullParse
        }
        defer { try? handle.close() }

        var appendedData = Data()
        appendedData.reserveCapacity(Int(byteCount))
        do {
            try handle.seek(toOffset: cursor.byteOffset)
            while appendedData.count < Int(byteCount) {
                let remaining = Int(byteCount) - appendedData.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty else {
                    return .fallbackToFullParse
                }
                appendedData.append(chunk)
            }
        } catch {
            return .fallbackToFullParse
        }

        // The path may be atomically replaced after the first stat but before the
        // handle opens or finishes reading. Never join bytes from a replacement
        // file onto the already-published transcript.
        guard let postReadAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let postReadSystemNumber = (postReadAttributes[.systemNumber] as? NSNumber)?.uint64Value,
              let postReadFileNumber = (postReadAttributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let postReadSize = (postReadAttributes[.size] as? NSNumber)?.uint64Value,
              postReadSystemNumber == cursor.systemNumber,
              postReadFileNumber == cursor.fileNumber,
              postReadSize >= size else {
            return .fallbackToFullParse
        }

        // Codex can be observed while it is midway through a JSONL write. Keep the
        // previous complete-line cursor and retry after the writer terminates the line;
        // reparsing the entire file here would recreate the large-session CPU spike.
        guard appendedData.last == 0x0A else { return .incompleteTail }

        var events = existing.events
        var model = existing.model
        var reasoningEffort = existing.reasoningEffort
        var lineIndex = cursor.lastLineIndex
        let eventIDBase = Self.hash(path: url.path)
        let pieces = appendedData.split(separator: 0x0A, omittingEmptySubsequences: false)
        for piece in pieces.dropLast() {
            guard !piece.isEmpty else { continue }
            guard piece.count <= 8_388_608,
                  let rawLine = String(data: Data(piece), encoding: .utf8) else {
                return .fallbackToFullParse
            }
            lineIndex += 1
            let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeLargeLine(rawLine) : rawLine
            let (event, maybeModel) = Self.parseLine(
                safeLine,
                eventID: Self.eventID(base: eventIDBase, index: lineIndex)
            )
            if model == nil, let maybeModel { model = maybeModel }
            if let data = safeLine.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] as? String == "turn_context",
               let payload = object["payload"] as? [String: Any] {
                if let turnModel = payload["model"] as? String, !turnModel.isEmpty {
                    model = turnModel
                }
                if reasoningEffort == nil,
                   let effort = payload["effort"] as? String, !effort.isEmpty {
                    reasoningEffort = effort
                }
            }
            events.append(event)
        }

        let eventTimes = events.compactMap(\.timestamp)
        let startTime = eventTimes.min() ?? existing.startTime
        let endTime = eventTimes.max() ?? existing.endTime
        let nonMetaCount = events.lazy.filter { $0.kind != .meta }.count
        let parsed = Session(
            id: existing.id,
            source: .codex,
            startTime: startTime,
            endTime: endTime,
            model: model,
            filePath: url.path,
            fileSizeBytes: Int(exactly: size),
            eventCount: nonMetaCount,
            events: events,
            cwd: existing.lightweightCwd,
            repoName: existing.lightweightRepoName,
            lightweightTitle: existing.lightweightTitle,
            lightweightCommands: existing.lightweightCommands,
            isHousekeeping: Session.computeIsHousekeeping(source: .codex, events: events),
            codexInternalSessionIDHint: existing.codexInternalSessionIDHint
                ?? Session.deriveCodexInternalSessionID(from: events),
            parentSessionID: existing.parentSessionID,
            subagentType: existing.subagentType,
            relationshipKind: existing.relationshipKind,
            customTitle: existing.customTitle,
            codexOriginator: existing.codexOriginator,
            codexSource: existing.codexSource,
            codexSurface: existing.codexSurface,
            originator: existing.originator,
            originSource: existing.originSource,
            surface: existing.surface,
            reasoningEffort: (existing.parentSessionID != nil || existing.subagentType != nil)
                ? reasoningEffort
                : nil,
            deletedAt: existing.deletedAt
        )
        let nextCursor = CodexAppendCursor(path: cursor.path,
                                           systemNumber: cursor.systemNumber,
                                           fileNumber: cursor.fileNumber,
                                           byteOffset: size,
                                           lastLineIndex: lineIndex,
                                           modifiedAt: modifiedAt)
        return .appended(parsed, nextCursor)
    }

    // Task 9e stage 0: disposable tail-only parse. Reads only the last window
    // of the file (ReverseJSONLTailReader) and parses those lines with the
    // same Self.parseLine used by parseFileFull, so a monster session can
    // paint something readable in milliseconds instead of waiting ~10s for a
    // full parse. The result is marked isPartiallyHydrated=true and is meant
    // to be replaced wholesale when the real parseFileFull publishes — it
    // does NOT attempt head-metadata extraction (model/parent/subagent),
    // since that requires the file HEAD which this deliberately never reads.
    static func parseFileTail(at url: URL,
                        forcedID: String? = nil,
                        maxBytes: Int = 2_097_152,
                        maxLines: Int = 400) -> Session? {
        let _span = Perf.begin("transcriptParseTail", thresholdMs: 50, "path=\(url.lastPathComponent)")
        defer { Perf.end(_span) }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1

        let rawLines = ReverseJSONLTailReader.readLastLines(url: url, maxBytes: maxBytes, maxLines: maxLines)
        guard !rawLines.isEmpty else { return nil }

        // Provisional event IDs are seeded from a base far outside the range
        // parseFileFull ever produces (idx starts at 1), so they never
        // coexist with or collide against the full parse's event IDs.
        let tailIndexBase = 5_000_000
        let eventIDBase = Self.hash(path: url.path)
        var events: [SessionEvent] = []
        events.reserveCapacity(rawLines.count)
        for (offset, rawLine) in rawLines.enumerated() {
            let idx = tailIndexBase + offset
            let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeLargeLine(rawLine) : rawLine
            let (event, _) = Self.parseLine(safeLine, eventID: Self.eventID(base: eventIDBase, index: idx))
            events.append(event)
        }

        let times = events.compactMap { $0.timestamp }
        var start = times.min()
        var end = times.max()
        if start == nil || end == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if start == nil { start = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) }
                if end == nil { end = (attrs[.modificationDate] as? Date) ?? start }
            }
        }

        let id = forcedID ?? Self.hash(path: url.path)
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let isHousekeeping = Session.computeIsHousekeeping(source: .codex, events: events)

        var session = Session(id: id,
                               source: .codex,
                               startTime: start,
                               endTime: end,
                               model: nil,
                               filePath: url.path,
                               fileSizeBytes: size >= 0 ? size : nil,
                               eventCount: nonMetaCount,
                               events: events,
                               isHousekeeping: isHousekeeping,
                               codexInternalSessionIDHint: nil,
                               parentSessionID: nil,
                               subagentType: nil,
                               codexOriginator: nil,
                               codexSource: nil,
                               codexSurface: nil,
                               reasoningEffort: nil)
        session.isPartiallyHydrated = true

        DBG("  ⚡ TAIL PARSE: \(url.lastPathComponent) size=\(size/1_000_000)MB tailEvents=\(events.count)")

        return session
    }

    /// Build a lightweight Session by scanning only head/tail slices for timestamps and model, and estimating event count.
    static func lightweightSession(from url: URL, size: Int, mtime: Date) -> Session? {
        let headBytesInitial = 256 * 1024
        let headBytesMax = 2 * 1024 * 1024
        let tailBytes = 256 * 1024
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Read head lines (newline-bounded) rather than a fixed slice.
        // Newer Codex sessions can have an extremely large first line (session_meta with embedded instructions),
        // which can exceed 256KB and otherwise prevent extracting any usable metadata/title.
        func readHeadLines(initialBytes: Int, maxBytes: Int, maxLines: Int) -> (lines: [String], bytesRead: Int, newlineCount: Int) {
            var out: [String] = []
            out.reserveCapacity(min(maxLines, 300))
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            var bytesRead = 0
            var newlineCount = 0

            while bytesRead < maxBytes, out.count < maxLines {
                let remaining = maxBytes - bytesRead
                let chunkSize = min(64 * 1024, remaining)
                let chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
                if chunk.isEmpty { break }
                bytesRead += chunk.count
                newlineCount += chunk.filter { $0 == 0x0a }.count
                buffer.append(chunk)

                while out.count < maxLines {
                    guard let nl = buffer.firstIndex(of: 0x0a) else { break }
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl) // remove through newline
                    if let line = String(data: lineData, encoding: .utf8) {
                        out.append(line)
                    }
                }

                // Common case: once we've reached the "old" head slice size and have at least one complete line,
                // stop early to avoid reading megabytes per file during normal indexing.
                if bytesRead >= initialBytes, !out.isEmpty { break }
            }

            // If we never saw a newline but have some content, keep a best-effort first line.
            if out.isEmpty, !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                out.append(s)
            }
            return (out, bytesRead, newlineCount)
        }

        let headRead = readHeadLines(initialBytes: headBytesInitial, maxBytes: headBytesMax, maxLines: 300)

        // Read tail slice
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? size
        var tailData: Data = Data()
        if fileSize > tailBytes {
            let offset = UInt64(fileSize - tailBytes)
            try? fh.seek(toOffset: offset)
            tailData = (try? fh.readToEnd()) ?? Data()
        }

        func lines(from data: Data, keepHead: Bool) -> [String] {
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return [] }
            let parts = s.components(separatedBy: "\n")
            if keepHead {
                return Array(parts.prefix(300))
            } else {
                return Array(parts.suffix(300))
            }
        }

        let headLines = headRead.lines
        let tailLines = lines(from: tailData, keepHead: false)

        var model: String? = nil
        var tmin: Date? = nil
        var tmax: Date? = nil
        var sampleCount = 0
        var sampleEvents: [SessionEvent] = []
        var cwd: String? = nil
        var parentSessionID: String? = nil
        var subagentType: String? = nil
        var codexSurfaceMetadata: CodexSurfaceMetadata? = nil
        var reasoningEffort: String? = nil

        func ingest(_ raw: String) {
            let line = sanitizeCodexHugeFields(sanitizeImagePayload(raw))
            let (ev, maybeModel) = parseLine(line, eventID: "light-\(sampleCount)")
            if let ts = ev.timestamp {
                if tmin == nil || ts < tmin! { tmin = ts }
                if tmax == nil || ts > tmax! { tmax = ts }
            }
            if model == nil, let m = maybeModel, !m.isEmpty { model = m }
            // Extract cwd, subagent info, and turn_context model from raw JSON
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let objType = obj["type"] as? String
                let payload = obj["payload"] as? [String: Any]

                // Extract cwd from session_meta or environment_context
                if cwd == nil {
                    if let text = ev.text, text.contains("<cwd>") {
                        if let start = text.range(of: "<cwd>"),
                           let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
                            cwd = String(text[start.upperBound..<end.lowerBound])
                        }
                    } else if let payload {
                        if let cwdValue = payload["cwd"] as? String, !cwdValue.isEmpty { cwd = cwdValue }
                    } else if let cwdValue = obj["cwd"] as? String, !cwdValue.isEmpty {
                        cwd = cwdValue
                    }
                }

                // Codex session_meta: detect subagent source
                if objType == "session_meta", let payload {
                    if codexSurfaceMetadata == nil {
                        codexSurfaceMetadata = Self.codexSurfaceMetadata(from: payload)
                    }
                }
                if parentSessionID == nil, objType == "session_meta", let payload {
                    if let source = payload["source"] {
                        if let sourceDict = source as? [String: Any],
                           let subagentInfo = sourceDict["subagent"] {
                            if let subStr = subagentInfo as? String {
                                // e.g. "review" — no parent thread ID available
                                subagentType = subStr
                            } else if let subDict = subagentInfo as? [String: Any] {
                                if let threadSpawn = subDict["thread_spawn"] as? [String: Any] {
                                    parentSessionID = threadSpawn["parent_thread_id"] as? String
                                    subagentType = threadSpawn["agent_role"] as? String
                                } else if let other = subDict["other"] as? String {
                                    // Codex's catch-all variant, e.g. {"other":"guardian"}
                                    // (approval-reviewer subagents; 70 on disk as of 2026-07-19).
                                    subagentType = other
                                } else if let variant = subDict.keys.sorted().first {
                                    // Unknown future struct variant: keep the variant name so
                                    // the session still classifies as a subagent instead of
                                    // silently reading as a root session.
                                    subagentType = variant
                                }
                            }
                            if parentSessionID == nil {
                                // Newer Codex builds (0.145+) also stamp the parent link at
                                // payload top level; guardian rollouts have ONLY this form
                                // (thread_spawn_edges has no row for them).
                                parentSessionID = payload["parent_thread_id"] as? String
                            }
                        }
                    }
                }

                // Codex turn_context: extract actual LLM model and provider-reported effort.
                if objType == "turn_context", let payload {
                    if let turnModel = payload["model"] as? String, !turnModel.isEmpty {
                        model = turnModel
                    }
                    if reasoningEffort == nil,
                       let effort = payload["effort"] as? String, !effort.isEmpty {
                        reasoningEffort = effort
                    }
                }
            } else if cwd == nil, let text = ev.text, text.contains("<cwd>") {
                if let start = text.range(of: "<cwd>"),
                   let end = text.range(of: "</cwd>", range: start.upperBound..<text.endIndex) {
                    cwd = String(text[start.upperBound..<end.lowerBound])
                }
            }
            sampleEvents.append(ev)
            sampleCount += 1
        }

        headLines.forEach(ingest)
        tailLines.forEach(ingest)

        // Estimate event count: count newlines in head slice for more accurate estimate
        let headBytesRead = max(headRead.bytesRead, 1)
        let newlineCount = max(headRead.newlineCount, 1)
        let avgLineLen = max(256, headBytesRead / max(newlineCount, 1))  // Min 256 bytes per line
        let estEvents = max(1, min(1_000_000, fileSize / avgLineLen))

        DBG("  📊 Lightweight estimation: headBytes=\(headBytesRead) newlines=\(newlineCount) avgLineLen=\(avgLineLen) estEvents=\(estEvents)")

        let id = Self.hash(path: url.path)
        let internalSessionIDHint = Session.deriveCodexInternalSessionID(from: sampleEvents)
        // Use sample events for title/cwd extraction, then create lightweight session
        let tempIsHousekeeping = Session.computeIsHousekeeping(source: .codex, events: sampleEvents)
        let subagentReasoningEffort = (parentSessionID != nil || subagentType != nil) ? reasoningEffort : nil
        let tempSession = Session(id: id,
                                  source: .codex,
                                  startTime: tmin,
                                  endTime: tmax,
                                  model: model,
                                  filePath: url.path,
                                  fileSizeBytes: fileSize,
                                  eventCount: estEvents,
                                  events: sampleEvents,
                                  isHousekeeping: tempIsHousekeeping,
                                  codexInternalSessionIDHint: internalSessionIDHint,
                                  parentSessionID: parentSessionID,
                                  subagentType: subagentType,
                                  codexOriginator: codexSurfaceMetadata?.originator,
                                  codexSource: codexSurfaceMetadata?.source,
                                  codexSurface: codexSurfaceMetadata?.surface ?? .unknown,
                                  reasoningEffort: subagentReasoningEffort)

        // Extract title from sample events using existing logic
        let title = tempSession.codexPreviewTitle ?? tempSession.title

        // Now create final lightweight session with empty events but preserve metadata
        let session = Session(id: id,
                              source: .codex,
                              startTime: tmin ?? (attrsDate(url, key: .creationDate) ?? mtime),
                              endTime: tmax ?? mtime,
                              model: model,
                              filePath: url.path,
                              fileSizeBytes: fileSize,
                              eventCount: estEvents,
                              events: [],
                              cwd: cwd,
                              repoName: nil,  // Will be computed from cwd
                              lightweightTitle: title,
                              isHousekeeping: tempIsHousekeeping || title == "No prompt",
                              codexInternalSessionIDHint: internalSessionIDHint,
                              parentSessionID: parentSessionID,
                              subagentType: subagentType,
                              customTitle: tempSession.customTitle,
                              codexOriginator: codexSurfaceMetadata?.originator,
                              codexSource: codexSurfaceMetadata?.source,
                              codexSurface: codexSurfaceMetadata?.surface ?? .unknown,
                              reasoningEffort: subagentReasoningEffort)
        return session
    }

    private static func attrsDate(_ url: URL, key: FileAttributeKey) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[key] as? Date) ?? nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func parseLine(_ line: String, eventID: String) -> (SessionEvent, String?) {
        var timestamp: Date? = nil
        var role: String? = nil
        var type: String? = nil
        var text: String? = nil
        var toolName: String? = nil
        var toolInput: String? = nil
        var toolOutput: String? = nil
        var model: String? = nil
        var messageID: String? = nil
        var parentID: String? = nil
        var isDelta: Bool = false

        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // timestamp could be number or string, and under various keys
            let tsKeys = [
                "timestamp", "time", "ts", "created", "created_at", "datetime", "date",
                "event_time", "eventTime", "iso_timestamp", "when", "at"
            ]
            for key in tsKeys {
                if let v = obj[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
            }

            // Check for nested payload structure (Codex format)
            var workingObj = obj
            if let payload = obj["payload"] as? [String: Any] {
                // Merge payload fields into working object
                workingObj = payload
                // Also check payload for timestamp if not found at top level
                if timestamp == nil {
                    for key in tsKeys {
                        if let v = payload[key] { timestamp = timestamp ?? Self.decodeDate(from: v) }
                    }
                }
            }

            // role / type (now checking in payload if present)
            if let r = workingObj["role"] as? String { role = r }
            if let t = workingObj["type"] as? String { type = t }
            if type == nil, let e = workingObj["event"] as? String { type = e }

            // model (check both top-level and payload)
            if let m = obj["model"] as? String { model = m }
            if model == nil, let m = workingObj["model"] as? String { model = m }

            // delta / chunk identifiers
            if let mid = workingObj["message_id"] as? String { messageID = mid }
            if let pid = workingObj["parent_id"] as? String { parentID = pid }
            if let idFromObj = workingObj["id"] as? String, messageID == nil { messageID = idFromObj }
            if let d = workingObj["delta"] as? Bool { isDelta = isDelta || d }
            if workingObj["delta"] is [String: Any] { isDelta = true }
            if workingObj["chunk"] != nil { isDelta = true }
            if workingObj["delta_index"] != nil { isDelta = true }

            // text content variants
            if let content = workingObj["content"] as? String { text = content }
            if text == nil, let txt = workingObj["text"] as? String { text = txt }
            if text == nil, let msg = workingObj["message"] as? String { text = msg }
            // Assistant content arrays: concatenate text parts
            if text == nil, let arr = workingObj["content"] as? [Any] {
                var pieces: [String] = []
                for el in arr {
                    if let d = el as? [String: Any] {
                        if let t = d["text"] as? String { pieces.append(t) }
                        else if let val = d["value"] as? String { pieces.append(val) }
                        else if let data = d["data"] as? String { pieces.append(data) }
                    } else if let s = el as? String { pieces.append(s) }
                }
                if !pieces.isEmpty { text = pieces.joined() }
            }

            // Heuristic: environment_context appears as an XML-ish block often logged under 'user'.
            // Treat any event whose text contains this block as meta regardless of role/type.
            if let t = text, t.contains("<environment_context>") { type = "environment_context" }

            if text == nil, let t = type?.lowercased(), t == "thread_rolled_back" {
                var numTurns: Int? = nil
                if let n = workingObj["num_turns"] as? Int { numTurns = n }
                if numTurns == nil, let n = workingObj["numTurns"] as? Int { numTurns = n }
                if numTurns == nil, let n = workingObj["num_turns"] as? Double { numTurns = Int(n) }
                if numTurns == nil, let n = workingObj["numTurns"] as? Double { numTurns = Int(n) }
                if numTurns == nil, let n = workingObj["num_turns"] as? String, let parsed = Int(n) { numTurns = parsed }
                if numTurns == nil, let n = workingObj["numTurns"] as? String, let parsed = Int(n) { numTurns = parsed }
                if numTurns == nil, let payload = workingObj["payload"] as? [String: Any] {
                    if let n = payload["num_turns"] as? Int { numTurns = n }
                    if numTurns == nil, let n = payload["numTurns"] as? Int { numTurns = n }
                    if numTurns == nil, let n = payload["num_turns"] as? Double { numTurns = Int(n) }
                    if numTurns == nil, let n = payload["numTurns"] as? Double { numTurns = Int(n) }
                    if numTurns == nil, let n = payload["num_turns"] as? String, let parsed = Int(n) { numTurns = parsed }
                    if numTurns == nil, let n = payload["numTurns"] as? String, let parsed = Int(n) { numTurns = parsed }
                }
                if let n = numTurns {
                    let suffix = (n == 1) ? "" : "s"
                    text = "Thread rollback: removed \(n) user turn\(suffix)"
                } else {
                    text = "Thread rollback"
                }
            }

            // tool fields
            if let t = workingObj["tool"] as? String { toolName = t }
            if toolName == nil, let name = workingObj["name"] as? String { toolName = name }
            if toolName == nil, let fn = (workingObj["function"] as? [String: Any])?["name"] as? String { toolName = fn }

            if let input = workingObj["input"] as? String { toolInput = input }
            if toolInput == nil, let args = workingObj["arguments"] as? String { toolInput = args }
            // Arguments may be non-string; minify to single-line JSON
            if toolInput == nil, let argsObj = workingObj["arguments"] {
                if let s = Self.stringifyJSON(argsObj, pretty: false) { toolInput = s }
            }

            // Outputs: stdout, stderr, result, output (in this stable order)
            var outputs: [String] = []
            if let stdout = workingObj["stdout"] { outputs.append(Self.stringifyJSON(stdout, pretty: true) ?? String(describing: stdout)) }
            if let stderr = workingObj["stderr"] { outputs.append(Self.stringifyJSON(stderr, pretty: true) ?? String(describing: stderr)) }
            if let result = workingObj["result"] { outputs.append(Self.stringifyJSON(result, pretty: true) ?? String(describing: result)) }
            if let output = workingObj["output"] { outputs.append(Self.stringifyJSON(output, pretty: true) ?? String(describing: output)) }
            if !outputs.isEmpty {
                toolOutput = outputs.joined(separator: "\n")
            }
            // Back-compat if values above were strings only
            if toolOutput == nil, let out = workingObj["output"] as? String { toolOutput = out }
            if toolOutput == nil, let res = workingObj["result"] as? String { toolOutput = res }
        }

        let kind = SessionEventKind.from(role: role, type: type)
        let event = SessionEvent(
            id: eventID,
            timestamp: timestamp,
            kind: kind,
            role: role,
            text: text,
            toolName: toolName,
            toolInput: toolInput,
            toolOutput: toolOutput,
            messageID: messageID,
            parentID: parentID,
            isDelta: isDelta,
            rawJSON: line
        )
        return (event, model)
    }
    
    // MARK: - Sanitizers
    /// Replace very large JSON string fields that can balloon memory or slow down parsing.
    ///
    /// Primarily for newer Codex CLI sessions which can include:
    /// - `payload.encrypted_content` (reasoning) which can be very large
    /// - `payload.instructions` (session_meta) which can also be very large
    private static func sanitizeCodexHugeFields(_ line: String) -> String {
        guard line.contains("\"encrypted_content\"") || line.contains("\"instructions\"") else { return line }
        var s = line
        s = sanitizeJSONStringValue(in: s, key: "\"encrypted_content\"", placeholder: "[ENCRYPTED_OMITTED]")
        s = sanitizeJSONStringValue(in: s, key: "\"instructions\"", placeholder: "[INSTRUCTIONS_OMITTED]")
        return s
    }

    /// Sanitizes a JSON string value for a given `"key"` by replacing its value with `placeholder`.
    /// Byte-scanning implementation that respects JSON string escaping (\" and \\) and avoids String-index
    /// invalidation issues when mutating the underlying storage.
    private static func sanitizeJSONStringValue(in input: String, key: String, placeholder: String) -> String {
        guard let inputData = input.data(using: .utf8),
              let keyData = key.data(using: .utf8),
              let placeholderData = placeholder.data(using: .utf8) else {
            return input
        }

        let bytes = Array(inputData)
        let needle = Array(keyData)
        let replacement = Array(placeholderData)

        func findSubsequence(_ haystack: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
            guard !needle.isEmpty, start >= 0 else { return nil }
            if needle.count > haystack.count { return nil }
            var i = start
            while i + needle.count <= haystack.count {
                if haystack[i] == needle[0] {
                    var match = true
                    if needle.count > 1 {
                        for j in 1..<needle.count where haystack[i + j] != needle[j] {
                            match = false
                            break
                        }
                    }
                    if match { return i }
                }
                i += 1
            }
            return nil
        }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var i = 0
        while let keyStart = findSubsequence(bytes, needle, from: i) {
            let keyEnd = keyStart + needle.count
            out.append(contentsOf: bytes[i..<keyStart])
            out.append(contentsOf: bytes[keyStart..<keyEnd])

            // Find the ':' following the key.
            var j = keyEnd
            while j < bytes.count, bytes[j] != 0x3A { j += 1 } // ':'
            if j >= bytes.count {
                out.append(contentsOf: bytes[keyEnd..<bytes.count])
                return String(bytes: out, encoding: .utf8) ?? input
            }

            // Include everything up to and including the ':'.
            out.append(contentsOf: bytes[keyEnd...j])
            j += 1

            // Preserve whitespace after ':'.
            while j < bytes.count {
                let b = bytes[j]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    out.append(b)
                    j += 1
                    continue
                }
                break
            }

            // Only handle string values. If not a string, continue scanning.
            guard j < bytes.count, bytes[j] == 0x22 else { // '"'
                i = j
                continue
            }

            // Copy opening quote.
            out.append(0x22)
            j += 1

            // Scan to closing quote, respecting escapes.
            var escaped = false
            while j < bytes.count {
                let b = bytes[j]
                if escaped {
                    escaped = false
                    j += 1
                    continue
                }
                if b == 0x5C { // '\\'
                    escaped = true
                    j += 1
                    continue
                }
                if b == 0x22 { break } // '"'
                j += 1
            }

            // If we never found a closing quote (truncated), fall back to original input.
            guard j < bytes.count, bytes[j] == 0x22 else { return input }

            // Replace contents with placeholder, then copy closing quote.
            out.append(contentsOf: replacement)
            out.append(0x22)
            j += 1

            // Continue after the replaced value.
            i = j
        }

        if i < bytes.count {
            out.append(contentsOf: bytes[i..<bytes.count])
        }
        return String(bytes: out, encoding: .utf8) ?? input
    }

    /// Replace any inline base64 image data URLs with a short placeholder to avoid huge allocations and slow JSON parsing.
    private static func sanitizeImagePayload(_ line: String) -> String {
        // Fast path: nothing to do
        guard line.contains("data:image") || line.contains("\"input_image\"") else { return line }
        var s = line
        // Replace data:image..." up to the closing quote with a compact token
        // This is a simple, robust scan that avoids heavy regex backtracking on very long lines.
        let needle = "data:image"
        if let range = s.range(of: needle) {
            // Find the next quote after the scheme
            if let q = s[range.upperBound...].firstIndex(of: "\"") {
                let replaceRange = range.lowerBound..<q
                s.replaceSubrange(replaceRange, with: "data:image/omitted")
            }
        }
        return s
    }

    /// Aggressively strip ALL embedded images from a line (for lazy load performance).
    /// Uses regex for 50-100x speedup vs string manipulation.
    private static func sanitizeAllImages(_ line: String) -> String {
        guard line.contains("data:image") else { return line }

        // Fast byte-level check before expensive string operations
        // For extremely long lines (>5MB UTF-8 bytes), skip entirely
        let utf8Count = line.utf8.count
        if utf8Count > 5_000_000 {
            // Just return a minimal JSON stub - the line is too large to parse usefully anyway
            return #"{"type":"omitted","text":"[Large event omitted - \#(utf8Count/1_000_000)MB]"}"#
        }

        // For moderately large lines (1-5MB), use a simpler/faster approach
        if utf8Count > 1_000_000 {
            // Simple string split approach - faster than regex on huge strings
            let parts = line.components(separatedBy: "data:image")
            if parts.count <= 1 { return line }

            var result = parts[0]
            for i in 1..<parts.count {
                // Find the closing quote and skip everything up to it
                if let quoteIdx = parts[i].firstIndex(of: "\"") {
                    result += "[IMG]"
                    result += String(parts[i][quoteIdx...])
                } else {
                    result += "[IMG]" + parts[i]
                }
            }
            return result
        }

        // For normal lines (<1MB), use fast string scanning (avoids slow regex backtracking)
        var result = line
        while let dataIdx = result.range(of: "data:image") {
            // Find the closing quote (end of data URL)
            if let endQuote = result[dataIdx.upperBound...].firstIndex(of: "\"") {
                // Replace everything from "data:image" to quote with placeholder that doesn't contain "data:image"
                result.replaceSubrange(dataIdx.lowerBound..<endQuote, with: "[IMG_OMITTED]")
            } else {
                // No closing quote found, replace to end and break
                result.replaceSubrange(dataIdx.lowerBound..., with: "[IMG_OMITTED]")
                break
            }
        }

        return result
    }

    /// Composite sanitizer for unusually large JSONL lines.
    /// Intentionally conservative: only used for very large lines in full-parse paths.
    private static func sanitizeLargeLine(_ line: String) -> String {
        var s = line
        s = sanitizeAllImages(s)
        s = sanitizeCodexHugeFields(s)
        return s
    }

    private static func eventID(for url: URL, index: Int) -> String {
        let base = Self.hash(path: url.path)
        return Self.eventID(base: base, index: index)
    }

    static func eventID(forPath path: String, index: Int) -> String {
        let base = hash(path: path)
        return eventID(base: base, index: index)
    }

    private static func eventID(base: String, index: Int) -> String {
        base + String(format: "-%04d", index)
    }

    private static func hash(path: String) -> String {
        let d = SHA256.hash(data: Data(path.utf8))
        return d.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func decodeDate(from any: Any) -> Date? {
        // Numeric (seconds, ms, µs)
        if let d = any as? Double {
            let secs = normalizeEpochSeconds(d)
            return Date(timeIntervalSince1970: secs)
        }
        if let i = any as? Int {
            let secs = normalizeEpochSeconds(Double(i))
            return Date(timeIntervalSince1970: secs)
        }
        if let s = any as? String {
            // Digits-only string → numeric epoch
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: s)) {
                if let val = Double(s) { return Date(timeIntervalSince1970: normalizeEpochSeconds(val)) }
            }
            // ISO8601 with or without fractional seconds (cached, lock-protected)
            Self.dateFormatterLock.lock()
            defer { Self.dateFormatterLock.unlock() }
            if let d = Self.isoFracFormatter.date(from: s) { return d }
            if let d = Self.isoNoFracFormatter.date(from: s) { return d }
            for fmt in Self.fallbackDateFormatters {
                if let d = fmt.date(from: s) { return d }
            }
        }
        return nil
    }

    private static let dateFormatterLock = NSLock()

    // Cached date formatters — allocation is expensive, reuse across all parse calls
    private static let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fallbackDateFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss",
         "yyyy/MM/dd HH:mm:ssZZZZZ", "yyyy/MM/dd HH:mm:ss"].map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            return df
        }
    }()

    private static func normalizeEpochSeconds(_ value: Double) -> Double {
        // Heuristic: >1e14 → microseconds; >1e11 → milliseconds; else seconds
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }

    private static func stringifyJSON(_ any: Any, pretty: Bool) -> String? {
        // If it's already a String, return as-is
        if let s = any as? String { return s }
        // Numbers, bools, arrays, dicts → JSON text
        if JSONSerialization.isValidJSONObject(any) {
            if let data = try? JSONSerialization.data(withJSONObject: any, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]) {
                return String(data: data, encoding: .utf8)
            }
        } else {
            // Wrap simple types into JSON-compatible representation
            if let n = any as? NSNumber { return n.stringValue }
            if let b = any as? Bool { return b ? "true" : "false" }
        }
        return nil
    }
}
