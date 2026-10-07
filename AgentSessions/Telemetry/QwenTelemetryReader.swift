import Foundation
import CoreFoundation

/// Reads Qwen Code's assistant usage records without counting dead rewind branches.
///
/// Qwen writes the same usage in `system/ui_telemetry` and on the corresponding
/// assistant record. The assistant `usageMetadata` is the authoritative family:
/// UI telemetry is diagnostic/duplicate evidence and is intentionally ignored.
enum QwenTelemetryReader {
    private static let speed = "standard-normalized"
    private static let usageFamily = "qwen.assistant.usageMetadata"
    private static let validTypes: Set<String> = ["user", "assistant", "tool_result", "system"]
    private static let artifactSubtypes: Set<String> = [
        "session_artifact_event", "session_artifact_snapshot"
    ]

    private struct UsageComponents {
        let freshInput: Int
        let cacheRead: Int
        let output: Int
        let reasoning: Int
        let recordedTotal: Int

        var topLine: Int? {
            let (input, inputOverflow) = freshInput.addingReportingOverflow(cacheRead)
            let (withOutput, outputOverflow) = input.addingReportingOverflow(output)
            guard !inputOverflow, !outputOverflow else { return nil }
            return withOutput
        }
    }

    private enum UsageEvidence {
        case absent
        case valid(UsageComponents)
        case malformed

        var isPresent: Bool {
            switch self {
            case .absent: return false
            case .valid, .malformed: return true
            }
        }
    }

    /// A telemetry projection of one JSONL object. Keep message/tool payloads out of
    /// the scan so a large Qwen transcript cannot become a second in-memory transcript.
    private struct Record {
        let uuid: String
        let parentUUID: String?
        let sessionID: String
        let type: String
        let subtype: String?
        let model: String?
        let sessionModel: String?
        let observedAt: Date?
        let usage: UsageEvidence
        let inheritedFromFork: Bool
        let anchorLine: Int

        var isArtifact: Bool {
            type == "system"
                && subtype.map { QwenTelemetryReader.artifactSubtypes.contains($0) } == true
        }
    }

    private struct ActiveChainProjection {
        let records: [Record]
        let topologyComplete: Bool
        let identityComplete: Bool
    }

    private struct ModelObservation {
        let model: String
        let observedAt: Date?
        let anchorLine: Int
    }

