import Foundation
import SQLite3
import CryptoKit

private struct OpenCodeTelemetryMessageRow {
    let id: String
    let observedAt: Date?
    let role: String?
    let model: String?
    let reasoningEffort: String?
    let object: [String: Any]
    let malformedPayload: Bool
    let bytesScanned: UInt64
}

private struct OpenCodeTelemetryPartRow {
    let id: String
    let messageID: String
    let observedAt: Date?
    let object: [String: Any]
    let malformedPayload: Bool
    let bytesScanned: UInt64
    /// The v1 part row's `time_updated`. A v1 step-finish part is written when its
    /// request finishes, so this is the completion fallback. nil for v2 rows, whose
    /// adapter records completion in the part object.
    var updatedAt: Date? = nil
}

private struct OpenCodeTelemetryUsageRow {
    let id: String
    let observedAt: Date?
    /// Timestamp of the owning message, used for fork attribution. OpenCode
    /// may rewrite cloned part timestamps while copying fork history, so a
    /// step-finish part's own timestamp is not a safe attribution boundary.
    let attributionAt: Date?
    let model: String?
    let reasoningEffort: String?
    let tokens: [String: Any]
    let usageFamily: String
    var completedAt: Date? = nil
}

private struct OpenCodeTelemetryRows<Row> {
    let rows: [Row]
    let cancelled: Bool
    let malformedPayload: Bool
}

private struct OpenCodeTelemetrySessionMetadata {
    let hasModelColumn: Bool
    let model: String?
    let updatedAt: Date?
    let createdAt: Date?
    let parentID: String?
}

/// Read-only adapter for OpenCode's opencode.db SQLite database (v1.2+).
///
/// Opens the database per call using SQLITE_OPEN_READONLY to avoid WAL lock
/// contention with the running OpenCode process. No writes, no migrations.
struct OpenCodeSqliteReader {

    // MARK: - Session list (lightweight, no events)

    /// Returns all non-archived sessions ordered by time_updated descending.
    static func listSessions(customRoot: String?) -> [Session] {
        listSessionsIfReadable(customRoot: customRoot) ?? []
    }

