import Foundation

/// Reads the Cline manifest+messages pair for detailed Session Info telemetry.
///
/// Cline stores one JSON object containing a `messages` array rather than a
/// JSONL stream. The reader therefore owns the pair validation and message
/// decoding, while the registry-owned engine still owns revision checks,
/// cancellation, caching, pricing, and publication.
enum ClineTelemetryReader {
    private static let speed = "standard-normalized"
    private static let usageFamily = "assistant.metrics"

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard let paths = paths(for: session),
              let manifest = SessionFileStat.precise(from: paths.manifest),
              let messages = SessionFileStat.precise(from: paths.messages) else {
            return nil
        }

        let manifestIdentity = signature(path: paths.manifest, stat: manifest)
        let messagesIdentity = signature(path: paths.messages, stat: messages)
        return .logical("cline:v1|\(manifestIdentity)|\(messagesIdentity)")
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard let paths = paths(for: session),
              let manifestStat = SessionFileStat.precise(from: paths.manifest),
              let messagesStat = SessionFileStat.precise(from: paths.messages),
              !Task.isCancelled else {
            return nil
        }

        guard let manifestData = try? Data(contentsOf: paths.manifest),
              let messagesData = try? Data(contentsOf: paths.messages),
              let bytesScanned = checkedByteCount(manifestData.count, messagesData.count),
              let manifest = try? jsonObject(manifestData),
              let messagesObject = try? jsonObject(messagesData),
              let messages = messagesObject["messages"] as? [[String: Any]] else {
            return nil
        }

        guard manifest["version"] as? Int == 1,
              messagesObject["version"] as? Int == nil || messagesObject["version"] as? Int == 1 else {
            return nil
        }

        let manifestID = (manifest["session_id"] as? String)
            .flatMap(Self.clean)
            ?? paths.manifest.deletingPathExtension().lastPathComponent
        guard manifestID == session.id else { return nil }

        if let companionID = (messagesObject["sessionId"] as? String)
            ?? (messagesObject["session_id"] as? String),
           let cleanCompanionID = Self.clean(companionID),
           cleanCompanionID != manifestID {
            return nil
        }

        var timeline = ConfigurationTimeline(
            provenance: .assistantRecord,
            initialProvenance: .inferredFirstObservation)
        var slices = UsageSliceTable()
        var events: [TelemetryUsageEvent] = []
        var sawAssistantRecord = false
        var sawMetrics = false
        var invalidMetrics = false
        var invalidModelInfo = false
        var totalTopLine = 0

        for (index, message) in messages.enumerated() {
            guard !Task.isCancelled else {
                return cancelledScan(bytesScanned: bytesScanned)
            }
            guard message["role"] as? String == "assistant" else { continue }
            sawAssistantRecord = true

            let observedAt = date(message["ts"])
            let model = modelInfoID(in: message["modelInfo"])
            timeline.observe(model: model,
                             effort: nil,
                             observedAt: observedAt,
                             anchorLine: index,
                             provenance: .assistantRecord)

            guard message.keys.contains("metrics") else { continue }
            sawMetrics = true
            guard modelInfo(in: message["modelInfo"]) != nil else {
                invalidModelInfo = true
                continue
            }
            guard let metrics = message["metrics"] as? [String: Any] else {
                invalidMetrics = true
                continue
            }
            guard let components = components(in: metrics),
                  let recordTotal = components.topLine else {
                invalidMetrics = true
                continue
            }
            let (nextTotal, totalOverflow) = totalTopLine.addingReportingOverflow(recordTotal)
            guard !totalOverflow else {
                invalidMetrics = true
                continue
            }
            totalTopLine = nextTotal

            slices.addComponents(fresh: components.fresh,
                                 cacheRead: components.cacheRead,
                                 write5m: components.cacheWrite,
                                 write1h: 0,
                                 output: components.output,
                                 model: model,
                                 effort: nil,
                                 speed: Self.speed)

            guard recordTotal > 0 else { continue }
            let recordID = (message["id"] as? String).flatMap(Self.clean)
                ?? "assistant.metrics:\(index)"
            events.append(TelemetryUsageEvent(
                recordID: recordID,
                observedAt: observedAt,
                anchorLine: index,
                usageFamily: Self.usageFamily,
                ownership: .session,
                model: model,
                reasoningEffort: nil,
                speed: Self.speed,
                freshInputTokens: components.fresh,
                cacheReadTokens: components.cacheRead,
                cacheWrite5mTokens: components.cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: components.output,
                contextInputTokens: components.contextInput))
        }

        let unavailableReason: String?
        if invalidModelInfo {
            unavailableReason = "Cline assistant model/provider metadata is incomplete or malformed."
        } else if invalidMetrics {
            unavailableReason = "Cline assistant metric components are incomplete or malformed."
        } else if sawMetrics {
            unavailableReason = nil
        } else {
            unavailableReason = "Cline did not record usable token metrics."
        }
        let invalidUsage = invalidModelInfo || invalidMetrics
        let currentConfiguration = currentConfiguration(sessionModel: session.model,
                                                         timeline: timeline)
        let summary: TelemetryUsageSummary? = sawAssistantRecord
            ? TelemetryUsageSummary(
                topLineTokens: invalidModelInfo || invalidMetrics ? 0 : totalTopLine,
                hasComponentBreakdown: sawMetrics
                    && !invalidModelInfo
                    && !invalidMetrics,
                recordedTotalTokens: nil,
                usageFamilies: sawMetrics ? [Self.usageFamily] : [],
                usageFamilyConflict: false,
                unavailableReason: unavailableReason)
            : nil