    private struct UsageObservation {
        let record: Record
        let components: UsageComponents
    }

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard supportedPath(for: session),
              let stat = SessionFileStat.precise(from: URL(fileURLWithPath: session.filePath)) else {
            return nil
        }
        return .logical(revision(sessionID: session.id,
                                 sessionModel: session.model,
                                 stat: stat))
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard supportedPath(for: session), !Task.isCancelled,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: session.filePath)) else {
            return nil
        }
        let descriptor = handle.fileDescriptor
        guard let startStat = SessionFileStat.precise(fromFileDescriptor: descriptor) else {
            try? handle.close()
            return nil
        }
        defer { try? handle.close() }

        let inputRevision = SessionTelemetryRevision.logical(
            revision(sessionID: session.id,
                     sessionModel: session.model,
                     stat: startStat))
        let maximumBytes = UInt64(max(0, startStat.size))
        var bytesScanned: UInt64 = 0
        var malformedLine = false
        var records: [Record] = []
        var anchorLine = 0

        let completed: Bool
        do {
            completed = try JSONLReader(
                url: URL(fileURLWithPath: session.filePath),
                maximumBytes: maximumBytes,
                propagatesReadErrors: true
            ).forEachLineWhile(using: handle, { line in
                guard !Task.isCancelled else { return false }
                let objects = QwenJSONL.objects(inPhysicalLine: line)
                guard !objects.isEmpty else {
                    malformedLine = true
                    anchorLine += 1
                    return true
                }
                for object in objects {
                    guard !Task.isCancelled else { return false }
                    guard let record = record(from: object, anchorLine: anchorLine) else {
                        malformedLine = true
                        continue
                    }
                    records.append(record)
                }
                anchorLine += 1
                return true
            }, reportBytesRead: { bytesScanned = $0 }, reportMalformedLine: {
                malformedLine = true
            })
        } catch {
            return nil
        }

        guard let endStat = SessionFileStat.precise(fromFileDescriptor: descriptor) else {
            return unstableScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
        }
        guard completed, !Task.isCancelled else {
            return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
        }
        guard endStat == startStat else {
            return unstableScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
        }

        guard !records.isEmpty else {
            return invalidScan(bytesScanned: bytesScanned,
                               inputRevision: inputRevision,
                               reason: "Qwen transcript contains no usable records.")
        }
        var recordsByUUID: [String: [Record]] = [:]
        for record in records {
            guard !Task.isCancelled else {
                return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
            }
            recordsByUUID[record.uuid, default: []].append(record)
        }
        for fragments in recordsByUUID.values {
            guard !Task.isCancelled else {
                return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
            }
            guard fragments.contains(where: {
                $0.sessionID.caseInsensitiveCompare(session.id) == .orderedSame
            }) else {
                return invalidScan(bytesScanned: bytesScanned,
                                   inputRevision: inputRevision,
                                   reason: "Qwen records do not agree with the selected session identity.")
            }
        }

        let projection = activeChain(records)
        guard !Task.isCancelled else {
            return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
        }
        guard projection.identityComplete else {
            return invalidScan(bytesScanned: bytesScanned,
                               inputRevision: inputRevision,
                               reason: "Qwen records do not agree with the selected session identity.")
        }
        let activeRecords = projection.records
        var timeline = ConfigurationTimeline(
            provenance: .assistantRecord,
            initialProvenance: .inferredFirstObservation)
        var slices = UsageSliceTable()
        var observations: [UsageObservation] = []
        var sawAssistantRecord = false
        var sawLocallyOwnedAssistantRecord = false
        var sawLocallyOwnedUsageRecord = false
        var hasSeenActiveSessionModel = false
        var latestActiveSessionModel: ModelObservation?
        var invalidUsage = malformedLine || !projection.topologyComplete
        var invalidUsageReason: String? = projection.topologyComplete
            ? nil
            : "Qwen active branch topology is incomplete; token usage is unavailable."

        for record in activeRecords {
            guard !Task.isCancelled else {
                return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
            }
            if let sessionModel = record.sessionModel {
                hasSeenActiveSessionModel = true
                latestActiveSessionModel = ModelObservation(model: sessionModel,
                                                            observedAt: record.observedAt,
                                                            anchorLine: record.anchorLine)
                timeline.observe(model: sessionModel,
                                 effort: nil,
                                 observedAt: record.observedAt,
                                 anchorLine: record.anchorLine,
                                 provenance: .sessionMetadata)
            }
            guard record.type == "assistant" else { continue }
            sawAssistantRecord = true
            timeline.observe(model: hasSeenActiveSessionModel ? nil : record.model,
                             effort: nil,
                             observedAt: record.observedAt,
                             anchorLine: record.anchorLine,
                             provenance: .assistantRecord)

            guard !record.inheritedFromFork else { continue }
            sawLocallyOwnedAssistantRecord = true
            switch record.usage {
            case .absent:
                invalidUsage = true
                invalidUsageReason = invalidUsageReason
                    ?? "Qwen assistant usageMetadata is missing for at least one local assistant record."
            case .malformed:
                sawLocallyOwnedUsageRecord = true
                invalidUsage = true
                invalidUsageReason = invalidUsageReason
                    ?? "Qwen assistant usageMetadata is incomplete or malformed."
            case let .valid(components):
                sawLocallyOwnedUsageRecord = true
                observations.append(UsageObservation(record: record,
                                                     components: components))
            }
        }

        var totalTopLine = 0
        var recordedTotal = 0
        if !invalidUsage {
            for observation in observations {
                guard !Task.isCancelled else {
                    return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
                }
                guard let recordTotal = observation.components.topLine,
                      let nextTopLine = adding(totalTopLine, recordTotal),
                      let nextRecordedTotal = adding(recordedTotal, observation.components.recordedTotal) else {
                    invalidUsage = true
                    invalidUsageReason = "Qwen token totals exceed the supported integer range."
                    break
                }
                totalTopLine = nextTopLine
                recordedTotal = nextRecordedTotal
                slices.addComponents(
                    fresh: observation.components.freshInput,
                    cacheRead: observation.components.cacheRead,
                    write5m: 0,
                    write1h: 0,
                    output: observation.components.output,
                    reasoning: observation.components.reasoning,
                    model: observation.record.model,
                    effort: nil,
                    speed: Self.speed)
            }
        }

        var events: [TelemetryUsageEvent] = []
        if !invalidUsage {
            events.reserveCapacity(observations.count)
            for observation in observations {
                guard !Task.isCancelled else {
                    return cancelledScan(bytesScanned: bytesScanned, inputRevision: inputRevision)
                }
                guard observation.components.topLine ?? 0 > 0 else { continue }
                events.append(TelemetryUsageEvent(
                    recordID: observation.record.uuid,
                    observedAt: observation.record.observedAt,
                    anchorLine: observation.record.anchorLine,
                    usageFamily: Self.usageFamily,
                    ownership: .session,
                    model: observation.record.model,
                    reasoningEffort: nil,
                    speed: Self.speed,
                    freshInputTokens: observation.components.freshInput,
                    cacheReadTokens: observation.components.cacheRead,
                    cacheWrite5mTokens: 0,
                    cacheWrite1hTokens: 0,
                    outputTokens: observation.components.output,
                    reasoningOutputTokens: observation.components.reasoning,
                    contextInputTokens: adding(observation.components.freshInput,
                                               observation.components.cacheRead))
                )
            }
        } else {
            observations.removeAll(keepingCapacity: false)
            slices = UsageSliceTable()
        }

        let unavailableReason: String?
        if invalidUsage {
            unavailableReason = invalidUsageReason
                ?? "Qwen telemetry contains malformed or incomplete records."
        } else if sawLocallyOwnedUsageRecord && sawLocallyOwnedAssistantRecord {
            unavailableReason = nil
        } else {
            unavailableReason = "Qwen did not record locally-owned assistant usageMetadata for this session."
        }

        let usageSummary: TelemetryUsageSummary? = sawAssistantRecord
            ? TelemetryUsageSummary(
                topLineTokens: invalidUsage ? 0 : totalTopLine,
                hasComponentBreakdown: sawLocallyOwnedUsageRecord && !invalidUsage,
                recordedTotalTokens: sawLocallyOwnedUsageRecord && !invalidUsage ? recordedTotal : nil,
                usageFamilies: sawLocallyOwnedUsageRecord ? [Self.usageFamily] : [],
                usageFamilyConflict: false,
                displayTotalTokens: sawLocallyOwnedUsageRecord && !invalidUsage ? totalTopLine : nil,
                unavailableReason: unavailableReason)
            : nil

        let currentConfiguration = currentConfiguration(
            loadedSessionModel: session.model,
            activeSessionModel: latestActiveSessionModel,
            timeline: timeline)
        let telemetry = SessionTelemetry(
            source: .qwen,
            initialConfiguration: timeline.initialConfiguration,
            currentConfiguration: currentConfiguration,
            configurationChanges: timeline.changes,
            usageSlices: invalidUsage ? [] : slices.ordered,
            usageEvents: invalidUsage ? [] : events,
            usageSummary: usageSummary,
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }

    private static func supportedPath(for session: Session) -> Bool {
        guard session.source == .qwen,
              URL(fileURLWithPath: session.filePath).pathExtension.lowercased() == "jsonl",
              let filenameID = QwenSessionDiscovery.sessionID(
                forTranscript: URL(fileURLWithPath: session.filePath)) else {
            return false
        }
        return filenameID.caseInsensitiveCompare(session.id) == .orderedSame
    }

    private static func record(from object: [String: Any], anchorLine: Int) -> Record? {
        guard let uuid = object["uuid"] as? String, !uuid.isEmpty,
              object.keys.contains("parentUuid"),
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
              let type = object["type"] as? String,
              validTypes.contains(type) else {
            return nil
        }

        let parentUUID: String?
        switch object["parentUuid"] {
        case let value as String:
            parentUUID = value.isEmpty ? nil : value
        case is NSNull:
            parentUUID = nil
        default:
            return nil
        }
        let usage: UsageEvidence
        if let rawUsage = object["usageMetadata"], !(rawUsage is NSNull) {
            guard let rawUsage = rawUsage as? [String: Any] else {
                usage = .malformed
                return Record(uuid: uuid,
                              parentUUID: parentUUID,
                              sessionID: sessionID,
                              type: type,
                              subtype: object["subtype"] as? String,
                              model: clean(object["model"] as? String),
                              sessionModel: sessionModel(from: object),
                              observedAt: date(object["timestamp"]),
                              usage: usage,
                              inheritedFromFork: inheritedFromFork(in: object),
                              anchorLine: anchorLine)
            }
            usage = components(from: rawUsage).map(UsageEvidence.valid) ?? .malformed
        } else {
            usage = .absent
        }
        return Record(uuid: uuid,
                      parentUUID: parentUUID,
                      sessionID: sessionID,
                      type: type,
                      subtype: object["subtype"] as? String,
                      model: clean(object["model"] as? String),
                      sessionModel: sessionModel(from: object),
                      observedAt: date(object["timestamp"]),
                      usage: usage,
                      inheritedFromFork: inheritedFromFork(in: object),
                      anchorLine: anchorLine)
    }

    /// Mirrors Qwen's active-leaf projection. Usage on abandoned rewind branches
    /// is not session usage and must not be added to the selected session total.
    private static func activeChain(_ records: [Record]) -> ActiveChainProjection {
        var identityConflictUUIDs: Set<String> = []
        var firstIdentityRecordByUUID: [String: Record] = [:]
        var conversationRecords: [Record] = []
        conversationRecords.reserveCapacity(records.count)
        for record in records {
            if Task.isCancelled {
                return ActiveChainProjection(records: [], topologyComplete: false, identityComplete: false)
            }
            if let first = firstIdentityRecordByUUID[record.uuid] {
                if first.sessionID.caseInsensitiveCompare(record.sessionID) != .orderedSame {
                    identityConflictUUIDs.insert(record.uuid)
                }
            } else {
                firstIdentityRecordByUUID[record.uuid] = record
            }
            if validTypes.contains(record.type), !record.isArtifact {
                conversationRecords.append(record)
            }
        }
        guard let leafUUID = conversationRecords.last?.uuid else {
            return ActiveChainProjection(records: [], topologyComplete: false, identityComplete: false)
        }

        var fragmentsByUUID: [String: [Record]] = [:]
        var firstByUUID: [String: Record] = [:]
        var topologyConflictUUIDs: Set<String> = []
        for record in conversationRecords {
            if Task.isCancelled {
                return ActiveChainProjection(records: [], topologyComplete: false, identityComplete: false)
            }
            fragmentsByUUID[record.uuid, default: []].append(record)
            if let first = firstByUUID[record.uuid] {
                if first.parentUUID != record.parentUUID
                    || first.type != record.type {
                    topologyConflictUUIDs.insert(record.uuid)
                }
            } else {
                firstByUUID[record.uuid] = record
            }
        }

        var reverseChain: [String] = []
        var visited: Set<String> = []
        var current: String? = leafUUID
        var topologyComplete = true
        var identityComplete = true
        while let uuid = current, !uuid.isEmpty {
            guard visited.insert(uuid).inserted else {
                topologyComplete = false
                break
            }
            if topologyConflictUUIDs.contains(uuid) {
                topologyComplete = false
            }
            if identityConflictUUIDs.contains(uuid) {
                identityComplete = false
            }
            guard let record = firstByUUID[uuid] else {
                topologyComplete = false
                break
            }
            reverseChain.append(uuid)
            guard let parent = record.parentUUID, !parent.isEmpty else {
                current = nil
                break
            }
            guard firstByUUID[parent] != nil else {
                topologyComplete = false
                current = nil
                break
            }
            current = parent
        }

        var projected: [Record] = []
        projected.reserveCapacity(reverseChain.count)
        for uuid in reverseChain.reversed() {
            guard !Task.isCancelled else {
                return ActiveChainProjection(records: [], topologyComplete: false, identityComplete: false)
            }
            guard let fragments = fragmentsByUUID[uuid], let first = fragments.first else { continue }
            projected.append(aggregate(first: first, fragments: fragments.dropFirst()))
        }
        return ActiveChainProjection(records: projected,
                                     topologyComplete: topologyComplete,
                                     identityComplete: identityComplete)
    }

    private static func aggregate<S: Sequence>(first: Record, fragments: S) -> Record where S.Element == Record {
        var model = first.model
        var sessionModel = first.sessionModel
        var observedAt = first.observedAt
        var usage = first.usage
        var inheritedFromFork = first.inheritedFromFork
        for fragment in fragments {
            if Task.isCancelled { break }
            if model == nil { model = fragment.model }
            if sessionModel == nil { sessionModel = fragment.sessionModel }
            if let candidate = fragment.observedAt,
               let current = observedAt, candidate > current {
                observedAt = candidate
            } else if observedAt == nil {
                observedAt = fragment.observedAt
            }
            if fragment.usage.isPresent { usage = fragment.usage }
            inheritedFromFork = inheritedFromFork || fragment.inheritedFromFork
        }
        return Record(uuid: first.uuid,
                      parentUUID: first.parentUUID,
                      sessionID: first.sessionID,
                      type: first.type,
                      subtype: first.subtype,
                      model: model,
                      sessionModel: sessionModel,
                      observedAt: observedAt,
                      usage: usage,
                      inheritedFromFork: inheritedFromFork,
                      anchorLine: first.anchorLine)
    }

    private static func components(from usage: [String: Any]) -> UsageComponents? {
        guard let prompt = count(usage["promptTokenCount"]),
              let total = count(usage["totalTokenCount"]) else {
            return nil
        }
        let candidates: Int
        if let rawCandidates = usage["candidatesTokenCount"] {
            guard let parsedCandidates = count(rawCandidates) else { return nil }
            candidates = parsedCandidates
        } else {
            candidates = 0
        }
        let cached = count(usage["cachedContentTokenCount"]) ?? 0
        let thoughts = count(usage["thoughtsTokenCount"]) ?? 0
        guard usage["cachedContentTokenCount"] == nil || count(usage["cachedContentTokenCount"]) != nil,
              usage["thoughtsTokenCount"] == nil || count(usage["thoughtsTokenCount"]) != nil,
              cached <= prompt,
              let freshInput = adding(prompt, -cached) else {
            return nil
        }

        let toolUsePrompt = count(usage["toolUsePromptTokenCount"]) ?? 0
        guard usage["toolUsePromptTokenCount"] == nil || count(usage["toolUsePromptTokenCount"]) != nil,
              let baseTotal = adding(prompt, candidates),
              let googleTotal = adding(baseTotal, toolUsePrompt),
              let googleTotalWithThoughts = adding(googleTotal, thoughts) else {
            return nil
        }

        if toolUsePrompt == 0,
           total == baseTotal,
           thoughts <= candidates {
            return UsageComponents(freshInput: freshInput,
                                   cacheRead: cached,
                                   output: candidates,
                                   reasoning: thoughts,
                                   recordedTotal: total)
        }

        guard total == googleTotalWithThoughts,
              let normalizedFreshInput = adding(freshInput, toolUsePrompt),
              let normalizedOutput = adding(candidates, thoughts) else {
            return nil
        }
        return UsageComponents(freshInput: normalizedFreshInput,
                               cacheRead: cached,
                               output: normalizedOutput,
                               reasoning: thoughts,
                               recordedTotal: total)
    }

    private static func sessionModel(from object: [String: Any]) -> String? {
        guard object["type"] as? String == "system",
              object["subtype"] as? String == "session_model" else { return nil }
        let payload = object["systemPayload"] as? [String: Any]
        return clean(payload?["modelId"] as? String)
            ?? clean(payload?["model"] as? String)
            ?? clean(object["modelId"] as? String)
            ?? clean(object["model"] as? String)
    }

    private static func inheritedFromFork(in object: [String: Any]) -> Bool {
        guard let forkedFrom = object["forkedFrom"] else { return false }
        return !(forkedFrom is NSNull)
    }

    private static func currentConfiguration(loadedSessionModel: String?,
                                             activeSessionModel: ModelObservation?,
                                             timeline: ConfigurationTimeline) -> SessionConfiguration? {
        if let activeSessionModel {
            let observed = timeline.currentConfiguration
            return SessionConfiguration(
                model: activeSessionModel.model,
                reasoningEffort: observed?.reasoningEffort,
                observedAt: observed?.observedAt ?? activeSessionModel.observedAt,
                anchorLine: observed?.anchorLine ?? activeSessionModel.anchorLine,
                provenance: .sessionMetadata,
                modelObservedAt: activeSessionModel.observedAt,
                modelAnchorLine: activeSessionModel.anchorLine,
                modelProvenance: .sessionMetadata,
                reasoningEffortObservedAt: observed?.reasoningEffortObservedAt,
                reasoningEffortAnchorLine: observed?.reasoningEffortAnchorLine,
                reasoningEffortProvenance: observed?.reasoningEffortProvenance)
        }

        guard let observed = timeline.currentConfiguration else {
            guard let sessionModel = clean(loadedSessionModel) else { return nil }
            return SessionConfiguration(
                unanchoredModel: sessionModel,
                reasoningEffort: nil,
                observedAt: nil,
                anchorLine: nil,
                provenance: .sessionMetadata,
                reasoningEffortObservedAt: nil,
                reasoningEffortAnchorLine: nil,
                reasoningEffortProvenance: nil)
        }
        guard observed.modelProvenance != .sessionMetadata,
              let sessionModel = clean(loadedSessionModel) else { return observed }
        return SessionConfiguration(
            unanchoredModel: sessionModel,
            reasoningEffort: nil,
            observedAt: nil,
            anchorLine: nil,
            provenance: .sessionMetadata,
            reasoningEffortObservedAt: nil,
            reasoningEffortAnchorLine: nil,
            reasoningEffortProvenance: nil)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["q", "Q", "i", "I", "s", "S", "l", "L"].contains(
                  String(cString: number.objCType)),
              let integer = Int(exactly: number),
              integer >= 0 else { return nil }
        return integer
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let dateLock = NSLock()
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let basicISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        dateLock.lock()
        defer { dateLock.unlock() }
        return fractionalISO8601.date(from: string) ?? basicISO8601.date(from: string)
    }

    private static func revision(sessionID: String,
                                 sessionModel: String?,
                                 stat: SessionFileStat) -> String {
        "qwen:v2|session=\(sessionID)|model=\(clean(sessionModel) ?? "")|mtime=\(stat.mtime)|size=\(stat.size)|inode=\(stat.fingerprint ?? "")|ctime=\(stat.changeTime.map(String.init) ?? "")"
    }

    private static func emptyTelemetry() -> SessionTelemetry {
        SessionTelemetry(source: .qwen,
                         initialConfiguration: nil,
                         currentConfiguration: nil,
                         configurationChanges: [],
                         usageSlices: [],
                         usageEvents: [],
                         usageSummary: nil,
                         costEstimate: nil)
    }

    private static func cancelledScan(bytesScanned: UInt64,
                                      inputRevision: SessionTelemetryRevision) -> SessionTelemetryProviderScan {
        SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: emptyTelemetry(), durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }

    private static func unstableScan(bytesScanned: UInt64,
                                     inputRevision: SessionTelemetryRevision) -> SessionTelemetryProviderScan {
        SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: emptyTelemetry(), durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision,
            revisionChanged: true)
    }

    private static func invalidScan(bytesScanned: UInt64,
                                    inputRevision: SessionTelemetryRevision,
                                    reason: String) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .qwen,
            initialConfiguration: nil,
            currentConfiguration: nil,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: reason),
            costEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }
}
