import Foundation

enum SearchCoverageReason: String, Hashable, Sendable {
    case sourceChanged, unavailable, unsupportedFormat, malformedRecord, omittedRecord, resourceLimit, cancelled
}

struct SearchSourceRevision: Equatable, Sendable {
    struct File: Equatable, Sendable { let path: String; let stat: SessionFileStat }
    var files: [File] = []
    var logical: String? = nil
    let format = 1
}

struct SearchScanSummary: Sendable {
    var revision: SearchSourceRevision?
    var reasons: Set<SearchCoverageReason> = []
    var bytesRead: UInt64 = 0
    var decompressedBytes: UInt64 = 0
    var records: Int = 0
    var messages: Int = 0
    var commands: Int = 0
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var peakPayloadCharge: Int = 0
    var complete: Bool { reasons.isEmpty && revision != nil }
}

struct SearchScanResult: Sendable {
    let key: SearchCoordinator.SessionKey
    let truth: SearchQuery.Truth
    let summary: SearchScanSummary
    let snippet: String?
}

/// Each lane owns one worker through physical cleanup, including cancellation during OS I/O.
actor SearchScanAdmission {
    static let shared = SearchScanAdmission()
    enum Lane: Hashable, Sendable { case foreground, ingestion }
    private var occupied: Set<Lane> = []
    private var waiters: [Lane: [(UUID, CheckedContinuation<Bool, Never>)]] = [:]

    func acquire(_ lane: Lane) async -> Bool {
        if Task.isCancelled { return false }
        if occupied.insert(lane).inserted { return true }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[lane, default: []].append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancel(id, lane: lane) } })
    }
    private func cancel(_ id: UUID, lane: Lane) {
        guard let index = waiters[lane]?.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiters[lane]!.remove(at: index)
        waiter.1.resume(returning: false)
    }
    func release(_ lane: Lane) {
        if var queue = waiters[lane], !queue.isEmpty {
            let next = queue.removeFirst(); waiters[lane] = queue; next.1.resume(returning: true)
        } else { occupied.remove(lane) }
    }
}

/// Bounded scanner primitives shared by foreground verification and sampled index ingestion.
enum SearchSourceScanner {
    static let chunkBytes = 64 * 1024
    static let recordBytes = 8 * 1024 * 1024
    static let payloadBytes = 64 * 1024 * 1024
    private static let lineFeed = Data([0x0A])
    enum Failure: Error { case resourceLimit, malformed, unsupported, changed }

