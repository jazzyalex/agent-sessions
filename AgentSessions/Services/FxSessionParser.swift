import Foundation

/// Parses fx (vercel-labs) session directories into `Session` values.
///
/// A session directory holds `session.json` (metadata sidecar),
/// `display.json` (title/preview), and `checkpoint.json` (the materialized
/// conversation). The sidecars are authoritative for identity, workspace,
/// title, model and both timestamps; history entries carry no per-entry time,
/// so text events inherit nil and only tool results carry their own
/// `created_at_ms`.
///
/// Shapes verified against the on-disk sessions at fx 0.0.4 and re-checked
/// line-by-line against upstream v0.0.5 (`session_codec.zig`, `session.zig`):
///
/// - `checkpoint.json` — `{schema_version, session_id, log_generation,
///   through_seq, state}`. `state.history[]` is the transcript; the sibling
///   `events.jsonl` is write-ahead infrastructure and is never read.
/// - `state.history[]` entries are whole turns keyed by `kind` — all four
///   kinds are rendered:
///   `assistant` carries `{user: {text, images}, assistant, execution}`;
///   `interrupted` carries `{user, assistant (often null), tool_call,
///   completed_tool_names, terminal_reason}` plus `execution` whenever tools
///   completed before the cut;
///   `background_command` is an assistant-shaped turn the runtime parked in
///   the background (`{user, log_path, expect_url, url, background_record_id}`
///   plus optional `assistant`/`execution`);
///   `compacted_summary` is the turn that replaces the history removed by
///   auto-compaction (`{summary, removed_turn_count, compaction_count}` plus
///   optionally `root_user_messages`). The user prompt lives *inside* the
///   turn — fx has no standalone user records.
/// - `execution.tool_steps[]` — each `{assistant, tool_calls, tool_results}`;
///   a turn renders user → per-step narration + calls + results → final reply.
/// - `tool_calls[]` — `{id, name, arguments_json}` where **`arguments_json`
///   is a JSON string** on the wire (Grok/Kimi's shape, not Devin's object).
/// - `tool_results[]` — `{tool_call_id, tool_name, status, output, preview,
///   truncated, created_at_ms, …}`, keyed back to its call by id.
/// - Text-bearing fields are written through fx's durable-bytes encoder:
///   valid UTF-8 lands as a plain JSON string, anything else as
///   `{"encoding": "base64", "data": …}`. Every text read here goes through
///   `durableString`, so one non-UTF-8 byte degrades that field to a
///   `[binary output]` marker instead of erasing it.
/// - `user.images` — `{id, path, media_type, snapshot_path, snapshot_sha256}`
///   records whose bytes live in files under the session directory
///   (`snapshot_path` resolves to `images/<basename>`); rendered as
///   `[image]` markers and never opened.
///
/// **Schema 4 (fx 0.0.8 → 0.0.14)** has no checkpoint. Built from upstream
/// source at tag v0.0.14 (`session_codec.zig` `SessionMetadata`,
/// `session_event.zig` `ConversationEnvelope`/`ConversationEvent`,
/// `session_log.zig`, `result_store.zig`); the frame union is unchanged from
/// v0.0.8 and readers accept frame `schema_version` 1–3.
///
/// - `session.json` — compact `{schema_version: 4, id, origin_workspace_root,
///   workspace_root, created_at_ms, updated_at_ms, conversation_language,
///   provider, model, effort, fast_mode, ultrafast_mode?, title?,
///   subagent_child}`. `provider` is a name string, or `{name, binding}` for a
///   configured provider. `title` appears once fx names the session.
/// - `events.jsonl` — one frame per line: `{schema_version, seq,
///   timestamp_ms, event: {<kind>: payload}}`, the kind being the payload's
///   single key: `user {text, images, work_id}`, `assistant {text,
///   provider_replay, standalone_response}`, `tool_call {call_id, tool_name,
///   arguments_json, …}`, `tool_result {call_id, tool_name, status,
///   artifact_ref, output_bytes, stored_bytes, completeness, preview,
///   created_at_ms, …}`, `steering {text}`, `turn_completed {files,
///   turn_summary}`, `interrupted {reason, partial_text, …}` and
///   `context_checkpoint {covers_through_seq, summary}`. Text is plain UTF-8
///   JSON (no durable base64 form here). Every frame of a committed turn
///   carries the commit time, so a prompt takes its turn's
///   `turn_summary.started_at_ms` when one is recorded. Compaction appends a
///   `context_checkpoint`; earlier frames stay in the log.
/// - `tool_result.preview` holds at most the first 4 KiB of the output; the
///   stored text lives in `tool-results/<artifact_ref>` (`result-*.txt`).
///   `completeness: "partial"` means the stored text itself was cut.
/// - `recovery.json` — `{conversation_seq, checkpoint}`: the turn fx was
///   running when it last saved, in the schema-3 history-turn shape
///   (`user`, `assistant_source`, `execution.tool_steps[]`). fx honors it only
///   while `conversation_seq` equals the log's last `seq`; so does this
///   parser, and it renders the turn's content only when the log has no open
///   turn (otherwise the log already holds its start).
enum FxSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024

    /// Reads `session.json` field by field out of a plain dictionary.
    /// Deliberately NOT `Decodable`, for the same reason Grok's sidecar reader
    /// is not: one unexpected field type must cost one field, not the session.
    private struct Sidecar {
        let schemaVersion: Int?
        let id: String?
        let createdAtMS: Int64?
        let updatedAtMS: Int64?
        let workspaceRoot: String?
        let model: String?
        let effort: String?
        let historyLen: Int?
        /// Schema 4 only; schema 3 kept the title in `display.json`.
        let title: String?

        init(object: [String: Any]) {
            schemaVersion = FxSessionParser.int(object["schema_version"])
            id = object["id"] as? String
            createdAtMS = FxSessionParser.int64(object["created_at_ms"])
            updatedAtMS = FxSessionParser.int64(object["updated_at_ms"])
            workspaceRoot = object["workspace_root"] as? String
            if let preferences = object["preferences"] as? [String: Any] {
                model = preferences["model"] as? String
                effort = preferences["effort"] as? String
            } else {
                // Schema 4 lifted the preferences to the top level.
                model = object["model"] as? String
                effort = object["effort"] as? String
            }
            historyLen = FxSessionParser.int(object["history_len"])
            title = object["title"] as? String
        }

        /// Schema 4 is the first manifest whose sibling `events.jsonl` is the
        /// conversation rather than write-ahead infrastructure.
        var isEventLogSchema: Bool { (schemaVersion ?? 0) >= 4 }
    }

    /// The head of the log the lightweight pass builds events for. Frames past
    /// it are still read, but only counted.
    private static let previewFrameLimit = 200

    /// Exact schema-4 lightweight count/title keyed to one on-disk file
    /// revision. Cached entries have no rendered events or artifact contents.
    private struct LightweightCountCacheEntry {
        let size: Int
        let modifiedAt: Date
        let nonMetaCount: Int
        let firstPromptText: String?
    }
    private static let countCacheLock = NSLock()
    private static var countCache: [String: LightweightCountCacheEntry] = [:]
    private static var countScansByPathForTesting: [String: Int] = [:]

    static func lightweightScanCountForTesting(at url: URL) -> Int {
        countCacheLock.lock()
        defer { countCacheLock.unlock() }
        return countScansByPathForTesting[url.path, default: 0]
    }

    private static func freshFileSize(at url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func logRevision(at url: URL) -> (size: Int, modifiedAt: Date)? {
        // URL.resourceValues caches metadata on the URL instance. A second
        // lightweight parse may reuse that URL after the log has grown.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        return (size.intValue, modifiedAt)
    }

    private static func cachedLightweightScan(at url: URL) -> EventLogScan? {
        guard let revision = logRevision(at: url) else { return nil }
        countCacheLock.lock()
        defer { countCacheLock.unlock() }
        guard let entry = countCache[url.path],
              entry.size == revision.size, entry.modifiedAt == revision.modifiedAt else { return nil }
        var scan = EventLogScan()
        scan.nonMetaCount = entry.nonMetaCount
        scan.firstPromptText = entry.firstPromptText
        return scan
    }

    private static func recordLightweightScan(_ scan: EventLogScan, at url: URL,
                                              revision: (size: Int, modifiedAt: Date)?) {
        countCacheLock.lock()
        defer { countCacheLock.unlock() }
        if countScansByPathForTesting.count >= 2_048,
           countScansByPathForTesting[url.path] == nil {
            countScansByPathForTesting.removeAll(keepingCapacity: true)
        }
        countScansByPathForTesting[url.path, default: 0] += 1
        guard let revision, let after = logRevision(at: url),
              revision.size == after.size, revision.modifiedAt == after.modifiedAt else { return }
        if countCache.count >= 2_048 { countCache.removeAll(keepingCapacity: true) }
        countCache[url.path] = LightweightCountCacheEntry(
            size: revision.size, modifiedAt: revision.modifiedAt,
            nonMetaCount: scan.nonMetaCount, firstPromptText: scan.firstPromptText)
    }
    /// Ceiling for one `tool-results/` artifact read during a full parse;
    /// fx itself caps stored text at 8 MiB.
    private static let maxArtifactReadBytes = 2 * 1024 * 1024

    // MARK: - Entry points

    /// Lightweight list pass. Schema 3: sidecars only, never the checkpoint;
    /// `eventCount` is fx's own `history_len` — whole turns, not rendered
    /// events — which is exact enough for the zero/low-message visibility
    /// filters. Schema 4 has no `history_len`, so the pass reads all of
    /// `events.jsonl`, builds events only for the first `previewFrameLimit`
    /// frames and counts the non-meta events of the whole log (never
    /// `recovery.json`). The full parse replaces either count with the real
    /// one. A schema-4 log that cannot be read returns nil.
    static func parseFile(at url: URL) -> Session? {
        build(url: url, includeEvents: false, readChunk: nil)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        let size = freshFileSize(at: url)
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }
        return build(url: url, includeEvents: true, readChunk: nil)
    }

    /// Test seam: injects the chunk reader `events.jsonl` is read through, so a
    /// test can prove that a read error mid-log fails the parse instead of
    /// publishing a partial scan. Same shape as Droid's telemetry seam.
    static func parseFileForTesting(at url: URL,
                                    includeEvents: Bool,
                                    readChunk: @escaping (FileHandle, Int) throws -> Data) -> Session? {
        build(url: url, includeEvents: includeEvents, readChunk: readChunk)
    }

    private static func build(url: URL,
                              includeEvents: Bool,
                              readChunk: ((FileHandle, Int) throws -> Data)?) -> Session? {
        switch FxSessionDiscovery.layout(forSessionFile: url) {
        case .checkpoint: return buildFromCheckpoint(url: url, includeEvents: includeEvents)
        case .eventLog: return buildFromEventLog(url: url, includeEvents: includeEvents, readChunk: readChunk)
        }
    }

    private static func buildFromCheckpoint(url: URL, includeEvents: Bool) -> Session? {
        guard let id = FxSessionDiscovery.sessionID(forSessionFile: url) else { return nil }

        let size = freshFileSize(at: url)
        let sidecar = readSidecar(for: url)
        let startTime = sidecar?.createdAtMS.flatMap(msDate)
        let endTime = sidecar?.updatedAtMS.flatMap(msDate)

        var events: [SessionEvent] = []
        var nonMetaCount = 0
        var commandCount = 0
        var firstPromptText: String?

        if includeEvents, let checkpoint = readCheckpoint(for: url) {
            let state = checkpoint["state"] as? [String: Any]
            let history = state?["history"] as? [[String: Any]] ?? []
            for (turnIndex, turn) in history.enumerated() {
                let built = Self.events(forTurn: turn, turnIndex: turnIndex)
                nonMetaCount += built.filter { $0.kind != .meta }.count
                commandCount += built.filter { $0.kind == .tool_call }.count
                if firstPromptText == nil, let prompt = promptText(fromTurn: turn), !prompt.isEmpty {
                    firstPromptText = prompt
                }
                events.append(contentsOf: built)
            }
        }

        let cwd = sidecar?.workspaceRoot
        let displayTitle = readDisplayTitle(for: url)
        let title = firstNonEmpty(displayTitle, firstPromptText)

        return Session(id: id,
                       source: .fx,
                       startTime: startTime,
                       endTime: endTime,
                       model: sidecar?.model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: includeEvents ? nonMetaCount : max(sidecar?.historyLen ?? 0, 0),
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       lightweightCommands: commandCount > 0 ? commandCount : nil,
                       parentSessionID: nil,
                       subagentType: nil,
                       surface: .cli,
                       reasoningEffort: sidecar?.effort)
    }

    // MARK: - Schema 4 event log

    /// What one pass over `events.jsonl` produced.
    private struct EventLogScan {
        var events: [SessionEvent] = []
        var firstPromptText: String?
        /// The `seq` of the last frame read; recovery is tied to it.
        var lastSeq: Int64 = 0
        /// A `user` frame opened a turn that no `turn_completed`/`interrupted`
        /// has closed yet.
        var turnOpen = false
        /// Non-meta and tool-call events across the whole log, including the
        /// frames past the preview window whose events were not built.
        var nonMetaCount = 0
        var commandCount = 0
    }

    private static func buildFromEventLog(url: URL,
                                          includeEvents: Bool,
                                          readChunk: ((FileHandle, Int) throws -> Data)?) -> Session? {
        guard let id = FxSessionDiscovery.sessionID(forSessionFile: url),
              let sidecar = readSidecar(for: url),
              sidecar.isEventLogSchema else { return nil }

        let size = freshFileSize(at: url)
        // A reader override is test-only and intentionally bypasses the
        // cache. Never record a failed or racing scan as a good revision.
        let useCountCache = !includeEvents && readChunk == nil
        let before = useCountCache ? logRevision(at: url) : nil
        var scan: EventLogScan
        if useCountCache, let cached = cachedLightweightScan(at: url) {
            scan = cached
        } else {
            guard let parsed = scanEventLog(at: url,
                                           previewFrameLimit: includeEvents ? nil : previewFrameLimit,
                                           readArtifacts: includeEvents,
                                           readChunk: readChunk) else { return nil }
            scan = parsed
            if useCountCache { recordLightweightScan(scan, at: url, revision: before) }
        }
        if includeEvents {
            let recovered = recoveryEvents(for: url, after: scan)
            scan.events.append(contentsOf: recovered)
            scan.nonMetaCount += recovered.filter { $0.kind != .meta }.count
            scan.commandCount += recovered.filter { $0.kind == .tool_call }.count
        }

        let nonMetaCount = scan.nonMetaCount
        let commandCount = scan.commandCount
        let cwd = sidecar.workspaceRoot
        let title = firstNonEmpty(sidecar.title, scan.firstPromptText)

        return Session(id: id,
                       source: .fx,
                       startTime: sidecar.createdAtMS.flatMap(msDate),
                       endTime: sidecar.updatedAtMS.flatMap(msDate),
                       model: sidecar.model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: nonMetaCount,
                       events: includeEvents ? scan.events : [],
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       // nil in the lightweight pass, as for schema 3: it never
                       // reads `recovery.json`, so its command count is partial.
                       lightweightCommands: includeEvents && commandCount > 0 ? commandCount : nil,
                       parentSessionID: nil,
                       subagentType: nil,
                       surface: .cli,
                       reasoningEffort: sidecar.effort)
    }

    /// Reads conversation frames in log order. Lines that are not frames — a
    /// torn last line, or a schema-3 `kind`/`payload` record — are skipped.
    ///
    /// Events are built for the first `previewFrameLimit` frames (all frames
    /// when nil). Past that window the scan keeps reading and only counts:
    /// every frame takes the same branch below, but `emit` skips building the
    /// event, so the lightweight count equals the full parse's count for the
    /// log. Returns nil when the log cannot be opened or a read fails.
    private static func scanEventLog(at url: URL,
                                     previewFrameLimit: Int?,
                                     readArtifacts: Bool,
                                     readChunk: ((FileHandle, Int) throws -> Data)?) -> EventLogScan? {
        var scan = EventLogScan()
        var framesRead = 0
        var turnUserIndex: Int?
        let reader = JSONLReader(url: url, propagatesReadErrors: true, readChunk: readChunk)
        do {
            try reader.forEachLineWhile { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let envelope = object["event"] as? [String: Any],
                      envelope.count == 1,
                      let entry = envelope.first else { return true }
                framesRead += 1
                let buildsEvents = previewFrameLimit.map { framesRead <= $0 } ?? true
                // The one way a frame adds an event: counted always, built
                // only inside the preview window.
                func emit(_ kind: SessionEventKind, _ make: @autoclosure () -> SessionEvent) {
                    if kind != .meta { scan.nonMetaCount += 1 }
                    if kind == .tool_call { scan.commandCount += 1 }
                    if buildsEvents { scan.events.append(make()) }
                }
                let kind = entry.key
                let seq = int64(object["seq"]) ?? Int64(framesRead)
                scan.lastSeq = seq
                let time = int64(object["timestamp_ms"]).flatMap(msDate)
                let payload = entry.value as? [String: Any] ?? [:]
                let prefix = String(seq)

                switch kind {
                case "user":
                    scan.turnOpen = true
                    if let user = userEvents(from: payload, idPrefix: prefix, time: time).first {
                        turnUserIndex = buildsEvents ? scan.events.count : nil
                        emit(.user, user)
                        if scan.firstPromptText == nil, let text = durableString(payload["text"]), !text.isEmpty {
                            scan.firstPromptText = text
                        }
                    } else {
                        turnUserIndex = nil
                    }

                case "steering":
                    // Typed by the user while the turn ran; a user message, never the title.
                    if let text = durableString(payload["text"]), !text.isEmpty {
                        emit(.user, event(idPrefix: prefix, suffix: "s", kind: .user, role: "user", text: text,
                                          messageID: nil, time: time, raw: line))
                    }

                case "assistant":
                    if let text = durableString(payload["text"]), !text.isEmpty {
                        emit(.assistant, event(idPrefix: prefix, suffix: "a", kind: .assistant, role: "assistant",
                                               text: text, messageID: nil, time: time, raw: line))
                    }

                case "tool_call":
                    emit(.tool_call, event(idPrefix: prefix, suffix: "t", kind: .tool_call, role: "assistant", text: nil,
                                           toolName: durableString(payload["tool_name"]),
                                           // `arguments_json` is already a JSON string on the wire.
                                           toolInput: durableString(payload["arguments_json"]),
                                           messageID: durableString(payload["call_id"]),
                                           time: time, raw: line))

                case "tool_result":
                    let created = int64(payload["created_at_ms"]).flatMap(msDate)
                    emit(.tool_result, event(idPrefix: prefix, suffix: "r", kind: .tool_result, role: "tool", text: nil,
                                             toolName: durableString(payload["tool_name"]),
                                             toolOutput: eventLogToolOutput(payload, sessionFile: url,
                                                                            readArtifact: readArtifacts),
                                             messageID: durableString(payload["call_id"]),
                                             time: created ?? time, raw: line))

                case "turn_completed", "interrupted":
                    scan.turnOpen = false
                    if let index = turnUserIndex,
                       let summary = payload["turn_summary"] as? [String: Any],
                       let started = int64(summary["started_at_ms"]).flatMap(msDate) {
                        scan.events[index] = retimed(scan.events[index], to: started)
                    }
                    turnUserIndex = nil
                    if kind == "interrupted" {
                        if let partial = durableString(payload["partial_text"]), !partial.isEmpty {
                            emit(.assistant, event(idPrefix: prefix, suffix: "p", kind: .assistant, role: "assistant",
                                                   text: partial, messageID: nil, time: time, raw: line))
                        }
                        var reason = payload["reason"] as? String ?? "interrupted"
                        if (payload["cancellation_origin"] as? String) == "compaction" { reason += " during compaction" }
                        emit(.meta, event(idPrefix: prefix, suffix: "i", kind: .meta, role: "system",
                                          text: "[interrupted: \(reason)]", messageID: nil, time: time, raw: line))
                    }

                case "context_checkpoint":
                    var lines: [String] = []
                    if let through = int64(payload["covers_through_seq"]) {
                        lines.append("[context compacted through event \(through)]")
                    } else {
                        lines.append("[context compacted]")
                    }
                    if let summary = durableString(payload["summary"]), !summary.isEmpty { lines.append(summary) }
                    emit(.meta, event(idPrefix: prefix, suffix: "c", kind: .meta, role: "system",
                                      text: lines.joined(separator: "\n"), messageID: nil, time: time, raw: line))

                default:
                    // A kind newer than this reader: keep it visible as metadata.
                    emit(.meta, event(idPrefix: prefix, suffix: "m", kind: .meta, role: kind,
                                      text: nil, messageID: nil, time: time, raw: line))
                }
                return true
            }
        } catch {
            return nil
        }
        return scan
    }

    /// The output of one schema-4 tool result. `preview` is the first 4 KiB;
    /// when the stored text is longer, the full parse reads it from
    /// `tool-results/<artifact_ref>`. A missing artifact leaves the preview
    /// with a truncation marker, as does a result fx stored only in part.
    private static func eventLogToolOutput(_ payload: [String: Any], sessionFile: URL, readArtifact: Bool) -> String? {
        var output = durableString(payload["preview"])
        let previewBytes = output?.utf8.count ?? 0
        let storedBytes = int(payload["stored_bytes"]) ?? previewBytes
        var cut = (payload["completeness"] as? String).map { $0 != "complete" } ?? false
        if storedBytes > previewBytes {
            if readArtifact, let full = readToolResultArtifact(payload["artifact_ref"], sessionFile: sessionFile) {
                output = full
            } else {
                cut = true
            }
        }
        if cut, output != nil { output! += "\n[truncated]" }
        return output
    }

    /// Reads `tool-results/<ref>` for a stored-text handle (`result-*.txt`).
    /// Other refs (command replay, compactor records) are framed or live
    /// elsewhere and are not opened; neither is anything that could leave the
    /// directory.
    private static func readToolResultArtifact(_ value: Any?, sessionFile: URL) -> String? {
        guard let ref = value as? String,
              ref.hasPrefix("result-"), ref.hasSuffix(".txt"),
              !ref.contains("/"), !ref.contains("\\"), !ref.contains("..") else { return nil }
        let url = sessionFile.deletingLastPathComponent()
            .appendingPathComponent("tool-results", isDirectory: true)
            .appendingPathComponent(ref, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxArtifactReadBytes) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if data.count >= maxArtifactReadBytes, (try? handle.read(upToCount: 1))?.isEmpty == false {
            text += "\n[truncated]"
        }
        return text
    }

    /// The uncommitted turn in `recovery.json`, rendered after the log.
    /// Valid only while its `conversation_seq` equals the log's last `seq`
    /// (fx's own rule in `loadConversationRecoveryCheckpoint`). When the log
    /// already opened that turn, only the marker is added.
    private static func recoveryEvents(for sessionFile: URL, after scan: EventLogScan) -> [SessionEvent] {
        let url = sessionFile.deletingLastPathComponent().appendingPathComponent("recovery.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversationSeq = int64(object["conversation_seq"]),
              conversationSeq == scan.lastSeq,
              let checkpoint = object["checkpoint"] as? [String: Any] else { return [] }

        let raw = String(decoding: data, as: UTF8.self)
        var out: [SessionEvent] = []
        if !scan.turnOpen {
            var turn: [String: Any] = [:]
            turn["user"] = checkpoint["user"]
            turn["execution"] = checkpoint["execution"]
            turn["assistant"] = checkpoint["assistant_source"]
            if let user = checkpoint["user"] as? [String: Any] {
                out.append(contentsOf: userEvents(from: user, idPrefix: "recovery"))
            }
            out.append(contentsOf: responseEvents(from: turn, idPrefix: "recovery"))
        }
        let cause = checkpoint["cause"] as? String ?? "unknown"
        out.append(event(idPrefix: "recovery", suffix: "x", kind: .meta, role: "system",
                         text: "[unsaved turn: \(cause)]", messageID: nil, raw: raw))
        return out
    }

    private static func retimed(_ event: SessionEvent, to time: Date) -> SessionEvent {
        SessionEvent(id: event.id, timestamp: time, kind: event.kind, role: event.role, text: event.text,
                     toolName: event.toolName, toolInput: event.toolInput, toolOutput: event.toolOutput,
                     messageID: event.messageID, parentID: event.parentID, isDelta: event.isDelta,
                     rawJSON: event.rawJSON)
    }

    // MARK: - Turn rendering

    /// One history entry becomes one user event plus whatever the response
    /// produced. Event ids are `"<turnIndex>-<suffix>"`; the turn index is the
    /// coordinate other tools can use to locate a record inside the checkpoint.
    /// Internal so tests can exercise a single turn without a file on disk.
    static func events(forTurn turn: [String: Any], turnIndex: Int) -> [SessionEvent] {
        let kind = turn["kind"] as? String ?? "unknown"
        let idPrefix = String(turnIndex)
        var out: [SessionEvent] = []

        if let user = turn["user"] as? [String: Any] {
            out.append(contentsOf: userEvents(from: user, idPrefix: idPrefix))
        }

        switch kind {
        case "assistant":
            out.append(contentsOf: responseEvents(from: turn, idPrefix: idPrefix))

        case "background_command":
            // A command the runtime moved to the background: the same body as
            // an ordinary turn (fx only appends `assistant`/`execution` once
            // there is something to record), plus where its output went.
            var detail: [String] = []
            if let logPath = durableString(turn["log_path"]), !logPath.isEmpty { detail.append("log \(logPath)") }
            if let url = durableString(turn["url"]), !url.isEmpty { detail.append(url) }
            let note = detail.isEmpty ? "[background command]"
                                      : "[background command — \(detail.joined(separator: " · "))]"
            out.append(event(idPrefix: idPrefix, suffix: "b", kind: .meta, role: "system",
                             text: note, messageID: nil, raw: jsonEncode(turn)))
            out.append(contentsOf: responseEvents(from: turn, idPrefix: idPrefix))

        case "compacted_summary":
            // The turn that replaces the history auto-compaction removed.
            // Rendering the summary is what keeps the gap from looking like a
            // session that simply started over.
            var lines: [String] = []
            let removed = int(turn["removed_turn_count"]) ?? 0
            let generation = int(turn["compaction_count"]) ?? 0
            lines.append("[context compacted: \(removed) earlier turn\(removed == 1 ? "" : "s") removed (compaction #\(generation))]")
            if let summary = durableString(turn["summary"]), !summary.isEmpty {
                lines.append(summary)
            }
            if let roots = turn["root_user_messages"] as? [String], !roots.isEmpty {
                lines.append("Original prompt(s):")
                lines.append(contentsOf: roots.map { "- \($0)" })
            }
            out.append(event(idPrefix: idPrefix, suffix: "c", kind: .meta, role: "system",
                             text: lines.joined(separator: "\n"), messageID: nil, raw: jsonEncode(turn)))

        case "interrupted":
            // A cancelled or failed turn. fx still records everything that
            // did happen before the cut: completed steps, any partial reply,
            // then the one call that never got its result.
            out.append(contentsOf: responseEvents(from: turn, idPrefix: idPrefix))
            if let call = turn["tool_call"] as? [String: Any] {
                out.append(toolCallEvent(from: call, idPrefix: idPrefix, suffix: "t"))
            }
            let reason = turn["terminal_reason"] as? String ?? "interrupted"
            var text = "[interrupted: \(reason)]"
            if turn["execution"] == nil,
               let completed = durableStrings(turn["completed_tool_names"]), !completed.isEmpty {
                // Degenerate shape: tools completed but their steps were not
                // persisted, so the names are the only surviving evidence.
                text = "[interrupted: \(reason) — completed: \(completed.joined(separator: ", "))]"
            }
            out.append(event(idPrefix: idPrefix, suffix: "i", kind: .meta, role: "system",
                             text: text, messageID: nil, raw: jsonEncode(turn)))

        default:
            out.append(event(idPrefix: idPrefix, suffix: "m", kind: .meta, role: kind,
                             text: nil, messageID: nil, raw: jsonEncode(turn)))
        }

        if out.isEmpty {
            out.append(event(idPrefix: idPrefix, suffix: "e", kind: .meta, role: kind,
                             text: nil, messageID: nil, raw: jsonEncode(turn)))
        }
        return out
    }

    /// The shared body of an agent turn — ordinary, background, or cut short:
    /// narrated tool steps with keyed calls and results, then the final (or,
    /// when interrupted, partial) reply.
    private static func responseEvents(from turn: [String: Any], idPrefix: String) -> [SessionEvent] {
        var out: [SessionEvent] = []
        if let execution = turn["execution"] as? [String: Any] {
            let steps = execution["tool_steps"] as? [[String: Any]] ?? []
            for (stepIndex, step) in steps.enumerated() {
                out.append(contentsOf: toolStepEvents(from: step, idPrefix: idPrefix, stepIndex: stepIndex))
            }
        }
        if let reply = durableString(turn["assistant"]), !reply.isEmpty {
            out.append(event(idPrefix: idPrefix, suffix: "a", kind: .assistant, role: "assistant", text: reply,
                             messageID: nil, raw: jsonEncode(turn)))
        }
        return out
    }

    /// `time` is nil for checkpoint history entries, which carry no time of
    /// their own; schema-4 frames pass theirs.
    private static func userEvents(from user: [String: Any], idPrefix: String, time: Date? = nil) -> [SessionEvent] {
        let text = durableString(user["text"])
        let images = user["images"] as? [[String: Any]] ?? []
        var rendered = text
        if !images.isEmpty {
            let markers = Array(repeating: "[image]", count: images.count).joined(separator: "\n")
            rendered = [markers, text].compactMap { $0 }.joined(separator: "\n")
        }
        guard let rendered, !rendered.isEmpty else { return [] }
        return [event(idPrefix: idPrefix, suffix: "u", kind: .user, role: "user", text: rendered,
                      messageID: nil, time: time, raw: jsonEncode(user))]
    }

    private static func toolStepEvents(from step: [String: Any], idPrefix: String, stepIndex: Int) -> [SessionEvent] {
        var out: [SessionEvent] = []
        if let narration = durableString(step["assistant"]), !narration.isEmpty {
            out.append(event(idPrefix: idPrefix, suffix: "s\(stepIndex)a", kind: .assistant, role: "assistant", text: narration,
                             messageID: nil, raw: jsonEncode(step)))
        }
        let calls = step["tool_calls"] as? [[String: Any]] ?? []
        for (callIndex, call) in calls.enumerated() {
            out.append(toolCallEvent(from: call, idPrefix: idPrefix, suffix: "s\(stepIndex)t\(callIndex)"))
        }
        let results = step["tool_results"] as? [[String: Any]] ?? []
        for (resultIndex, result) in results.enumerated() {
            out.append(toolResultEvent(from: result, idPrefix: idPrefix, suffix: "s\(stepIndex)r\(resultIndex)"))
        }
        return out
    }

    private static func toolCallEvent(from call: [String: Any], idPrefix: String, suffix: String) -> SessionEvent {
        event(idPrefix: idPrefix, suffix: suffix, kind: .tool_call, role: "assistant", text: nil,
              toolName: durableString(call["name"]),
              // `arguments_json` is already a JSON string on the wire.
              toolInput: durableString(call["arguments_json"]),
              toolOutput: nil,
              messageID: durableString(call["id"]),
              raw: jsonEncode(call))
    }

    private static func toolResultEvent(from result: [String: Any], idPrefix: String, suffix: String) -> SessionEvent {
        var output = durableString(result["output"])
        if output == nil, let preview = durableString(result["preview"]) { output = preview }
        if let truncated = result["truncated"] as? Bool, truncated, output != nil {
            output! += "\n[truncated]"
        }
        return event(idPrefix: idPrefix, suffix: suffix, kind: .tool_result, role: "tool", text: nil,
                     toolName: durableString(result["tool_name"]),
                     toolInput: nil,
                     toolOutput: output,
                     messageID: durableString(result["tool_call_id"]),
                     time: (result["created_at_ms"] as? NSNumber).flatMap { msDate($0.int64Value) },
                     raw: jsonEncode(result))
    }

    /// The genuine user prompt of a turn, for title derivation. Interrupted
    /// turns still carry a real prompt, so they qualify like any other.
    private static func promptText(fromTurn turn: [String: Any]) -> String? {
        guard let user = turn["user"] as? [String: Any] else { return nil }
        return durableString(user["text"])
    }

    // MARK: - Sidecars

    private static func readSidecar(for url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: FxSessionDiscovery.sidecarFile(forSessionFile: url)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Sidecar(object: object)
    }

    private static func readCheckpoint(for url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// `display.json` holds the CLI-generated title/preview pair. It may be
    /// absent (`display_metadata_present: false` in the shared index); the
    /// first user prompt takes over then.
    private static func readDisplayTitle(for url: URL) -> String? {
        let path = url.deletingLastPathComponent().appendingPathComponent("display.json", isDirectory: false)
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Helpers

    /// Ids are `"<prefix>-<suffix>"`: the history-turn index for a checkpoint,
    /// the frame `seq` for an event log, `recovery` for `recovery.json`.
    private static func event(idPrefix: String,
                              suffix: String,
                              kind: SessionEventKind,
                              role: String?,
                              text: String?,
                              toolName: String? = nil,
                              toolInput: String? = nil,
                              toolOutput: String? = nil,
                              messageID: String?,
                              time: Date? = nil,
                              raw: String) -> SessionEvent {
        SessionEvent(id: "\(idPrefix)-\(suffix)", timestamp: time, kind: kind, role: role, text: text,
                     toolName: toolName, toolInput: toolInput, toolOutput: toolOutput,
                     messageID: messageID, parentID: nil, isDelta: false, rawJSON: raw)
    }

    /// fx timestamps are epoch milliseconds, like OpenCode's and unlike Devin's seconds.
    private static func msDate(_ ms: Int64) -> Date? {
        ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1_000.0) : nil
    }

    /// JSON booleans must be rejected before numeric reads — but Foundation's
    /// dynamic casting answers `true` to `jsonOne is Bool` for the integer 1,
    /// so discriminate by CFType: only a genuine `__NSCFBoolean` carries
    /// CFBoolean's type ID. Without this, every fx field whose honest value is
    /// exactly 1 (`history_len: 1`, `compaction_count: 1`, …) reads as absent.
    private static func isJSONBool(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Reads a field fx wrote through its durable-bytes encoder: a plain JSON
    /// string when the bytes were valid UTF-8, else an
    /// `{"encoding": "base64", "data": …}` object. The object form decodes
    /// back to text, or to an honest marker when the bytes are not text at
    /// all. Without this, one non-UTF-8 byte in a tool result answered nil to
    /// `as? String` and the whole field vanished — prompt, reply, output, or
    /// the id a result is keyed back to its call by. Two binary ids decode to
    /// the same marker, so call/result keying survives even there.
    private static func durableString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any],
              (object["encoding"] as? String) == "base64",
              let encoded = object["data"] as? String,
              let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8) ?? "[binary output]"
    }

    /// `durableString` across a list — `completed_tool_names[]`. Elements that
    /// decode drop out; plain strings pass through untouched.
    private static func durableStrings(_ value: Any?) -> [String]? {
        (value as? [Any])?.compactMap { durableString($0) }
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !isJSONBool(value) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value, !isJSONBool(value) else { return nil }
        return (value as? NSNumber)?.int64Value
    }

    private static func jsonEncode(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
}