    /// nil distinguishes an open/prepare/step failure from an authoritative empty list.
    static func listSessionsIfReadable(customRoot: String?) -> [Session]? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard hasV2Store(db) else {
            return querySessionList(db: db, dbPath: url.path)
        }
        let hasV1Store = tableExists(db, table: "session")
        // Pick the store for each ID first, over all rows including archived
        // ones, with the same rule as v2SessionExists. Each store's list query
        // then drops its own archived rows, so a session archived in the
        // chosen store stays hidden even when the other store's copy is not
        // archived, and listing agrees with full loading.
        guard let v2IDs = v2PreferredSessionIDs(db, hasV1Store: hasV1Store),
              let v2Sessions = querySessionListV2(db: db, dbPath: url.path) else { return nil }
        // A database with only the v2 store has no v1 rows to merge. A v1 store
        // that exists but cannot be read is a failure, not an empty store:
        // returning only the v2 rows would hide every uncopied v1 session.
        let v1Sessions: [Session]
        if hasV1Store {
            guard let rows = querySessionList(db: db, dbPath: url.path) else { return nil }
            v1Sessions = rows
        } else {
            v1Sessions = []
        }
        return (v2Sessions.filter { v2IDs.contains($0.id) } + v1Sessions.filter { !v2IDs.contains($0.id) })
            .sorted { ($0.endTime ?? .distantPast) > ($1.endTime ?? .distantPast) }
    }

    // MARK: - Full session (with transcript events)

    /// Returns a Session with fully loaded events for the given session ID.
    static func loadFullSession(customRoot: String?, sessionID: String) -> Session? {
        loadFullSession(customRoot: customRoot, sessionID: sessionID, afterV2Row: nil)
    }

    /// Test seam: `afterV2Row` runs after each OpenCode 2.x `session_message`
    /// row is read, so a test can cancel mid-scan at a known row. Production
    /// callers use the overload above.
    static func loadFullSession(customRoot: String?,
                                sessionID: String,
                                afterV2Row: ((Int) -> Void)?) -> Session? {
        let metricIdentity = SessionInfoMetricsIdentity(source: .opencode, sessionID: sessionID)
        SessionInfoMetrics.shared.beginTranscript(identity: metricIdentity)
        defer { SessionInfoMetrics.shared.endTranscript(identity: metricIdentity) }
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return queryFullSession(db: db, sessionID: sessionID, dbPath: url.path, afterV2Row: afterV2Row)
    }

    // MARK: - Freshness probe

    /// Returns the session's `time_updated` without loading any parts. Used to decide
    /// whether a hydrated transcript snapshot is stale while OpenCode is still writing.
    static func sessionUpdatedAt(customRoot: String?, sessionID: String) -> Date? {
        let url = OpenCodeBackendDetector.dbURL(customRoot: customRoot)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let table = v2SessionExists(db, sessionID: sessionID) ? "session_v2" : "session"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT time_updated FROM \(table) WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let millis = sqlite3_column_int64(stmt, 0)
        return millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000.0) : nil
    }

    // MARK: - Telemetry backend

    /// Returns a logical revision for one SQLite session. The revision is
    /// intentionally independent of the database file's stat so committed WAL
    /// writes invalidate telemetry even when the main database file is unchanged.
    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard session.source == .opencode,
              URL(fileURLWithPath: session.filePath).lastPathComponent == "opencode.db" else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(session.filePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        guard let revision = logicalRevision(db: db, sessionID: session.id) else { return nil }
        return .logical(revision)
    }

    /// Scans only the selected session's SQLite rows. OpenCode's durable
    /// request-level usage lives in `step-finish` parts; message tokens are a
    /// compatibility fallback for older databases that have no usable parts.
    /// SQLite owns the storage format; the telemetry engine still owns cache,
    /// pricing, and publication policy.
    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        loadTelemetry(for: session, afterRowsLoaded: nil)
    }

    /// Test seam invoked after the selected message/part rows have been read
    /// and their byte count is known, but before usage/configuration reduction.
    /// Production callers use the overload above so this cannot affect normal
    /// telemetry behavior.
    static func loadTelemetry(
        for session: Session,
        afterRowsLoaded: (@Sendable () -> Void)?
    ) -> SessionTelemetryProviderScan? {
        guard session.source == .opencode,
              URL(fileURLWithPath: session.filePath).lastPathComponent == "opencode.db" else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(session.filePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        let isV2 = v2SessionExists(db, sessionID: session.id)
        let metadata: OpenCodeTelemetrySessionMetadata
        let messageScan: OpenCodeTelemetryRows<OpenCodeTelemetryMessageRow>
        let partScan: OpenCodeTelemetryRows<OpenCodeTelemetryPartRow>
        if isV2 {
            guard let v2Metadata = queryTelemetrySessionMetadataV2(db: db, sessionID: session.id),
                  let v2Scan = queryTelemetryV2(db: db, sessionID: session.id) else { return nil }
            metadata = v2Metadata
            messageScan = v2Scan.messages
            partScan = v2Scan.parts
        } else {
            guard let v1Metadata = queryTelemetrySessionMetadata(db: db, sessionID: session.id),
                  let v1Messages = queryTelemetryMessages(db: db, sessionID: session.id),
                  let v1Parts = queryTelemetryParts(db: db, sessionID: session.id) else { return nil }
            metadata = v1Metadata
            messageScan = v1Messages
            partScan = v1Parts
        }
        let messages = messageScan.rows
        let parts = partScan.rows

        struct SliceKey: Hashable {
            let model: String?
            let reasoningEffort: String?
            let speed: String
        }

        let bytesScanned = messages.reduce(0) { $0 + $1.bytesScanned }
            + parts.reduce(0) { $0 + $1.bytesScanned }
        if messageScan.cancelled || partScan.cancelled {
            return cancelledTelemetryScan(bytesScanned: bytesScanned)
        }
        afterRowsLoaded?()
        let messageByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var stepFinishCount = 0
        var malformedStepFinish = false
        var stepUsage: [OpenCodeTelemetryUsageRow] = []
        for part in parts {
            guard let type = stringValue(part.object["type"]),
                  type.lowercased() == "step-finish" else { continue }
            stepFinishCount += 1
            guard let tokens = completeStepFinishTokenObject(from: part.object) else {
                malformedStepFinish = true
                continue
            }
            let message = messageByID[part.messageID]
            stepUsage.append(OpenCodeTelemetryUsageRow(
                id: part.id,
                observedAt: part.observedAt ?? message?.observedAt,
                attributionAt: message?.observedAt,
                model: modelID(from: part.object) ?? message?.model,
                reasoningEffort: reasoningEffort(from: part.object) ?? message?.reasoningEffort,
                tokens: tokens,
                usageFamily: "opencode.step-finish.tokens",
                completedAt: completionDate(of: part)))
        }
        // v2 assistant rows carry their usage directly; the adapter turns each
        // into a step-finish row, so v2 behaves like a database with parts.
        let hasPartTable = isV2 || tableExists(db, table: "part")
        let rawUsageRows: [OpenCodeTelemetryUsageRow]
        var usageUnavailableReason: String?
        if messageScan.malformedPayload || partScan.malformedPayload {
            // An undecodable row may hide a usage record, a message timestamp,
            // or configuration evidence. Do not present the readable subset as
            // a complete session total.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode telemetry is unavailable because one or more stored JSON records is malformed."
        } else if stepFinishCount > 0 && malformedStepFinish {
            // Never present the valid subset as the session total. One malformed
            // step-finish record means the provider's request-level accounting is
            // incomplete, even if neighboring records are readable.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode step-finish usage is incomplete because one or more records are malformed or missing required token components."
        } else if !stepUsage.isEmpty {
            rawUsageRows = stepUsage
        } else if !hasPartTable {
            // Pre-step-finish databases have no part table. Their assistant
            // message tokens are the only available usage evidence.
            rawUsageRows = messages.compactMap { message in
                guard message.role?.lowercased() == "assistant",
                      let tokens = tokenObject(from: message.object) else { return nil }
                return OpenCodeTelemetryUsageRow(
                    id: message.id,
                    observedAt: message.observedAt,
                    attributionAt: message.observedAt,
                    model: message.model,
                    reasoningEffort: message.reasoningEffort,
                    tokens: tokens,
                    usageFamily: "opencode.message.tokens")
            }
        } else {
            // A modern database has a part table, but without a usable
            // step-finish record there is no trustworthy request-level total.
            // Keep that distinction in the result instead of collapsing it into
            // the same empty state as a transcript that truly used no tokens.
            rawUsageRows = []
            usageUnavailableReason = "OpenCode parts contain no usable step-finish usage record."
        }

        // OpenCode forks clone the parent's messages and parts into a new
        // session. Those rows are inherited history, not usage produced by
        // the fork. The fork path does not reliably populate parent_id, so the
        // session creation timestamp is the attribution boundary whenever the
        // schema provides it. If an explicitly parented schema cannot provide
        // that boundary, fail closed instead of presenting an inflated total.
        var usageRows = rawUsageRows
        if let forkBoundary = metadata.createdAt {
            usageRows = rawUsageRows.filter { row in
                guard let attributionAt = row.attributionAt else { return false }
                return attributionAt >= forkBoundary
            }
            if rawUsageRows.contains(where: { $0.attributionAt == nil }) {
                usageUnavailableReason = "Some OpenCode usage could not be attributed to this fork."
            }
        } else if metadata.parentID != nil {
            usageRows = []
            usageUnavailableReason = "OpenCode fork usage is unavailable because the session creation boundary is missing."
        }

        var changes: [ConfigurationChange] = []
        var initialConfiguration: SessionConfiguration?
        var effectiveModel: String?
        var effectiveReasoningEffort: String?
        var modelObservedAt: Date?
        var modelAnchorLine: Int?
        var reasoningObservedAt: Date?
        var reasoningAnchorLine: Int?

        func observeAssistantConfiguration(model: String?,
                                           reasoningEffort: String?,
                                           date: Date?,
                                           anchor: Int) {
            guard model != nil || reasoningEffort != nil else { return }
            let oldModel = effectiveModel
            let oldReasoning = effectiveReasoningEffort
            if let model, model != effectiveModel {
                if let oldModel {
                    changes.append(ConfigurationChange(
                        field: .model, oldValue: oldModel, newValue: model,
                        observedAt: date, anchorLine: anchor, provenance: .assistantRecord))
                }
                effectiveModel = model
                modelObservedAt = date
                modelAnchorLine = anchor
            }
            if let reasoningEffort, reasoningEffort != effectiveReasoningEffort {
                if let oldReasoning {
                    changes.append(ConfigurationChange(
                        field: .reasoningEffort, oldValue: oldReasoning,
                        newValue: reasoningEffort, observedAt: date,
                        anchorLine: anchor, provenance: .assistantRecord))
                }
                effectiveReasoningEffort = reasoningEffort
                reasoningObservedAt = date
                reasoningAnchorLine = anchor
            }
            let configuration = SessionConfiguration(
                model: effectiveModel,
                reasoningEffort: effectiveReasoningEffort,
                observedAt: date,
                anchorLine: anchor,
                provenance: .inferredFirstObservation,
                modelObservedAt: modelObservedAt,
                modelAnchorLine: modelAnchorLine,
                modelProvenance: effectiveModel == nil ? nil : .assistantRecord,
                reasoningEffortObservedAt: reasoningObservedAt,
                reasoningEffortAnchorLine: reasoningAnchorLine,
                reasoningEffortProvenance: effectiveReasoningEffort == nil ? nil : .assistantRecord)
            initialConfiguration = initialConfiguration ?? configuration
        }

        let configurationMessages: [OpenCodeTelemetryMessageRow]
        if messageScan.malformedPayload {
            // A readable suffix cannot establish the first observation or a
            // complete change history when an earlier message may be missing
            // its model or reasoning fields. Session metadata remains an
            // independent source for the current model below.
            configurationMessages = []
        } else if let forkBoundary = metadata.createdAt {
            configurationMessages = messages.filter { message in
                guard let observedAt = message.observedAt else { return false }
                return observedAt >= forkBoundary
            }
        } else if metadata.parentID != nil {
            // Usage already fails closed above when a fork has no creation
            // boundary. Configuration must not leak inherited model/effort
            // observations into the child either.
            configurationMessages = []
        } else {
            configurationMessages = messages
        }
        for (index, message) in configurationMessages.enumerated()
            where message.role?.lowercased() == "assistant" {
            observeAssistantConfiguration(
                model: message.model,
                reasoningEffort: message.reasoningEffort,
                date: message.observedAt,
                anchor: index)
        }

        // A current schema's model column is authoritative even when its value
        // is NULL or malformed. Old schemas have no such column and therefore
        // retain the last assistant observation as their best current evidence.
        let metadataModel = metadata.hasModelColumn ? metadata.model : nil
        if let metadataModel, let effectiveModel, metadataModel != effectiveModel {
            changes.append(ConfigurationChange(
                field: .model,
                oldValue: effectiveModel,
                newValue: metadataModel,
                observedAt: metadata.updatedAt,
                anchorLine: messages.count,
                provenance: .sessionMetadata))
        }
        let currentModel = metadata.hasModelColumn ? metadataModel : effectiveModel
        let currentFromMetadata = metadata.hasModelColumn
        let currentConfiguration: SessionConfiguration? = if currentModel != nil || effectiveReasoningEffort != nil {
            SessionConfiguration(
                model: currentModel,
                reasoningEffort: effectiveReasoningEffort,
                observedAt: currentFromMetadata ? metadata.updatedAt : (modelObservedAt ?? reasoningObservedAt),
                anchorLine: currentFromMetadata ? messages.count : max(messages.count - 1, 0),
                provenance: currentFromMetadata ? .sessionMetadata : .assistantRecord,
                modelObservedAt: currentFromMetadata ? metadata.updatedAt : modelObservedAt,
                modelAnchorLine: currentFromMetadata ? messages.count : modelAnchorLine,
                modelProvenance: currentModel == nil
                    ? nil
                    : (currentFromMetadata ? .sessionMetadata : .assistantRecord),
                reasoningEffortObservedAt: reasoningObservedAt,
                reasoningEffortAnchorLine: reasoningAnchorLine,
                reasoningEffortProvenance: effectiveReasoningEffort == nil ? nil : .assistantRecord)
        } else {
            nil
        }

        var events: [TelemetryUsageEvent] = []
        var slices: [SliceKey: TelemetryUsageSlice] = [:]
        var recordedTotalTokens = 0
        var hasRecordedTotal = false
        var displayTotalTokens = 0
        var hasDisplayTotal = false
        var hasComponentBreakdown = true
        var topLineTokens = 0
        for (index, row) in usageRows.enumerated() {
            guard !Task.isCancelled else {
                return cancelledTelemetryScan(bytesScanned: bytesScanned)
            }
            let tokens = row.tokens
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            guard let input = optionalNonNegativeInteger(tokens["input"]),
                  let cacheRead = optionalNonNegativeInteger(cache["read"] ?? tokens["cacheRead"]),
                  let cacheWrite = optionalNonNegativeInteger(cache["write"] ?? tokens["cacheWrite"]),
                  let storedOutput = optionalNonNegativeInteger(tokens["output"]),
                  let reasoning = optionalNonNegativeInteger(tokens["reasoning"]) else {
                usageUnavailableReason = "OpenCode usage is unavailable because a token component is malformed or out of range."
                break
            }
            // OpenCode stores output excluding reasoning; the common model stores
            // reasoning as a subset of output, so normalize before aggregation.
            guard let output = adding(storedOutput, reasoning),
                  let baseContextInput = adding(input, cacheRead),
                  let contextInput = adding(baseContextInput, cacheWrite),
                  let rowTopLineTokens = adding(contextInput, output) else {
                usageUnavailableReason = "OpenCode usage is unavailable because token totals exceed the supported integer range."
                break
            }
            guard let updatedTopLineTokens = adding(topLineTokens, rowTopLineTokens) else {
                usageUnavailableReason = "OpenCode usage is unavailable because aggregated token totals exceed the supported integer range."
                break
            }
            let total: Int?
            if let rawTotal = tokens["total"] {
                let parsedTotal: Int?
                if row.usageFamily == "opencode.step-finish.tokens" {
                    parsedTotal = nonNegativeJSONInteger(rawTotal)
                } else {
                    parsedTotal = optionalNonNegativeInteger(rawTotal)
                }
                guard let parsedTotal else {
                    usageUnavailableReason = "OpenCode usage is unavailable because a recorded total is malformed or out of range."
                    break
                }
                total = parsedTotal
            } else {
                total = nil
            }
            let hasComponents = tokens["input"] != nil
                || tokens["output"] != nil
                || tokens["reasoning"] != nil
                || cache["read"] != nil
                || cache["write"] != nil
                || tokens["cacheRead"] != nil
                || tokens["cacheWrite"] != nil
            let hasUsableComponents = hasComponents
                && !(rowTopLineTokens == 0 && (total ?? 0) > 0)
            hasComponentBreakdown = hasComponentBreakdown && hasUsableComponents
            if let total {
                guard let updatedRecordedTotal = adding(recordedTotalTokens, total) else {
                    usageUnavailableReason = "OpenCode usage is unavailable because recorded token totals exceed the supported integer range."
                    break
                }
                recordedTotalTokens = updatedRecordedTotal
                hasRecordedTotal = true
            }
            let rowDisplayTokens = total ?? rowTopLineTokens
            guard let updatedDisplayTotal = adding(displayTotalTokens, rowDisplayTokens) else {
                usageUnavailableReason = "OpenCode usage is unavailable because display token totals exceed the supported integer range."
                break
            }
            displayTotalTokens = updatedDisplayTotal
            hasDisplayTotal = true
            if !hasUsableComponents {
                // Preserve a provider-recorded total-only value for the summary,
                // but do not create a zero-valued request that can mask it in the
                // presentation layer or inflate activity counts.
                continue
            }

            // Price-bearing evidence: only the row's own model. Session metadata holds
            // the *current* model, so borrowing it would price an older request at a
            // later model's rate. A nil model makes the calculator refuse the figure.
            let model = row.model
            let speed = "standard-normalized"
            events.append(TelemetryUsageEvent(
                recordID: row.id.isEmpty ? nil : row.id,
                observedAt: row.observedAt,
                anchorLine: index,
                usageFamily: row.usageFamily,
                ownership: .session,
                model: model,
                reasoningEffort: row.reasoningEffort,
                speed: speed,
                freshInputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                contextInputTokens: contextInput,
                completedAt: row.completedAt))

            let key = SliceKey(model: model, reasoningEffort: row.reasoningEffort, speed: speed)
            var slice = slices[key] ?? TelemetryUsageSlice(
                model: model, reasoningEffort: row.reasoningEffort, speed: speed)
            guard let freshInputTokens = adding(slice.freshInputTokens, input),
                  let cacheReadTokens = adding(slice.cacheReadTokens, cacheRead),
                  let cacheWriteTokens = adding(slice.cacheWrite5mTokens, cacheWrite),
                  let outputTokens = adding(slice.outputTokens, output),
                  let reasoningOutputTokens = adding(slice.reasoningOutputTokens, reasoning),
                  let sliceBaseContextInput = adding(freshInputTokens, cacheReadTokens),
                  let sliceContextInput = adding(sliceBaseContextInput, cacheWriteTokens),
                  adding(sliceContextInput, outputTokens) != nil else {
                usageUnavailableReason = "OpenCode usage is unavailable because aggregated token totals exceed the supported integer range."
                break
            }
            slice.freshInputTokens = freshInputTokens
            slice.cacheReadTokens = cacheReadTokens
            slice.cacheWrite5mTokens = cacheWriteTokens
            slice.outputTokens = outputTokens
            slice.reasoningOutputTokens = reasoningOutputTokens
            slices[key] = slice
            topLineTokens = updatedTopLineTokens
        }

        if usageUnavailableReason != nil {
            events.removeAll(keepingCapacity: false)
            slices.removeAll(keepingCapacity: false)
            topLineTokens = 0
            recordedTotalTokens = 0
            hasRecordedTotal = false
            displayTotalTokens = 0
            hasDisplayTotal = false
        }

        guard !Task.isCancelled else {
            return cancelledTelemetryScan(bytesScanned: bytesScanned)
        }
        let usageFamilies = Array(Set(usageRows.map(\.usageFamily))).sorted()
        let usageSummary: TelemetryUsageSummary?
        if events.isEmpty && usageUnavailableReason == nil && !hasRecordedTotal {
            usageSummary = nil
        } else {
            usageSummary = TelemetryUsageSummary(
                topLineTokens: topLineTokens,
                hasComponentBreakdown: usageUnavailableReason == nil && hasComponentBreakdown,
                recordedTotalTokens: usageUnavailableReason == nil && hasRecordedTotal
                    ? recordedTotalTokens : nil,
                usageFamilies: usageFamilies,
                usageFamilyConflict: false,
                displayTotalTokens: usageUnavailableReason == nil && hasDisplayTotal
                    ? displayTotalTokens : nil,
                unavailableReason: usageUnavailableReason)
        }
        let telemetry = SessionTelemetry(
            source: .opencode,
            initialConfiguration: initialConfiguration,
            currentConfiguration: currentConfiguration,
            configurationChanges: changes,
            usageSlices: slices.values.sorted { lhs, rhs in
                (lhs.model ?? "") == (rhs.model ?? "")
                    ? (lhs.reasoningEffort ?? "") < (rhs.reasoningEffort ?? "")
                    : (lhs.model ?? "") < (rhs.model ?? "")
            },
            usageEvents: events,
            usageSummary: usageSummary,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func modelID(from object: [String: Any]) -> String? {
        if let model = object["model"] as? [String: Any] {
            return stringValue(model["id"]) ?? stringValue(model["modelID"])
        }
        return stringValue(object["modelID"]) ?? stringValue(object["model"])
    }

    private static func reasoningEffort(from object: [String: Any]) -> String? {
        stringValue(object["variant"])
            ?? stringValue(object["reasoningEffort"])
            ?? stringValue(object["thinking"])
    }

    private static func tokenObject(from object: [String: Any]) -> [String: Any]? {
        if let tokens = object["tokens"] as? [String: Any] {
            return tokens
        }
        if let usage = object["usage"] as? [String: Any] {
            return usage
        }
        return nil
    }

    private static func completeStepFinishTokenObject(from object: [String: Any]) -> [String: Any]? {
        guard let tokens = tokenObject(from: object),
              nonNegativeJSONInteger(tokens["input"]) != nil,
              nonNegativeJSONInteger(tokens["output"]) != nil,
              nonNegativeJSONInteger(tokens["reasoning"]) != nil else { return nil }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        guard nonNegativeJSONInteger(cache["read"] ?? tokens["cacheRead"]) != nil,
              nonNegativeJSONInteger(cache["write"] ?? tokens["cacheWrite"]) != nil else { return nil }
        return tokens
    }

    /// JSONSerialization bridges numbers through NSNumber, including booleans.
    /// Accept only integral numeric encodings that are non-negative and fit in
    /// Swift's Int; strings, booleans, floats, and negative counts are not
    /// complete usage evidence.
    private static func nonNegativeJSONInteger(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber else {
            return nil
        }
        let type = String(cString: value.objCType)
        guard ["q", "Q", "i", "I", "s", "S", "l", "L"].contains(type) else {
            return nil
        }
        let integer = value.int64Value
        guard integer >= 0,
              NSNumber(value: integer).compare(value) == .orderedSame else {
            return nil
        }
        return Int(exactly: integer)
    }

    /// Legacy message-token records predate the strict step-finish schema and
    /// may omit individual fields. Missing fields remain zero, but a present
    /// value must still be an exact non-negative integer. Numeric strings are
    /// retained only for this compatibility path; modern step-finish records
    /// continue to require JSON NSNumber values above.
    private static func optionalNonNegativeInteger(_ value: Any?) -> Int? {
        guard let value else { return 0 }
        if let integer = nonNegativeJSONInteger(value) {
            return integer
        }
        if let value = value as? String,
           let parsed = Int(value),
           parsed >= 0 {
            return parsed
        }
        return nil
    }

    private static func dateFromMillis(_ value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: Double(value) / 1000.0) : nil
    }

    /// A JSON completion value as a positive whole epoch-millisecond count, or nil.
    /// Booleans, strings, fractions, non-positive and out-of-range values are nil:
    /// callers treat a present-but-nil value as malformed, never as missing.
    static func positiveEpochMillis(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double > 0, double.rounded() == double,
              double < 9_000_000_000_000_000 else { return nil }
        return Int64(double)
    }

    /// When a step-finish part's request finished. v2 parts carry the adapter's
    /// `completedAt`; v1 parts use `time.end`, else the part row's update time.
    private static func completionDate(of part: OpenCodeTelemetryPartRow) -> Date? {
        if let raw = part.object["completedAt"] {
            return positiveEpochMillis(raw).flatMap(dateFromMillis)
        }
        if let time = part.object["time"] as? [String: Any], let end = time["end"] {
            return positiveEpochMillis(end).flatMap(dateFromMillis)
        }
        return part.updatedAt
    }

    private static func queryTelemetrySessionMetadata(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetrySessionMetadata? {
        let hasModelColumn = tableHasColumn(db, table: "session", column: "model")
        let hasCreatedColumn = tableHasColumn(db, table: "session", column: "time_created")
        let hasParentColumn = tableHasColumn(db, table: "session", column: "parent_id")
        var columns = ["time_updated"]
        if hasModelColumn { columns.append("model") }
        if hasCreatedColumn { columns.append("time_created") }
        if hasParentColumn { columns.append("parent_id") }
        let sql = "SELECT \(columns.joined(separator: ", ")) FROM session WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var columnIndex: Int32 = 1
        let modelIndex: Int32? = hasModelColumn ? columnIndex : nil
        if hasModelColumn { columnIndex += 1 }
        let createdIndex: Int32? = hasCreatedColumn ? columnIndex : nil
        if hasCreatedColumn { columnIndex += 1 }
        let parentIndex: Int32? = hasParentColumn ? columnIndex : nil
        let rawModel = modelIndex.flatMap { index in
            sqlite3_column_type(stmt, index) != SQLITE_NULL ? text(stmt, index) : nil
        }
        let createdAt = createdIndex.flatMap { dateFromMillis(sqlite3_column_int64(stmt, $0)) }
        let parentID = parentIndex.flatMap { index in
            sqlite3_column_type(stmt, index) != SQLITE_NULL ? stringValue(text(stmt, index)) : nil
        }
        return OpenCodeTelemetrySessionMetadata(
            hasModelColumn: hasModelColumn,
            model: rawModel.flatMap(currentModelID(from:)),
            updatedAt: dateFromMillis(sqlite3_column_int64(stmt, 0)),
            createdAt: createdAt,
            parentID: parentID)
    }

    private static func queryTelemetryMessages(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetryRows<OpenCodeTelemetryMessageRow>? {
        let sql = "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [OpenCodeTelemetryMessageRow] = []
        var step = sqlite3_step(stmt)
        var cancelled = false
        while step == SQLITE_ROW {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let dataString = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let object: [String: Any]
            let malformedPayload: Bool
            if let dataString,
               let data = dataString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
                malformedPayload = false
            } else {
                object = [:]
                malformedPayload = true
            }
            rows.append(OpenCodeTelemetryMessageRow(
                id: text(stmt, 0),
                observedAt: dateFromMillis(sqlite3_column_int64(stmt, 1))
                    ?? dateFromMillis(sqlite3_column_int64(stmt, 2)),
                role: stringValue(object["role"]),
                model: modelID(from: object),
                reasoningEffort: reasoningEffort(from: object),
                object: object,
                malformedPayload: malformedPayload,
                bytesScanned: payloadByteCount(stmt, column: 3)))
            step = sqlite3_step(stmt)
        }
        guard cancelled || step == SQLITE_DONE else { return nil }
        return OpenCodeTelemetryRows(
            rows: rows,
            cancelled: cancelled,
            malformedPayload: rows.contains(where: \.malformedPayload))
    }

    private static func queryTelemetryParts(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetryRows<OpenCodeTelemetryPartRow>? {
        guard tableExists(db, table: "part") else {
            return OpenCodeTelemetryRows(rows: [], cancelled: false, malformedPayload: false)
        }
        let sql = "SELECT id, message_id, time_created, time_updated, data FROM part WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var rows: [OpenCodeTelemetryPartRow] = []
        var step = sqlite3_step(stmt)
        var cancelled = false
        while step == SQLITE_ROW {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let dataString = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let object: [String: Any]
            let malformedPayload: Bool
            if let dataString,
               let data = dataString.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
                malformedPayload = false
            } else {
                object = [:]
                malformedPayload = true
            }
            rows.append(OpenCodeTelemetryPartRow(
                id: text(stmt, 0),
                messageID: text(stmt, 1),
                observedAt: dateFromMillis(sqlite3_column_int64(stmt, 2))
                    ?? dateFromMillis(sqlite3_column_int64(stmt, 3)),
                object: object,
                malformedPayload: malformedPayload,
                bytesScanned: payloadByteCount(stmt, column: 4),
                updatedAt: dateFromMillis(sqlite3_column_int64(stmt, 3))))
            step = sqlite3_step(stmt)
        }
        guard cancelled || step == SQLITE_DONE else { return nil }
        return OpenCodeTelemetryRows(
            rows: rows,
            cancelled: cancelled,
            malformedPayload: rows.contains(where: \.malformedPayload))
    }

    private static func payloadByteCount(_ stmt: OpaquePointer?, column: Int32) -> UInt64 {
        UInt64(max(Int32(0), sqlite3_column_bytes(stmt, column)))
    }

    private static func cancelledTelemetryScan(bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .opencode,
            initialConfiguration: nil,
            currentConfiguration: nil,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: nil,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private static func beginReadTransaction(_ db: OpaquePointer?) -> Bool {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil) == SQLITE_OK
    }

    private static func rollbackReadTransaction(_ db: OpaquePointer?) {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }

    private static func logicalRevision(db: OpaquePointer?, sessionID: String) -> String? {
        if v2SessionExists(db, sessionID: sessionID) {
            return logicalRevisionV2(db: db, sessionID: sessionID)
        }
        guard tableExists(db, table: "message") else { return nil }
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        let hasCreated = tableHasColumn(db, table: "session", column: "time_created")
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        var sessionColumns = ["time_updated"]
        if hasModel { sessionColumns.append("model") }
        if hasCreated { sessionColumns.append("time_created") }
        if hasParent { sessionColumns.append("parent_id") }
        let sessionSQL = "SELECT \(sessionColumns.joined(separator: ", ")) FROM session WHERE id = ? LIMIT 1;"
        var sessionStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sessionSQL, -1, &sessionStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(sessionStmt) }
        sqlite3_bind_text(sessionStmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sessionStmt) == SQLITE_ROW else { return nil }
        let sessionUpdated = sqlite3_column_int64(sessionStmt, 0)
        var sessionIndex: Int32 = 1
        let modelIndex: Int32? = hasModel ? sessionIndex : nil
        if hasModel { sessionIndex += 1 }
        let createdIndex: Int32? = hasCreated ? sessionIndex : nil
        if hasCreated { sessionIndex += 1 }
        let parentIndex: Int32? = hasParent ? sessionIndex : nil
        let modelRaw = modelIndex.flatMap { index in
            sqlite3_column_type(sessionStmt, index) != SQLITE_NULL
                ? text(sessionStmt, index)
                : nil
        }
        let sessionCreated = createdIndex.flatMap { sqlite3_column_int64(sessionStmt, $0) }
        let parentRaw = parentIndex.flatMap { index in
            sqlite3_column_type(sessionStmt, index) != SQLITE_NULL
                ? stringValue(text(sessionStmt, index))
                : nil
        }

        var hasher = SHA256()
        feedDigest("session.id", value: sessionID, into: &hasher)
        feedDigest("session.time_updated", value: String(sessionUpdated), into: &hasher)
        feedDigest("session.model", value: hasModel ? (modelRaw ?? "<null>") : "<absent>", into: &hasher)
        feedDigest("session.time_created", value: hasCreated ? String(sessionCreated ?? 0) : "<absent>", into: &hasher)
        feedDigest("session.parent_id", value: hasParent ? (parentRaw ?? "<null>") : "<absent>", into: &hasher)

        let messageSQL = "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var messageStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, messageSQL, -1, &messageStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(messageStmt) }
        sqlite3_bind_text(messageStmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var step = sqlite3_step(messageStmt)
        while step == SQLITE_ROW {
            guard !Task.isCancelled else { return nil }
            feedDigest("message.id", value: text(messageStmt, 0), into: &hasher)
            feedDigest("message.time_created", value: String(sqlite3_column_int64(messageStmt, 1)), into: &hasher)
            feedDigest("message.time_updated", value: String(sqlite3_column_int64(messageStmt, 2)), into: &hasher)
            feedDigest("message.data", value: text(messageStmt, 3), into: &hasher)
            step = sqlite3_step(messageStmt)
        }
        guard step == SQLITE_DONE else { return nil }

        if tableExists(db, table: "part") {
            let partSQL = "SELECT id, message_id, time_created, time_updated, data FROM part WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
            var partStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, partSQL, -1, &partStmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(partStmt) }
            sqlite3_bind_text(partStmt, 1, (sessionID as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            step = sqlite3_step(partStmt)
            while step == SQLITE_ROW {
                guard !Task.isCancelled else { return nil }
                feedDigest("part.id", value: text(partStmt, 0), into: &hasher)
                feedDigest("part.message_id", value: text(partStmt, 1), into: &hasher)
                feedDigest("part.time_created", value: String(sqlite3_column_int64(partStmt, 2)), into: &hasher)
                feedDigest("part.time_updated", value: String(sqlite3_column_int64(partStmt, 3)), into: &hasher)
                feedDigest("part.data", value: text(partStmt, 4), into: &hasher)
                step = sqlite3_step(partStmt)
            }
            guard step == SQLITE_DONE else { return nil }
        } else {
            feedDigest("part.table", value: "<absent>", into: &hasher)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func feedDigest(_ label: String,
                                   value: String,
                                   into hasher: inout SHA256) {
        hasher.update(data: Data(label.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(value.utf8))
        hasher.update(data: Data([0]))
    }

    private static func tableExists(_ db: OpaquePointer?, table: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            -1,
            &stmt,
            nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Internal query helpers

    private static func querySessionList(db: OpaquePointer?, dbPath: String) -> [Session]? {
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        // OpenCode 1.2+ stores the effective session model as JSON on the
        // session row. That is the authoritative current value for the quick
        // surface; falling back to message metadata is only for older schemas.
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        var columns = ["id", "title", "directory", "time_created", "time_updated"]
        if hasParent { columns.append("parent_id") }
        if hasModel { columns.append("model") }
        let sql = "SELECT " + columns.joined(separator: ", ")
            + " FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let id = text(stmt, 0)
            if id.isEmpty {
                step = sqlite3_step(stmt)
                continue
            }
            let title = text(stmt, 1)
            let directory = text(stmt, 2)
            let timeCreated = sqlite3_column_int64(stmt, 3)
            let timeUpdated = sqlite3_column_int64(stmt, 4)
            let parentIndex: Int32? = hasParent ? 5 : nil
            let modelIndex: Int32? = hasModel ? (hasParent ? 6 : 5) : nil
            let parentID: String? = if let parentIndex,
                                        sqlite3_column_type(stmt, parentIndex) != SQLITE_NULL {
                text(stmt, parentIndex)
            } else {
                nil
            }
            let storedModelID = modelIndex.flatMap { index in
                sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : currentModelID(from: text(stmt, index))
            }

            let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
            let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil

            let storedTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
            let generatedDefaultTitle = OpenCodeSessionParser.isGeneratedDefaultSessionTitle(storedTitle)
            // Fetch message count and first model in a separate quick query. Only
            // timestamp-default rows also inspect their first user text part.
            let (msgCount, modelID, firstUserTitle) = lightweightMessageMeta(
                db: db,
                sessionID: id,
                includeFirstUserTitle: generatedDefaultTitle,
                needsLegacyModelLookup: !hasModel
            )
            // A present session.model column is authoritative even when its
            // value is null or malformed. Only schemas without that column
            // may fall back to message-derived model metadata.
            let currentModel = hasModel ? storedModelID : modelID
            let sessionTitle = OpenCodeSessionParser.effectiveSessionTitle(
                storedTitle: storedTitle,
                firstUserText: firstUserTitle
            )
            let customTitle = generatedDefaultTitle ? nil : storedTitle
            let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(storedTitle)
            sessions.append(Session(
                id: id,
                source: .opencode,
                startTime: startDate,
                endTime: endDate,
                model: currentModel,
                filePath: dbPath,
                fileSizeBytes: nil,
                eventCount: msgCount,
                events: [],
                cwd: directory.isEmpty ? nil : directory,
                repoName: nil,
                lightweightTitle: sessionTitle,
                lightweightCommands: nil,
                parentSessionID: parentID,
                subagentType: subagentType,
                customTitle: customTitle
            ))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        return sessions
    }

    private static func lightweightMessageMeta(
        db: OpaquePointer?,
        sessionID: String,
        includeFirstUserTitle: Bool,
        needsLegacyModelLookup: Bool
    ) -> (count: Int, modelID: String?, firstUserTitle: String?) {
        let orderedMessages = "ORDER BY time_created IS NULL, time_created, id"
        let sql = "SELECT id, data FROM message WHERE session_id = ? \(orderedMessages) LIMIT 20;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, nil, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var count = 0
        var modelID: String?
        var firstUserMessageID: String?
        var firstUserSummary: String?
        func inspectCurrentMessage(_ statement: OpaquePointer?) {
            let messageID = text(statement, 0)
            guard let dataStr = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let data = dataStr.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                return
            }
            if let observedModel = msg.model?.modelID ?? msg.modelID,
               !observedModel.isEmpty {
                // The initial query is bounded for quick metadata. The
                // newest-first fallback below scans all messages when an old
                // schema has no session.model column.
                modelID = observedModel
            }
            if includeFirstUserTitle,
               firstUserMessageID == nil,
               msg.role?.lowercased() == "user" {
                firstUserMessageID = messageID
                firstUserSummary = OpenCodeSessionParser.preferredUserSummaryText(from: msg)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            count += 1
            inspectCurrentMessage(stmt)
        }
        if includeFirstUserTitle, firstUserMessageID == nil {
            let tailSQL = "SELECT id, data FROM message WHERE session_id = ? \(orderedMessages) LIMIT -1 OFFSET 20;"
            var tailStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, tailSQL, -1, &tailStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(tailStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                while sqlite3_step(tailStmt) == SQLITE_ROW, firstUserMessageID == nil {
                    inspectCurrentMessage(tailStmt)
                }
            }
            sqlite3_finalize(tailStmt)
        }
        // Get actual total count
        let countSQL = "SELECT COUNT(*) FROM message WHERE session_id = ?;"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(countStmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }
        var firstUserTitle: String?
        if let firstUserMessageID {
            firstUserTitle = loadPartDicts(db: db, messageID: firstUserMessageID)
                .compactMap { part -> String? in
                    guard (part.dict["type"] as? String)?.lowercased() == "text" else { return nil }
                    guard let text = part.dict["text"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return text
                }
                .first
            if firstUserTitle == nil {
                firstUserTitle = firstUserSummary
            }
        }
        if needsLegacyModelLookup,
           let latestModel = latestMessageModelID(db: db, sessionID: sessionID) {
            modelID = latestModel
        }
        return (count, modelID, firstUserTitle)
    }

    /// Older OpenCode SQLite schemas do not have the session-level model JSON.
    /// Scan newest-first until the first model-bearing message so a model
    /// switch beyond the quick metadata probe is still represented correctly.
    private static func latestMessageModelID(db: OpaquePointer?, sessionID: String) -> String? {
        let sql = "SELECT data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created DESC, id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dataString = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let data = dataString.data(using: .utf8),
                  let message = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data),
                  let model = message.model?.modelID ?? message.modelID,
                  !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    private static func queryFullSession(db: OpaquePointer?,
                                         sessionID: String,
                                         dbPath: String,
                                         afterV2Row: ((Int) -> Void)?) -> Session? {
        if v2SessionExists(db, sessionID: sessionID) {
            return queryFullSessionV2(db: db, sessionID: sessionID, dbPath: dbPath, afterV2Row: afterV2Row)
        }
        // 1. Session metadata
        let hasParent = tableHasColumn(db, table: "session", column: "parent_id")
        let hasModel = tableHasColumn(db, table: "session", column: "model")
        var sessionColumns = ["id", "title", "directory", "time_created", "time_updated"]
        if hasParent { sessionColumns.append("parent_id") }
        if hasModel { sessionColumns.append("model") }
        let sesSQL = "SELECT " + sessionColumns.joined(separator: ", ")
            + " FROM session WHERE id = ? LIMIT 1;"
        var sesStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sesSQL, -1, &sesStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(sesStmt) }
        sqlite3_bind_text(sesStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(sesStmt) == SQLITE_ROW else { return nil }

        let id = text(sesStmt, 0)
        let title = text(sesStmt, 1)
        let directory = text(sesStmt, 2)
        let timeCreated = sqlite3_column_int64(sesStmt, 3)
        let timeUpdated = sqlite3_column_int64(sesStmt, 4)
        let parentIndex: Int32? = hasParent ? 5 : nil
        let modelIndex: Int32? = hasModel ? (hasParent ? 6 : 5) : nil
        let parentID: String? = if let parentIndex,
                                    sqlite3_column_type(sesStmt, parentIndex) != SQLITE_NULL {
            text(sesStmt, parentIndex)
        } else {
            nil
        }
        let storedModelID = modelIndex.flatMap { index in
            sqlite3_column_type(sesStmt, index) == SQLITE_NULL ? nil : currentModelID(from: text(sesStmt, index))
        }

        // 2. Load all messages ordered by time_created
        let msgSQL = "SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var msgStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, msgSQL, -1, &msgStmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(msgStmt) }
        sqlite3_bind_text(msgStmt, 1, (sessionID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var events: [SessionEvent] = []
        var modelID: String? = storedModelID
        var commandCount = 0

        while sqlite3_step(msgStmt) == SQLITE_ROW {
            let msgID = text(msgStmt, 0)
            let msgTimeMs = sqlite3_column_int64(msgStmt, 1)
            guard let dataStr = sqlite3_column_text(msgStmt, 2).map({ String(cString: $0) }) else { continue }
            let rawJSON = dataStr

            guard let data = dataStr.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data) else {
                continue
            }

            let ts = msgTimeMs > 0 ? Date(timeIntervalSince1970: Double(msgTimeMs) / 1000.0) : nil
            if !hasModel,
               let mid = msg.model?.modelID ?? msg.modelID, !mid.isEmpty {
                // Messages are oldest-first. This is the fallback current
                // model for pre-1.2 schemas without session.model.
                modelID = mid
            }

            // 3. Load parts for this message
            appendMessageEvents(msgID: msgID,
                                timestamp: ts,
                                rawJSON: rawJSON,
                                message: msg,
                                partDicts: loadPartDicts(db: db, messageID: msgID),
                                events: &events,
                                commandCount: &commandCount)
        }

        return buildFullSession(id: id,
                                title: title,
                                directory: directory,
                                timeCreated: timeCreated,
                                timeUpdated: timeUpdated,
                                parentID: parentID,
                                modelID: modelID,
                                events: events,
                                commandCount: commandCount,
                                dbPath: dbPath)
    }

    /// Converts one v1 message and its parts into transcript events.
    private static func appendMessageEvents(msgID: String,
                                            timestamp ts: Date?,
                                            rawJSON: String,
                                            message msg: OpenCodeSessionParser.MessageJSON,
                                            partDicts: [(id: String, dict: [String: Any], rawJSON: String)],
                                            events: inout [SessionEvent],
                                            commandCount: inout Int) {
            let hasTools = (msg.tools?.todowrite ?? false) || (msg.tools?.todoread ?? false) || (msg.tools?.task ?? false)
            if hasTools { commandCount += 1 }

            let partEvents = OpenCodeSessionParser.buildPartEvents(
                for: msg,
                effectiveMsgID: msgID,
                parts: partDicts,
                fallbackTimestamp: ts
            )
            commandCount += partEvents.tool.filter { $0.kind == .tool_call }.count

            // Meta event for the raw message
            events.append(messageMetaEvent(msgID: msgID, timestamp: ts, role: msg.role, rawJSON: rawJSON))

            if !partEvents.text.isEmpty {
                events.append(contentsOf: partEvents.text)
            } else {
                // Fallback: render from message summary fields
                let baseKind = SessionEventKind.from(role: msg.role, type: nil)
                let normalizedRole = msg.role?.lowercased()
                var text: String?
                if normalizedRole == "user" {
                    text = msg.summary?.title
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        text = msg.summary?.body
                    }
                } else {
                    text = msg.summary?.body
                    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                       let t = msg.summary?.title, !t.isEmpty {
                        text = t
                    }
                }
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isUser = normalizedRole == "user"
                let hasToolParts = !partEvents.tool.isEmpty
                if trimmed.isEmpty && (hasTools || hasToolParts) && !isUser {
                    // no-op: tool-call wrapper with no display text
                } else if trimmed.isEmpty && !isUser {
                    // Drop completely empty non-user messages to avoid blank rows.
                } else {
                    events.append(SessionEvent(
                        id: msgID,
                        timestamp: ts,
                        kind: baseKind,
                        role: msg.role,
                        text: text,
                        toolName: nil,
                        toolInput: nil,
                        toolOutput: nil,
                        messageID: msgID,
                        parentID: nil,
                        isDelta: false,
                        rawJSON: rawJSON
                    ))
                }
            }
            events.append(contentsOf: partEvents.tool)
            events.append(contentsOf: partEvents.meta)
    }

    private static func messageMetaEvent(msgID: String, timestamp: Date?, role: String?, rawJSON: String) -> SessionEvent {
        SessionEvent(
            id: msgID + "-meta",
            timestamp: timestamp,
            kind: .meta,
            role: role,
            text: nil,
            toolName: nil,
            toolInput: nil,
            toolOutput: nil,
            messageID: msgID,
            parentID: nil,
            isDelta: false,
            rawJSON: rawJSON
        )
    }

    private static func buildFullSession(id: String,
                                         title: String,
                                         directory: String,
                                         timeCreated: Int64,
                                         timeUpdated: Int64,
                                         parentID: String?,
                                         modelID: String?,
                                         events: [SessionEvent],
                                         commandCount: Int,
                                         dbPath: String) -> Session {
        let startDate = timeCreated > 0 ? Date(timeIntervalSince1970: Double(timeCreated) / 1000.0) : nil
        let endDate = timeUpdated > 0 ? Date(timeIntervalSince1970: Double(timeUpdated) / 1000.0) : nil
        let nonMetaCount = events.filter { $0.kind != .meta }.count
        let storedTitle = OpenCodeSessionParser.normalizedSessionTitle(title)
        let generatedDefaultTitle = OpenCodeSessionParser.isGeneratedDefaultSessionTitle(storedTitle)
        let firstUserTitle = events.first(where: { $0.kind == .user })?.text
        let sessionTitle = OpenCodeSessionParser.effectiveSessionTitle(
            storedTitle: storedTitle,
            firstUserText: firstUserTitle
        )
        let customTitle = generatedDefaultTitle ? nil : storedTitle
        let subagentType = OpenCodeSessionParser.deriveSubagentTypeFromTitle(storedTitle)
        return Session(
            id: id,
            source: .opencode,
            startTime: startDate,
            endTime: endDate,
            model: modelID,
            filePath: dbPath,
            fileSizeBytes: nil,
            eventCount: nonMetaCount,
            events: events,
            cwd: directory.isEmpty ? nil : directory,
            repoName: nil,
            lightweightTitle: sessionTitle,
            lightweightCommands: commandCount > 0 ? commandCount : nil,
            parentSessionID: parentID,
            subagentType: subagentType,
            customTitle: customTitle
        )
    }

    private static func loadPartDicts(db: OpaquePointer?, messageID: String) -> [(id: String, dict: [String: Any], rawJSON: String)] {
        let sql = "SELECT id, data FROM part WHERE message_id = ? ORDER BY time_created IS NULL, time_created, id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (messageID as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var results: [(id: String, dict: [String: Any], rawJSON: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let partID = text(stmt, 0)
            guard let dataStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let data = dataStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawJSON = OpenCodeSessionParser.cappedPartJSON(obj: obj, source: dataStr.data(using: .utf8))
            results.append((id: partID, dict: obj, rawJSON: rawJSON))
        }
        return results
    }

    // MARK: - OpenCode 2.0 store (session_v2 + session_message)
    //
    // OpenCode 2.0 keeps the v1 `session`/`message`/`part` tables and adds
    // `session_v2` and `session_message` in the same database. New sessions are
    // written only to the v2 tables. A background job copies v1 sessions into
    // them with the same IDs and the same `time_updated`, and leaves the v1 rows
    // in place, so a session can exist in both stores.
    //
    // The copy is lossy: on a real 2.1.1 database it dropped every assistant
    // step of some older sessions while their v1 rows stayed complete. So the v2
    // row is used only when it has no v1 row, is strictly newer, or was archived
    // only in v2, which means the session changed in OpenCode 2.x. An untouched
    // migrated session keeps reading from its original v1 rows.

    private static func hasV2Store(_ db: OpaquePointer?) -> Bool {
        tableExists(db, table: "session_v2") && tableExists(db, table: "session_message")
    }

    /// The one precedence rule, as SQL over a `session_v2 v` row: read it from
    /// the v2 store unless a v1 row exists that is at least as new. An archive
    /// recorded only in v2 also counts as a 2.x change, so archiving a migrated
    /// session in OpenCode 2.x hides it even if time_updated did not move.
    private static let v2PreferredPredicate = """
        NOT EXISTS (
            SELECT 1 FROM session s
            WHERE s.id = v.id
              AND s.time_updated >= v.time_updated
              AND NOT (v.time_archived IS NOT NULL AND s.time_archived IS NULL)
        )
        """

    /// True when this session should be read from the v2 store (see above).
    private static func v2SessionExists(_ db: OpaquePointer?, sessionID: String) -> Bool {
        guard hasV2Store(db) else { return false }
        let sql = tableExists(db, table: "session")
            ? "SELECT 1 FROM session_v2 v WHERE v.id = ? AND \(v2PreferredPredicate) LIMIT 1;"
            : "SELECT 1 FROM session_v2 v WHERE v.id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// IDs read from the v2 store, chosen over all rows including archived
    /// ones with the same rule as v2SessionExists. nil means a query failure.
    private static func v2PreferredSessionIDs(_ db: OpaquePointer?, hasV1Store: Bool) -> Set<String>? {
        let sql = hasV1Store
            ? "SELECT v.id FROM session_v2 v WHERE \(v2PreferredPredicate);"
            : "SELECT id FROM session_v2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var ids = Set<String>()
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            ids.insert(text(stmt, 0))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        return ids
    }

    private struct V2Row {
        let id: String
        let type: String
        let seq: Int64
        let timeCreated: Int64
        let timeUpdated: Int64
        let data: String
    }

    /// Reads a session's v2 rows in `seq` order. nil means a query failure.
    /// Cancellation is checked before the first row, between rows, and after
    /// the last one, so an empty or fully read session also reports it.
    /// `afterRow` is a test seam called after each collected row.
    private static func v2Rows(db: OpaquePointer?,
                               sessionID: String,
                               afterRow: ((Int) -> Void)? = nil) -> (rows: [V2Row], cancelled: Bool)? {
        if Task.isCancelled { return ([], true) }
        let sql = "SELECT id, type, seq, time_created, time_updated, data FROM session_message WHERE session_id = ? ORDER BY seq;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var rows: [V2Row] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if Task.isCancelled { return (rows, true) }
            rows.append(V2Row(id: text(stmt, 0),
                              type: text(stmt, 1),
                              seq: sqlite3_column_int64(stmt, 2),
                              timeCreated: sqlite3_column_int64(stmt, 3),
                              timeUpdated: sqlite3_column_int64(stmt, 4),
                              data: text(stmt, 5)))
            afterRow?(rows.count)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        return (rows, Task.isCancelled)
    }

    private static func decodeObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func decodeMessageJSON(_ object: [String: Any]) -> OpenCodeSessionParser.MessageJSON? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(OpenCodeSessionParser.MessageJSON.self, from: data)
    }

    private static func adaptedV2Row(_ row: V2Row) -> OpenCodeV2MessageAdapter.Adapted? {
        guard let object = decodeObject(row.data) else { return nil }
        return OpenCodeV2MessageAdapter.adapt(rowID: row.id,
                                             type: row.type,
                                             timeCreatedMillis: row.timeCreated,
                                             timeUpdatedMillis: row.timeUpdated,
                                             data: object)
    }

    private struct V2SessionRow {
        let id: String
        let title: String
        let directory: String
        let timeCreated: Int64
        let timeUpdated: Int64
        let parentID: String?
        let modelID: String?
    }

    private static let v2SessionColumns = "id, title, directory, time_created, time_updated, parent_id, model"

    private static func v2SessionRow(_ stmt: OpaquePointer?) -> V2SessionRow {
        V2SessionRow(
            id: text(stmt, 0),
            title: text(stmt, 1),
            directory: text(stmt, 2),
            timeCreated: sqlite3_column_int64(stmt, 3),
            timeUpdated: sqlite3_column_int64(stmt, 4),
            parentID: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : stringValue(text(stmt, 5)),
            // session_v2.model is the authoritative current model, as in v1.
            modelID: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : currentModelID(from: text(stmt, 6)))
    }

    private static func querySessionListV2(db: OpaquePointer?, dbPath: String) -> [Session]? {
        let sql = "SELECT \(v2SessionColumns) FROM session_v2 WHERE time_archived IS NULL ORDER BY time_updated DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let row = v2SessionRow(stmt)
            if !row.id.isEmpty {
                let storedTitle = OpenCodeSessionParser.normalizedSessionTitle(row.title)
                let generatedDefaultTitle = OpenCodeSessionParser.isGeneratedDefaultSessionTitle(storedTitle)
                let meta = v2LightweightMeta(db: db, sessionID: row.id, includeFirstUserTitle: generatedDefaultTitle)
                sessions.append(Session(
                    id: row.id,
                    source: .opencode,
                    startTime: dateFromMillis(row.timeCreated),
                    endTime: dateFromMillis(row.timeUpdated),
                    model: row.modelID,
                    filePath: dbPath,
                    fileSizeBytes: nil,
                    eventCount: meta.count,
                    events: [],
                    cwd: row.directory.isEmpty ? nil : row.directory,
                    repoName: nil,
                    lightweightTitle: OpenCodeSessionParser.effectiveSessionTitle(
                        storedTitle: storedTitle,
                        firstUserText: meta.firstUserTitle),
                    lightweightCommands: nil,
                    parentSessionID: row.parentID,
                    subagentType: OpenCodeSessionParser.deriveSubagentTypeFromTitle(storedTitle),
                    customTitle: generatedDefaultTitle ? nil : storedTitle))
            }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        return sessions
    }

    private static func v2LightweightMeta(db: OpaquePointer?,
                                          sessionID: String,
                                          includeFirstUserTitle: Bool) -> (count: Int, firstUserTitle: String?) {
        var count = 0
        let types = OpenCodeV2MessageAdapter.conversationTypes.sorted().map { "'\($0)'" }.joined(separator: ", ")
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_message WHERE session_id = ? AND type IN (\(types));",
                              -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, (sessionID as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(countStmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(countStmt, 0))
            }
        }
        sqlite3_finalize(countStmt)

        guard includeFirstUserTitle else { return (count, nil) }
        var firstUserTitle: String?
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM session_message WHERE session_id = ? AND type = 'user' ORDER BY seq;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while firstUserTitle == nil, sqlite3_step(stmt) == SQLITE_ROW {
                // Same visible text as the transcript, so a file-only first
                // prompt titles the row by its attachment names.
                if let object = decodeObject(text(stmt, 0)) {
                    firstUserTitle = OpenCodeV2MessageAdapter.visibleUserText(object)
                }
            }
        }
        sqlite3_finalize(stmt)
        return (count, firstUserTitle)
    }

    private static func queryFullSessionV2(db: OpaquePointer?,
                                           sessionID: String,
                                           dbPath: String,
                                           afterV2Row: ((Int) -> Void)?) -> Session? {
        let sql = "SELECT \(v2SessionColumns) FROM session_v2 WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let session = v2SessionRow(stmt)
        // A cancelled scan holds only a prefix of the rows. Returning it would
        // look like a complete transcript.
        guard let scan = v2Rows(db: db, sessionID: sessionID, afterRow: afterV2Row),
              !scan.cancelled else { return nil }

        var events: [SessionEvent] = []
        var commandCount = 0
        for row in scan.rows {
            guard let adapted = adaptedV2Row(row),
                  let message = decodeMessageJSON(adapted.message) else { continue }
            let timestamp = dateFromMillis(row.timeCreated)
            events.append(messageMetaEvent(msgID: row.id, timestamp: timestamp, role: message.role, rawJSON: row.data))
            // Expand one part at a time so text, reasoning and tool items keep
            // the order of the row's `content` array. (The shared builder groups
            // a message's events by kind, which in v1 spans a whole turn.)
            for part in adapted.parts {
                let partEvents = OpenCodeSessionParser.buildPartEvents(
                    for: message,
                    effectiveMsgID: row.id,
                    parts: [(id: part.id,
                             dict: part.dict,
                             rawJSON: OpenCodeSessionParser.cappedPartJSON(obj: part.dict, source: nil))],
                    fallbackTimestamp: timestamp)
                commandCount += partEvents.tool.filter { $0.kind == .tool_call }.count
                events.append(contentsOf: partEvents.text)
                events.append(contentsOf: partEvents.tool)
                events.append(contentsOf: partEvents.meta)
            }
        }
        return buildFullSession(id: session.id,
                                title: session.title,
                                directory: session.directory,
                                timeCreated: session.timeCreated,
                                timeUpdated: session.timeUpdated,
                                parentID: session.parentID,
                                modelID: session.modelID,
                                events: events,
                                commandCount: commandCount,
                                dbPath: dbPath)
    }

    private static func queryTelemetrySessionMetadataV2(
        db: OpaquePointer?,
        sessionID: String
    ) -> OpenCodeTelemetrySessionMetadata? {
        let sql = "SELECT time_updated, model, time_created, parent_id FROM session_v2 WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let rawModel = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? text(stmt, 1) : nil
        let parentID = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? stringValue(text(stmt, 3)) : nil
        return OpenCodeTelemetrySessionMetadata(
            hasModelColumn: true,
            model: rawModel.flatMap(currentModelID(from:)),
            updatedAt: dateFromMillis(sqlite3_column_int64(stmt, 0)),
            createdAt: dateFromMillis(sqlite3_column_int64(stmt, 2)),
            parentID: parentID)
    }

    /// v2 rows as telemetry message rows plus the step-finish parts the adapter
    /// derives from assistant `tokens`.
    private static func queryTelemetryV2(
        db: OpaquePointer?,
        sessionID: String
    ) -> (messages: OpenCodeTelemetryRows<OpenCodeTelemetryMessageRow>,
          parts: OpenCodeTelemetryRows<OpenCodeTelemetryPartRow>)? {
        guard let scan = v2Rows(db: db, sessionID: sessionID) else { return nil }
        var messages: [OpenCodeTelemetryMessageRow] = []
        var parts: [OpenCodeTelemetryPartRow] = []
        for row in scan.rows {
            let observedAt = dateFromMillis(row.timeCreated) ?? dateFromMillis(row.timeUpdated)
            let bytes = UInt64(row.data.utf8.count)
            guard let adapted = adaptedV2Row(row) else {
                messages.append(OpenCodeTelemetryMessageRow(
                    id: row.id, observedAt: observedAt, role: nil, model: nil, reasoningEffort: nil,
                    object: [:], malformedPayload: true, bytesScanned: bytes))
                continue
            }
            let object = adapted.message
            messages.append(OpenCodeTelemetryMessageRow(
                id: row.id,
                observedAt: observedAt,
                role: stringValue(object["role"]),
                model: modelID(from: object),
                reasoningEffort: reasoningEffort(from: object),
                object: object,
                malformedPayload: false,
                bytesScanned: bytes))
            for part in adapted.parts where (part.dict["type"] as? String) == "step-finish" {
                parts.append(OpenCodeTelemetryPartRow(
                    id: part.id,
                    messageID: row.id,
                    observedAt: observedAt,
                    object: part.dict,
                    malformedPayload: false,
                    bytesScanned: 0))
            }
        }
        return (OpenCodeTelemetryRows(rows: messages,
                                      cancelled: scan.cancelled,
                                      malformedPayload: messages.contains(where: \.malformedPayload)),
                OpenCodeTelemetryRows(rows: parts, cancelled: scan.cancelled, malformedPayload: false))
    }

    private static func logicalRevisionV2(db: OpaquePointer?, sessionID: String) -> String? {
        let sql = "SELECT time_updated, model, time_created, parent_id FROM session_v2 WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var hasher = SHA256()
        feedDigest("store", value: "session_v2", into: &hasher)
        feedDigest("session.id", value: sessionID, into: &hasher)
        feedDigest("session.time_updated", value: String(sqlite3_column_int64(stmt, 0)), into: &hasher)
        feedDigest("session.model",
                   value: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? "<null>" : text(stmt, 1),
                   into: &hasher)
        feedDigest("session.time_created", value: String(sqlite3_column_int64(stmt, 2)), into: &hasher)
        feedDigest("session.parent_id",
                   value: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "<null>" : text(stmt, 3),
                   into: &hasher)
        guard let scan = v2Rows(db: db, sessionID: sessionID), !scan.cancelled else { return nil }
        for row in scan.rows {
            feedDigest("message.id", value: row.id, into: &hasher)
            feedDigest("message.seq", value: String(row.seq), into: &hasher)
            feedDigest("message.time_updated", value: String(row.timeUpdated), into: &hasher)
            feedDigest("message.data", value: row.data, into: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SQLite helpers

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private static func tableHasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }), name == column {
                return true
            }
        }
        return false
    }

    /// Session.model is a JSON object in current OpenCode databases. Keep this
    /// parser tolerant of older scalar forms so the quick value remains a
    /// current-model fact rather than being relabelled first-observed.
    private static func currentModelID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let dictionary = object as? [String: Any] {
                for key in ["id", "modelID", "model"] {
                    if let value = dictionary[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                    if let nested = dictionary[key] as? [String: Any],
                       let value = nested["id"] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
                // A JSON object with no recognized model field is not a model
                // name. Do not render the entire blob as user-facing text.
                return nil
            }
            if let scalar = object as? String {
                let value = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            return nil
        }
        // Preserve legacy unquoted scalar model IDs, but do not surface a
        // malformed JSON object/array/string as if it were a model name.
        if let first = trimmed.first, ["{", "[", "\""].contains(String(first)) {
            return nil
        }
        return trimmed
    }
}

// MARK: - Recent usage window (Quota Meter session rates)

/// One session in a batch read. `previousTail` is the caller's cached tail token;
/// `forceReload` re-reads the window even when the tail is unchanged.
struct OpenCodeRecentUsageRequest: Sendable {
    let sessionID: String
    let previousTail: String?
    let forceReload: Bool
}

enum OpenCodeRecentUsageResult: Equatable, Sendable {
    case unchanged(tail: String)
    case loaded(tail: String, window: OpenCodeRecentWindow)
    case unreadable
}

/// What one session's recent window holds for the Quota Meter's live rate.
enum OpenCodeRecentWindow: Equatable, Sendable {
    /// Nothing completed in the window: empty, user-only, or in-flight requests only.
    case noCompletedUsage
    /// Completed requests, oldest first, each with `completedAt` set.
    case usage([TelemetryUsageEvent])
    /// A request that could belong to the window has unreadable or invalid usage.
    case unavailable
}

extension OpenCodeSqliteReader {
    /// Requests that started earlier than this are not shown (product rule).
    static let recentStartBound: TimeInterval = 2 * 60 * 60
    /// Only requests completed this recently feed a rate.
    static let recentCompletionWindow: TimeInterval = 30 * 60

    #if DEBUG
    nonisolated(unsafe) static var databaseOpenCountForTesting = 0
    /// Runs after a session's tail is read and before its window is read.
    nonisolated(unsafe) static var recentUsageAfterTailHookForTesting: (() -> Void)?
    #endif

    /// Every requested session in one read-only connection and one read
    /// transaction, so each tail and window come from the same snapshot even
    /// while OpenCode writes. nil = the store could not be opened.
    static func recentUsage(databaseURL: URL, requests: [OpenCodeRecentUsageRequest],
                            now: Date) -> [String: OpenCodeRecentUsageResult]? {
        var db: OpaquePointer?
        #if DEBUG
        databaseOpenCountForTesting += 1
        #endif
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        var results: [String: OpenCodeRecentUsageResult] = [:]
        for request in requests {
            guard let tail = recentTail(db: db, sessionID: request.sessionID) else {
                results[request.sessionID] = .unreadable
                continue
            }
            #if DEBUG
            recentUsageAfterTailHookForTesting?()
            #endif
            if tail == request.previousTail, !request.forceReload {
                results[request.sessionID] = .unchanged(tail: tail)
            } else if let window = recentWindow(db: db, sessionID: request.sessionID, now: now) {
                results[request.sessionID] = .loaded(tail: tail, window: window)
            } else {
                results[request.sessionID] = .unreadable
            }
        }
        return results
    }

    /// Cheap change token from index seeks only: the newest row of the selected
    /// store plus the session row's update time. It misses an in-place edit of an
    /// older row (and, in v1, a part added to an older message); the caller's
    /// periodic forced reload covers those. nil = the store could not be queried.
    private static func recentTail(db: OpaquePointer?, sessionID: String) -> String? {
        func firstRow(_ sql: String, _ columns: Int32) -> [String]? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return (0..<columns).map { text(stmt, $0) }
            case SQLITE_DONE: return []
            default: return nil
            }
        }
        if v2SessionExists(db, sessionID: sessionID) {
            guard let newest = firstRow(recentV2TailSQL, 2),
                  let session = firstRow("SELECT time_updated FROM session_v2 WHERE id = ? LIMIT 1;", 1) else { return nil }
            return (["v2"] + newest + ["|"] + session).joined(separator: ":")
        }
        guard tableExists(db, table: "message") else { return "none" }
        guard let newest = firstRow(recentV1TailSQL, 3) else { return nil }
        let session = tableExists(db, table: "session")
            ? firstRow("SELECT time_updated FROM session WHERE id = ? LIMIT 1;", 1) ?? []
            : []
        return (["v1"] + newest + ["|"] + session).joined(separator: ":")
    }

    /// One session's window on its own read-only connection.
    static func recentWindow(databaseURL: URL, sessionID: String, now: Date) -> OpenCodeRecentWindow? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        guard beginReadTransaction(db) else { return nil }
        defer { rollbackReadTransaction(db) }
        return recentWindow(db: db, sessionID: sessionID, now: now)
    }

    /// One session's window on an open connection, inside the caller's read
    /// transaction. Uses the same store choice and fork boundary as
    /// `loadTelemetry(for:)`, but classifies each raw request first: a decoded
    /// request with no completion marker is in flight and ignored, while an
    /// unreadable or invalid one makes the window unavailable when it was written
    /// within the completion window. nil = the store could not be queried.
    static func recentWindow(db: OpaquePointer?, sessionID: String, now: Date) -> OpenCodeRecentWindow? {
        let nowMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let bounds = RecentBounds(since: nowMillis - Int64(recentStartBound * 1000),
                                  windowStart: nowMillis - Int64(recentCompletionWindow * 1000))
        let scan: RecentScan?
        let metadata: OpenCodeTelemetrySessionMetadata?
        if v2SessionExists(db, sessionID: sessionID) {
            metadata = queryTelemetrySessionMetadataV2(db: db, sessionID: sessionID)
            scan = recentV2Scan(db: db, sessionID: sessionID, bounds: bounds)
        } else if tableExists(db, table: "message"), tableExists(db, table: "part") {
            metadata = queryTelemetrySessionMetadata(db: db, sessionID: sessionID)
            scan = recentV1Scan(db: db, sessionID: sessionID, bounds: bounds)
        } else {
            return .noCompletedUsage
        }
        guard let metadata, let scan else { return nil }
        if scan.poisoned { return .unavailable }

        // Inherited fork history is not this session's usage (see loadTelemetry).
        var rows = scan.rows
        if let forkBoundary = metadata.createdAt {
            if rows.contains(where: { $0.attributionAt == nil }) { return .unavailable }
            rows = rows.filter { ($0.attributionAt ?? .distantPast) >= forkBoundary }
        } else if metadata.parentID != nil, !rows.isEmpty {
            return .unavailable
        }

        let windowStart = Date(timeIntervalSince1970: Double(bounds.windowStart) / 1000)
        var events: [TelemetryUsageEvent] = []
        for row in rows {
            guard let completedAt = row.completedAt, completedAt >= windowStart else { continue }
            let tokens = row.tokens
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            guard let input = nonNegativeJSONInteger(tokens["input"]),
                  let cacheRead = nonNegativeJSONInteger(cache["read"] ?? tokens["cacheRead"]),
                  let cacheWrite = nonNegativeJSONInteger(cache["write"] ?? tokens["cacheWrite"]),
                  let storedOutput = nonNegativeJSONInteger(tokens["output"]),
                  let reasoning = nonNegativeJSONInteger(tokens["reasoning"]),
                  let output = adding(storedOutput, reasoning),
                  let baseContext = adding(input, cacheRead),
                  let contextInput = adding(baseContext, cacheWrite),
                  adding(contextInput, output) != nil else { return .unavailable }
            events.append(TelemetryUsageEvent(
                recordID: row.id,
                observedAt: row.observedAt,
                anchorLine: events.count,
                usageFamily: "opencode.step-finish.tokens",
                ownership: .session,
                model: row.model,
                reasoningEffort: row.reasoningEffort,
                speed: "standard-normalized",
                freshInputTokens: input,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                contextInputTokens: contextInput,
                completedAt: completedAt))
        }
        return events.isEmpty ? .noCompletedUsage : .usage(events)
    }

    private struct RecentBounds {
        /// Epoch milliseconds: requests must start at or after this.
        let since: Int64
        /// Epoch milliseconds: start of the completion window.
        let windowStart: Int64
    }

    private struct RecentScan {
        var rows: [OpenCodeTelemetryUsageRow] = []
        /// A request that could belong to the window is unreadable or invalid.
        var poisoned = false
    }

    private static func decodedObject(_ data: String?) -> [String: Any]? {
        guard let data, let bytes = data.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    }

    static let recentV2WindowSQL = "SELECT id, type, seq, time_created, time_updated, data FROM session_message WHERE session_id = ? AND time_created >= ?;"
    static let recentV1MessageSQL = "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? AND time_created >= ?;"
    static let recentV1PartSQL = """
        SELECT id, message_id, time_created, time_updated, data FROM part
        WHERE message_id IN (SELECT id FROM message WHERE session_id = ? AND time_created >= ?)
        ORDER BY time_created IS NULL, time_created, id;
        """
    /// Newest row by the (session_id, seq) unique index.
    static let recentV2TailSQL = "SELECT seq, time_updated FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT 1;"
    /// Newest message by the (session_id, time_created, id) index.
    static let recentV1TailSQL = "SELECT id, time_created, time_updated FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1;"

    private static func recentV2Scan(db: OpaquePointer?, sessionID: String, bounds: RecentBounds) -> RecentScan? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, recentV2WindowSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, bounds.since)
        var raw: [V2Row] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            raw.append(V2Row(id: text(stmt, 0), type: text(stmt, 1), seq: sqlite3_column_int64(stmt, 2),
                             timeCreated: sqlite3_column_int64(stmt, 3), timeUpdated: sqlite3_column_int64(stmt, 4),
                             data: text(stmt, 5)))
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return nil }
        raw.sort { $0.seq < $1.seq }

        var scan = RecentScan()
        for row in raw {
            let recent = row.timeUpdated >= bounds.windowStart
            guard let object = decodedObject(row.data) else {
                if recent { scan.poisoned = true }
                continue
            }
            let time = object["time"] as? [String: Any] ?? [:]
            let completed = time["completed"]
            switch row.type {
            case "assistant":
                if completed != nil, positiveEpochMillis(completed) == nil {
                    if recent { scan.poisoned = true }
                    continue
                }
                if object["tokens"] == nil {
                    // No usage and no completion: in flight. Completed without usage: invalid.
                    if completed != nil, recent { scan.poisoned = true }
                    continue
                }
            case "compaction":
                guard stringValue(object["status"]) == "completed" else { continue }
                if completed != nil, positiveEpochMillis(completed) == nil {
                    if recent { scan.poisoned = true }
                    continue
                }
                // A completed compaction without tokens used none (as in Session Info).
                guard object["tokens"] != nil else { continue }
            default:
                continue
            }
            let adapted = OpenCodeV2MessageAdapter.adapt(rowID: row.id, type: row.type,
                                                         timeCreatedMillis: row.timeCreated,
                                                         timeUpdatedMillis: row.timeUpdated, data: object)
            guard let part = adapted.parts.first(where: { ($0.dict["type"] as? String) == "step-finish" }) else { continue }
            guard let tokens = completeStepFinishTokenObject(from: part.dict) else {
                if recent { scan.poisoned = true }
                continue
            }
            let start = dateFromMillis(row.timeCreated)
            scan.rows.append(OpenCodeTelemetryUsageRow(
                id: part.id,
                observedAt: start,
                attributionAt: start,
                model: modelID(from: part.dict) ?? modelID(from: adapted.message),
                reasoningEffort: reasoningEffort(from: part.dict) ?? reasoningEffort(from: adapted.message),
                tokens: tokens,
                usageFamily: "opencode.step-finish.tokens",
                completedAt: positiveEpochMillis(part.dict["completedAt"]).flatMap(dateFromMillis)))
        }
        return scan
    }

    /// v1 eligibility follows the owning message's start, never a part's own time.
    private static func recentV1Scan(db: OpaquePointer?, sessionID: String, bounds: RecentBounds) -> RecentScan? {
        let messageSQL = recentV1MessageSQL
        let partSQL = recentV1PartSQL
        struct MessageInfo { let start: Date?; let model: String?; let reasoningEffort: String? }
        var scan = RecentScan()
        var messages: [String: MessageInfo] = [:]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, messageSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, bounds.since)
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let id = text(stmt, 0)
            let created = sqlite3_column_int64(stmt, 1)
            let updated = sqlite3_column_int64(stmt, 2)
            if let object = decodedObject(sqlite3_column_text(stmt, 3).map { String(cString: $0) }) {
                messages[id] = MessageInfo(start: dateFromMillis(created), model: modelID(from: object),
                                           reasoningEffort: reasoningEffort(from: object))
            } else {
                // An unreadable message could hide step-finish evidence.
                if updated >= bounds.windowStart { scan.poisoned = true }
                messages[id] = MessageInfo(start: dateFromMillis(created), model: nil, reasoningEffort: nil)
            }
            step = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        guard step == SQLITE_DONE else { return nil }

        stmt = nil
        guard sqlite3_prepare_v2(db, partSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, bounds.since)
        step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(stmt) }
            let id = text(stmt, 0)
            let messageID = text(stmt, 1)
            let updated = sqlite3_column_int64(stmt, 3)
            let recent = updated >= bounds.windowStart
            guard let object = decodedObject(sqlite3_column_text(stmt, 4).map { String(cString: $0) }) else {
                if recent { scan.poisoned = true }
                continue
            }
            guard stringValue(object["type"])?.lowercased() == "step-finish" else { continue }
            let end = (object["time"] as? [String: Any])?["end"]
            if end != nil, positiveEpochMillis(end) == nil {
                if recent { scan.poisoned = true }
                continue
            }
            guard let tokens = completeStepFinishTokenObject(from: object) else {
                if recent { scan.poisoned = true }
                continue
            }
            let message = messages[messageID]
            scan.rows.append(OpenCodeTelemetryUsageRow(
                id: id,
                observedAt: message?.start,
                attributionAt: message?.start,
                model: modelID(from: object) ?? message?.model,
                reasoningEffort: reasoningEffort(from: object) ?? message?.reasoningEffort,
                tokens: tokens,
                usageFamily: "opencode.step-finish.tokens",
                completedAt: positiveEpochMillis(end).flatMap(dateFromMillis) ?? dateFromMillis(updated)))
        }
        guard step == SQLITE_DONE else { return nil }
        return scan
    }
}