    static func scan(session: Session, query: SearchQuery) async -> SearchScanResult {
        let metrics = SearchResponsivenessMetrics.shared
        let parent = SearchMetricScope.requestID
        let operation = metrics.newOperationID()
        let context = SearchResponsivenessMetricContext.session(session)
        let queued = metrics.beginSpan(.searchScanQueued, parentID: parent, operationID: operation, context: context)
        guard await SearchScanAdmission.shared.acquire(.foreground) else {
            if let queued { metrics.cancel(queued) }
            return .init(key: .init(session), truth: .unknown, summary: .init(reasons: [.cancelled]), snippet: nil)
        }
        if let queued { metrics.end(queued) }
        let worker = Task.detached(priority: .userInitiated) { () -> SearchScanResult in
            let span = metrics.beginSpan(.searchExtraction, parentID: parent, operationID: operation, context: context)
            defer { if let span { Task.isCancelled ? metrics.cancel(span) : metrics.end(span) } }
            metrics.record(.searchScanStarted, operationID: operation, parentID: parent, context: context, status: .started)
            do {
                let tokenizer = try SearchTokenizer()
                // Retry creates fresh evidence: a mixture of two revisions is never reusable.
                var last = SearchScanResult(key: .init(session), truth: .unknown, summary: .init(reasons: [.unavailable]), snippet: nil)
                for attempt in 0...1 {
                    try Task.checkCancellation()
                    let predicate = SearchPredicateAccumulator(query: query, tokenizer: tokenizer)
                    var snippet: String?
                    let summary = scanSegments(session: session) { segment in
                        let before = predicate.witnesses.count
                        try metrics.measured(.searchMatching, operationID: operation, parentID: parent, context: context) { try predicate.consume(field: segment.text) }
                        if snippet == nil, predicate.witnesses.count > before {
                            snippet = String(decoding: segment.text.utf16.prefix(512), as: UTF16.self)
                        }
                    }
                    metrics.record(.searchCoverageCounters, operationID: operation, parentID: parent, context: context,
                        status: summary.complete ? .succeeded : .partial,
                        counters: [.physicalBytes: Int64(summary.bytesRead), .decodedBytes: Int64(summary.decompressedBytes),
                                   .recordsVisited: Int64(summary.records), .retainedPayloadBytes: Int64(summary.peakPayloadCharge)])
                    for reason in summary.reasons {
                        let omission: SearchResponsivenessOmissionReason
                        switch reason {
                        case .sourceChanged: omission = .sourceChanged
                        case .cancelled: omission = .cancelled
                        case .resourceLimit, .omittedRecord: omission = .oversized
                        case .malformedRecord: omission = .malformed
                        case .unsupportedFormat: omission = .unsupported
                        case .unavailable: omission = .readError
                        }
                        metrics.recordOmission(omission, operationID: operation, parentID: parent, context: context)
                    }
                    if summary.reasons.contains(.sourceChanged), attempt == 0 {
                        metrics.record(.searchSourceRevisionRetry, operationID: operation, parentID: parent, context: context,
                                       counters: [.sourceChangedRetries: 1])
                    }
                    let stable = summary.revision != nil && !summary.reasons.contains(.sourceChanged)
                    last = .init(key: .init(session), truth: stable ? predicate.truth(complete: summary.complete) : .unknown,
                                 summary: summary, snippet: stable ? snippet : nil)
                    if !summary.reasons.contains(.sourceChanged) || attempt == 1 { return last }
                }
                return last
            } catch {
                return .init(key: .init(session), truth: .unknown,
                             summary: .init(reasons: [Task.isCancelled ? .cancelled : .unavailable]), snippet: nil)
            }
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        metrics.record(.searchWorkerAcknowledged, operationID: operation, parentID: parent, context: context, status: Task.isCancelled ? .cancelled : .succeeded)
        await SearchScanAdmission.shared.release(.foreground)
        return result
    }

    static func count(_ event: SessionEvent, into summary: inout SearchScanSummary) {
        if event.kind != .meta { summary.messages += 1 }
        if event.kind == .tool_call { summary.commands += 1 }
        if let time = event.timestamp {
            summary.firstTimestamp = summary.firstTimestamp.map { min($0, time) } ?? time
            summary.lastTimestamp = summary.lastTimestamp.map { max($0, time) } ?? time
        }
    }

    /// Synchronous worker entry point. Caller holds a scan permit; no Session is retained.
    static func scanSegments(session: Session, stopAtIncomplete: Bool = false,
                             consume: (SearchTextSegment) throws -> Void) -> SearchScanSummary {
        var summary = SearchScanSummary()
        do {
            try Task.checkCancellation()
            for (kind, text) in [(SearchTextSegment.Kind.title, session.listTitle), (.repository, session.repoName ?? ""), (.repository, session.cwd ?? "")] where !text.isEmpty {
                try consume(.init(source: session.source, eventID: "metadata", kind: kind, text: text, provenance: .source))
            }
            switch session.source {
            case .codex, .claude:
                try scanJSONL(session: session, summary: &summary, stopAtIncomplete: stopAtIncomplete,
                              consume: consume)
            case .opencode, .hermes, .devin:
                if session.source.descriptor.searchUsesIdentityAtURL?(URL(fileURLWithPath: session.filePath)) == true {
                    try scanDatabase(session: session, summary: &summary, consume: consume)
                } else { try scanBoundedFiles(session: session, summary: &summary, consume: consume) }
            case .antigravity, .copilot, .droid, .pi, .kimi, .grok, .qwen, .fx, .cline, .deepseekHarness:
                try scanBoundedFiles(session: session, summary: &summary, consume: consume)
            case .cursor:
                if CursorACPStoreReader.isACPStore(URL(fileURLWithPath: session.filePath)) {
                    try scanBoundedFiles(session: session, summary: &summary, consume: consume)
                } else { try scanJSONL(session: session, summary: &summary, consume: consume) }
            case .openclaw:
                if OpenClawSqliteReader.isSupportedDatabaseURL(URL(fileURLWithPath: session.filePath)) {
                    try scanDatabase(session: session, summary: &summary, consume: consume)
                } else { try scanJSONL(session: session, summary: &summary, consume: consume) }
            }
        } catch is CancellationError { summary.reasons.insert(.cancelled) }
        catch SearchTokenizer.Failure.resourceLimit { summary.reasons.insert(.resourceLimit) }
        catch Failure.resourceLimit { summary.reasons.insert(.resourceLimit) }
        catch Failure.malformed { summary.reasons.insert(.malformedRecord) }
        catch Failure.unsupported { summary.reasons.insert(.unsupportedFormat) }
        catch Failure.changed { summary.reasons.insert(.sourceChanged) }
        catch { summary.reasons.insert(.unavailable) }
        return summary
    }

    private static func scanJSONL(session: Session, summary: inout SearchScanSummary,
                                  stopAtIncomplete: Bool = false,
                                  consume: (SearchTextSegment) throws -> Void) throws {
        let logicalURL = URL(fileURLWithPath: session.filePath).standardizedFileURL
        let url = session.source == .codex ? (CodexRolloutStorage.storageURL(for: logicalURL) ?? logicalURL) : logicalURL
        let decoder = CodexRolloutStorage.isCompressedRollout(url)
            ? ZstdStreamDecoder(maximumWindowLog: 23, inputChunkSize: chunkBytes) : nil
        let handle = try FileHandle(forReadingFrom: url)
        let descriptor = handle.fileDescriptor
        defer { try? handle.close() }
        guard let before = SessionFileStat.precise(fromFileDescriptor: descriptor) else { throw Failure.changed }
        let revision = SearchSourceRevision(files: [.init(path: url.resolvingSymlinksInPath().path, stat: before)])
        var buffer = Data(), skipping = false
        var openClaw = OpenClawSessionParser.ParseAccumulator()
        func record(_ data: Data) throws {
            try Task.checkCancellation()
            guard !data.isEmpty else { return }
            summary.records += 1
            let charge = try validateJSON(data)
            let totalCharge = charge + (decoder == nil ? 0 : 9 * 1024 * 1024)
            guard totalCharge <= payloadBytes else { throw Failure.resourceLimit }
            summary.peakPayloadCharge = max(summary.peakPayloadCharge, totalCharge)
            guard let line = String(data: data, encoding: .utf8) else { throw Failure.malformed }
            let events: [SessionEvent]
            if session.source == .codex {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed }
                events = [SessionIndexer.parseLine(line, eventID: "search-\(summary.records)", parsedObject: object).0]
            } else {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed }
                switch session.source {
                case .claude:
                    if ClaudeSessionParser.isRequestLogRecord(object) { return }
                    events = ClaudeSessionParser.parseLineEvents(object, baseEventID: "search-\(summary.records)", forSearch: true)
                case .cursor:
                    events = CursorSessionParser.parseLineEvents(object, baseEventID: "search-\(summary.records)", forSearch: true)
                case .openclaw:
                    openClaw.events.removeAll(keepingCapacity: false)
                    OpenClawSessionParser.appendRecord(object, url: url, index: summary.records, into: &openClaw, forSearch: true)
                    events = openClaw.events
                default: throw Failure.unsupported
                }
            }
            for event in events {
                count(event, into: &summary)
                for segment in SearchSourceText.segments(event: event, source: session.source) { try consume(segment) }
            }
            openClaw.events.removeAll(keepingCapacity: false)
        }
        readLoop: while true {
            try Task.checkCancellation()
            let chunk: Data
            if let decoder {
                chunk = try decoder.read(from: handle, upTo: chunkBytes)
                summary.bytesRead = decoder.physicalBytesRead
            } else {
                chunk = try handle.read(upToCount: chunkBytes) ?? Data()
                summary.bytesRead += UInt64(chunk.count)
            }
            summary.decompressedBytes += UInt64(chunk.count)
            if chunk.isEmpty { break }
            var start = chunk.startIndex
            while let delimiter = chunk.range(of: lineFeed, in: start..<chunk.endIndex) {
                let index = delimiter.lowerBound
                let count = chunk.distance(from: start, to: index)
                if !skipping, buffer.count + count <= recordBytes {
                    let line = chunk[start..<index]
                    if !buffer.isEmpty { buffer.append(contentsOf: line) }
                    do { try autoreleasepool { try record(buffer.isEmpty ? line : buffer) } }
                    catch Failure.resourceLimit { summary.reasons.insert(.resourceLimit) }
                    catch Failure.malformed { summary.reasons.insert(.malformedRecord) }
                } else { summary.reasons.insert(.omittedRecord) }
                if stopAtIncomplete && !summary.reasons.isEmpty { break readLoop }
                buffer.removeAll(keepingCapacity: false)
                skipping = false
                start = delimiter.upperBound
            }
            if start < chunk.endIndex, !skipping {
                if buffer.count + chunk.distance(from: start, to: chunk.endIndex) <= recordBytes {
                    buffer.append(contentsOf: chunk[start...])
                } else {
                    buffer.removeAll(keepingCapacity: false)
                    skipping = true
                    summary.reasons.insert(.resourceLimit)
                    if stopAtIncomplete { break }
                }
            }
        }
        if !buffer.isEmpty, !skipping, !stopAtIncomplete || summary.reasons.isEmpty {
            do { try autoreleasepool { try record(buffer) } }
            catch Failure.resourceLimit { summary.reasons.insert(.resourceLimit) }
            catch Failure.malformed { summary.reasons.insert(.malformedRecord) }
        }
        guard SessionFileStat.precise(fromFileDescriptor: descriptor) == before,
              SessionFileStat.precise(from: url) == before,
              session.source != .codex || CodexRolloutStorage.storageURL(for: logicalURL) == url else { throw Failure.changed }
        summary.revision = revision
    }

    /// Preflight before Foundation/provider object allocation. The conservative charge includes
    /// UTF-16 expansion, raw/semantic copies, container storage and tokenizer scratch.
    @discardableResult
    static func validateJSON(_ data: Data) throws -> Int {
        guard data.count <= recordBytes else { throw Failure.resourceLimit }
        var depth = 0, nodes = 0, string = false, escaped = false

        for (index, byte) in data.enumerated() {
            if index % chunkBytes == 0 { try Task.checkCancellation() }
            if string {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { string = false }
                continue
            }
            switch byte {
            case 34: string = true; nodes += 1
            case 91, 123: depth += 1; nodes += 1
            case 93, 125: depth -= 1
            case 44, 58: nodes += 1
            default: break
            }
            guard depth >= 0 else { throw Failure.malformed }
            guard depth <= 64, nodes <= 65_536 else { throw Failure.resourceLimit }
        }
        guard !string, depth == 0 else { throw Failure.malformed }
        let charge = data.count * 24 + nodes * 512 + chunkBytes * 2
        guard charge <= payloadBytes else { throw Failure.resourceLimit }
        return charge
    }
}