        let telemetry = SessionTelemetry(
            source: .cline,
            initialConfiguration: timeline.initialConfiguration,
            currentConfiguration: currentConfiguration,
            configurationChanges: timeline.changes,
            usageSlices: invalidUsage ? [] : slices.ordered,
            usageEvents: invalidUsage ? [] : events,
            usageSummary: summary,
            costEstimate: nil)
        // Keep the precise captures alive through this function so the compiler
        // cannot accidentally reduce the freshness proof to a seconds-only stat.
        _ = manifestStat
        _ = messagesStat
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }

    private struct Paths {
        let manifest: URL
        let messages: URL
    }

    private struct ModelInfo {
        let id: String
        let provider: String
    }

    private struct Components {
        let fresh: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int

        var topLine: Int? {
            let (input, inputOverflow) = fresh.addingReportingOverflow(cacheRead)
            let (cached, cacheOverflow) = input.addingReportingOverflow(cacheWrite)
            let (total, outputOverflow) = cached.addingReportingOverflow(output)
            guard !inputOverflow, !cacheOverflow, !outputOverflow else { return nil }
            return total
        }

        var contextInput: Int? {
            let (input, inputOverflow) = fresh.addingReportingOverflow(cacheRead)
            let (total, cacheOverflow) = input.addingReportingOverflow(cacheWrite)
            return inputOverflow || cacheOverflow ? nil : total
        }
    }

    private static func paths(for session: Session) -> Paths? {
        guard session.source == .cline else { return nil }
        let manifest = URL(fileURLWithPath: session.filePath)
        guard ClineSessionDiscovery.sessionID(forManifest: manifest) != nil else { return nil }
        return Paths(manifest: manifest,
                     messages: ClineSessionDiscovery.messagesFile(forManifest: manifest))
    }

    private static func signature(path: URL, stat: SessionFileStat) -> String {
        "\(path.standardizedFileURL.path):mtime=\(stat.mtime):size=\(stat.size):fingerprint=\(stat.fingerprint ?? "")"
    }

    private static func checkedByteCount(_ first: Int, _ second: Int) -> UInt64? {
        let (total, overflow) = first.addingReportingOverflow(second)
        guard !overflow, total >= 0 else { return nil }
        return UInt64(total)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClineTelemetryReader", code: 1)
        }
        return object
    }

    private static func modelInfoID(in value: Any?) -> String? {
        guard let modelInfo = value as? [String: Any] else { return nil }
        return clean(modelInfo["id"] as? String)
    }

    private static func modelInfo(in value: Any?) -> ModelInfo? {
        guard let modelInfo = value as? [String: Any],
              let id = clean(modelInfo["id"] as? String),
              let provider = clean(modelInfo["provider"] as? String) else { return nil }
        return ModelInfo(id: id, provider: provider)
    }

    private static func components(in metrics: [String: Any]) -> Components? {
        // Cline v1 persists inputTokens as the inclusive input total. The
        // cache fields are components of that total, so derive fresh input by
        // subtraction before populating the shared disjoint token buckets.
        guard let inclusiveInput = count(metrics["inputTokens"]),
              let cacheRead = count(metrics["cacheReadTokens"]),
              let cacheWrite = count(metrics["cacheWriteTokens"]),
              let output = count(metrics["outputTokens"]) else { return nil }

        let (cacheTotal, cacheOverflow) = cacheRead.addingReportingOverflow(cacheWrite)
        guard !cacheOverflow, inclusiveInput >= cacheTotal else { return nil }
        let normalizedFresh = inclusiveInput - cacheTotal

        let components = Components(fresh: normalizedFresh,
                                    cacheRead: cacheRead,
                                    cacheWrite: cacheWrite,
                                    output: output)
        guard components.topLine != nil else { return nil }
        return components
    }

    private static func currentConfiguration(sessionModel: String?,
                                             timeline: ConfigurationTimeline) -> SessionConfiguration? {
        let cleanSessionModel = clean(sessionModel)
        guard cleanSessionModel != nil || timeline.currentConfiguration != nil else { return nil }
        guard let cleanSessionModel else { return timeline.currentConfiguration }
        let observed = timeline.currentConfiguration
        return SessionConfiguration(
            model: cleanSessionModel,
            reasoningEffort: observed?.reasoningEffort,
            observedAt: observed?.reasoningEffortObservedAt,
            anchorLine: observed?.anchorLine ?? 0,
            provenance: .sessionMetadata,
            modelProvenance: .sessionMetadata,
            reasoningEffortObservedAt: observed?.reasoningEffortObservedAt,
            reasoningEffortAnchorLine: observed?.reasoningEffortAnchorLine,
            reasoningEffortProvenance: observed?.reasoningEffortProvenance)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let value = ClaudeRunwayLog.double(value),
              value.isFinite,
              value >= 0,
              value < Double(Int.max),
              value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let milliseconds = ClaudeRunwayLog.double(value),
              milliseconds.isFinite,
              milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cancelledScan(bytesScanned: UInt64) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(source: .cline,
                                         initialConfiguration: nil,
                                         currentConfiguration: nil,
                                         configurationChanges: [],
                                         usageSlices: [],
                                         usageEvents: [],
                                         usageSummary: nil,
                                         costEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned)
    }
}
