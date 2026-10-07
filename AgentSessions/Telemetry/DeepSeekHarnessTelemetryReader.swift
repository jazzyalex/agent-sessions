import Foundation

/// Source-specific telemetry reader for DeepSeek Harness generation artifacts.
///
/// DSH stores one immutable generation as either plain JSONL or a Zstandard
/// artifact. The normalizer is reused so telemetry sees the same historical
/// migrations and strict payload admission as the transcript parser.
/// `assistant/message` top-level usage is preferred when present; when absent,
/// one final valid usage sample from that record's stream is used. Repeated
/// stream samples are never added on top of top-level usage.
enum DeepSeekHarnessTelemetryReader {
    private static let revisionPrefix = "dsh-telemetry-v1"
    private static let usageFamily = "assistant.message.usage"
    private static let speed = "standard-normalized"
    private static let missingUsageReason =
        "DeepSeek Harness did not record usable assistant usage."
    private static let malformedUsageReason =
        "DeepSeek Harness assistant usage is incomplete or inconsistent."
    private static let unavailableArtifactReason =
        "DeepSeek Harness telemetry is unavailable because the session artifact could not be read or normalized."

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard session.source == .deepseekHarness,
              let artifact = DeepSeekHarnessDiscovery.resolveArtifactRevision(
                forSelectedURL: URL(fileURLWithPath: session.filePath)) else {
            return nil
        }
        return revision(for: artifact)
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard session.source == .deepseekHarness, !Task.isCancelled else { return nil }
        let sessionURL = URL(fileURLWithPath: session.filePath)
        guard let initialArtifact = DeepSeekHarnessDiscovery.resolveArtifactRevision(
            forSelectedURL: sessionURL) else {
            return nil
        }

        let initialRevision = revision(for: initialArtifact)
        guard let parsedFilename = DeepSeekHarnessDiscovery.parseGenerationFilename(
            initialArtifact.selectedURL.lastPathComponent) else {
            return retryableScan(bytesScanned: 0, inputRevision: initialRevision)
        }

        let bytesScanned = UInt64(max(0, initialArtifact.physicalStat.size))
        let parseResult: DeepSeekHarnessParseResult
        let normalized: DeepSeekHarnessNormalizedResult
        do {
            parseResult = try DeepSeekHarnessArtifactReader.read(
                url: initialArtifact.selectedURL,
                compression: parsedFilename.compression)
            guard !Task.isCancelled else { return nil }
            guard parseResult.header.id == session.id else {
                return unavailableScan(bytesScanned: bytesScanned,
                                       inputRevision: initialRevision,
                                       reason: unavailableArtifactReason)
            }
            normalized = try DeepSeekHarnessHistoricalNormalizer.normalizeWithMetadata(parseResult)
        } catch is CancellationError {
            return nil
        } catch let error as DeepSeekHarnessFormatError {
            if case .staleAnchor = error {
                return retryableScan(bytesScanned: bytesScanned, inputRevision: initialRevision)
            }
            return unavailableScan(bytesScanned: bytesScanned,
                                   inputRevision: initialRevision,
                                   reason: unavailableArtifactReason)
        } catch {
            return unavailableScan(bytesScanned: bytesScanned,
                                   inputRevision: initialRevision,
                                   reason: unavailableArtifactReason)
        }

        guard !Task.isCancelled else { return nil }
        guard let finalArtifact = DeepSeekHarnessDiscovery.resolveArtifactRevision(
            forSelectedURL: sessionURL) else {
            return retryableScan(bytesScanned: bytesScanned, inputRevision: initialRevision)
        }
        let finalRevision = revision(for: finalArtifact)
        guard finalArtifact == initialArtifact else {
            return retryableScan(bytesScanned: bytesScanned, inputRevision: finalRevision)
        }

        let accumulator = DeepSeekHarnessTelemetryAccumulator(
            inheritedEventCount: normalized.inheritedEventCount,
            events: normalized.events)
        guard let telemetry = accumulator.telemetry() else { return nil }
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                   durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: initialRevision)
    }

    private static func revision(for artifact: SessionArtifactRevision) -> SessionTelemetryRevision {
        let stat = artifact.physicalStat
        return .logical([
            revisionPrefix,
            artifact.selectedURL.standardizedFileURL.path,
            artifact.manifestRevision,
            String(stat.mtime),
            String(stat.size),
            stat.fingerprint ?? ""
        ].joined(separator: "|"))
    }

    private static func retryableScan(bytesScanned: UInt64,
                                      inputRevision: SessionTelemetryRevision)
        -> SessionTelemetryProviderScan {
        SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(
                telemetry: SessionTelemetry(source: .deepseekHarness,
                                            initialConfiguration: nil,
                                            currentConfiguration: nil,
                                            configurationChanges: [],
                                            usageSlices: [],
                                            usageEvents: [],
                                            usageSummary: nil,
                                            costEstimate: nil),
                durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision,
            revisionChanged: true)
    }

    private static func unavailableScan(bytesScanned: UInt64,
                                        inputRevision: SessionTelemetryRevision,
                                        reason: String) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .deepseekHarness,
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
            result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                   durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }
}

struct DeepSeekHarnessTelemetryAccumulator {
    private static let usageFamily = "assistant.message.usage"
    private static let speed = "standard-normalized"
    private static let missingUsageReason =
        "DeepSeek Harness did not record usable assistant usage."
    private static let malformedUsageReason =
        "DeepSeek Harness assistant usage is incomplete or inconsistent."

    private struct Components: Equatable {
        let freshInput: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int
        let recordedTotal: Int?

        var contextInput: Int? {
            guard let first = DeepSeekHarnessJSON.safeAdd(freshInput, cacheRead),
                  let second = DeepSeekHarnessJSON.safeAdd(first, cacheWrite) else {
                return nil
            }
            return second
        }

        var topLine: Int? {
            guard let contextInput,
                  let total = DeepSeekHarnessJSON.safeAdd(contextInput, output) else {
                return nil
            }
            return total
        }
    }

    private struct Totals {
        var freshInput = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        var reasoning = 0
        var recordedTotal = 0
        var everyRowHasRecordedTotal = true
        var sawRecordedTotal = false

        mutating func add(_ components: Components) -> Bool {
            guard let freshInput = DeepSeekHarnessJSON.safeAdd(freshInput, components.freshInput),
                  let cacheRead = DeepSeekHarnessJSON.safeAdd(cacheRead, components.cacheRead),
                  let cacheWrite = DeepSeekHarnessJSON.safeAdd(cacheWrite, components.cacheWrite),
                  let output = DeepSeekHarnessJSON.safeAdd(output, components.output),
                  let reasoning = DeepSeekHarnessJSON.safeAdd(reasoning, components.reasoning) else {
                return false
            }
            if let rowTotal = components.recordedTotal {
                guard let recordedTotal = DeepSeekHarnessJSON.safeAdd(self.recordedTotal, rowTotal) else {
                    return false
                }
                self.recordedTotal = recordedTotal
                sawRecordedTotal = true
            } else {
                everyRowHasRecordedTotal = false
            }
            self.freshInput = freshInput
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.output = output
            self.reasoning = reasoning
            return true
        }

        var components: Components {
            Components(freshInput: freshInput,
                       cacheRead: cacheRead,
                       cacheWrite: cacheWrite,
                       output: output,
                       reasoning: reasoning,
                       recordedTotal: everyRowHasRecordedTotal && sawRecordedTotal
                           ? recordedTotal : nil)
        }
    }

    private let inheritedEventCount: Int
    private let eventsToConsume: [DeepSeekHarnessNormalizedEvent]
    private var timeline = ConfigurationTimeline(
        provenance: .requestRecord,
        initialProvenance: .inferredFirstObservation)
    private var slices = UsageSliceTable()
    private var usageEvents: [TelemetryUsageEvent] = []
    private var totals = Totals()
    private var sawRelevantRecord = false
    private var sawUsageRecord = false
    private var invalidUsage = false
    private var cancellationRequested = false

    init(inheritedEventCount: Int, events: [DeepSeekHarnessNormalizedEvent]) {
        self.inheritedEventCount = inheritedEventCount
        self.eventsToConsume = events
    }

    func telemetry() -> SessionTelemetry? {
        var accumulator = self
        for event in eventsToConsume {
            guard !Task.isCancelled else { return nil }
            accumulator.consume(event)
        }
        guard !accumulator.cancellationRequested, !Task.isCancelled else { return nil }
        return accumulator.finish()
    }

    private mutating func consume(_ event: DeepSeekHarnessNormalizedEvent) {
        guard !Task.isCancelled else {
            cancellationRequested = true
            return
        }
        guard !event.diagnosticOnly,
              event.envelope.sequence >= inheritedEventCount else { return }

        let type = event.canonicalType
        let anchorLine = event.envelope.sequence
        let observedAt = Date(timeIntervalSince1970:
            TimeInterval(event.envelope.timeMilliseconds) / 1_000)

        switch type {
        case "request/header":
            guard let header = event.data["header"] as? [String: Any],
                  let config = header["config"] as? [String: Any] else { return }
            let model = DeepSeekHarnessJSON.nonEmptyString(config["model"])
            let effort = DeepSeekHarnessJSON.nonEmptyString(config["reasoningEffort"])
            guard model != nil || effort != nil else { return }
            sawRelevantRecord = true
            timeline.observe(model: model,
                             effort: effort,
                             observedAt: observedAt,
                             anchorLine: anchorLine,
                             provenance: .requestRecord)

        case "request/context":
            let model = DeepSeekHarnessJSON.nonEmptyString(event.data["model"])
            guard model != nil else { return }
            sawRelevantRecord = true
            timeline.observe(model: model,
                             effort: nil,
                             observedAt: observedAt,
                             anchorLine: anchorLine,
                             provenance: .requestRecord)

        case "model/selection":
            let model = DeepSeekHarnessJSON.nonEmptyString(event.data["model"])
            let effort = DeepSeekHarnessJSON.nonEmptyString(event.data["reasoningEffort"])
            guard model != nil || effort != nil else { return }
            sawRelevantRecord = true
            timeline.observe(model: model,
                             effort: effort,
                             observedAt: observedAt,
                             anchorLine: anchorLine,
                             provenance: .providerChangeRecord)

        case "assistant/message":
            guard let message = event.data["message"] as? [String: Any] else { return }
            let source = message["source"] as? [String: Any]
            let assistantModel = DeepSeekHarnessJSON.nonEmptyString(source?["model"])
            if let assistantModel,
               timeline.model == nil || timeline.model != assistantModel {
                sawRelevantRecord = true
                timeline.observe(model: assistantModel,
                                 effort: nil,
                                 observedAt: observedAt,
                                 anchorLine: anchorLine,
                                 provenance: .assistantRecord)
            }

            let streamEvidence = Self.streamUsage(event.data["stream"])
            guard !Task.isCancelled else {
                cancellationRequested = true
                return
            }
            let hasTopLevelUsage = event.data.keys.contains("usage")
            guard !streamEvidence.malformed, streamEvidence.isConsistent else {
                sawUsageRecord = true
                invalidUsage = true
                return
            }
            if !hasTopLevelUsage {
                if let components = streamEvidence.values.last {
                    sawRelevantRecord = true
                    sawUsageRecord = true
                    append(components, message: message, model: assistantModel,
                           anchorLine: anchorLine, observedAt: observedAt)
                }
                return
            }

            sawRelevantRecord = true
            sawUsageRecord = true
            guard let components = Self.parseUsage(event.data["usage"]),
                  streamEvidence.values.isEmpty || streamEvidence.values.allSatisfy({ $0 == components }) else {
                invalidUsage = true
                return
            }
            append(components, message: message, model: assistantModel,
                   anchorLine: anchorLine, observedAt: observedAt)

        default:
            return
        }
    }

    private mutating func append(_ components: Components,
                                 message: [String: Any],
                                 model: String?,
                                 anchorLine: Int,
                                 observedAt: Date) {
        guard totals.add(components),
              let contextInput = components.contextInput,
              let topLine = components.topLine else {
            invalidUsage = true
            return
        }
        slices.addComponents(fresh: components.freshInput,
                             cacheRead: components.cacheRead,
                             write5m: components.cacheWrite,
                             write1h: 0,
                             output: components.output,
                             model: model ?? timeline.model,
                             effort: timeline.effort,
                             speed: Self.speed)
        if topLine > 0 {
            usageEvents.append(TelemetryUsageEvent(
                recordID: DeepSeekHarnessJSON.nonEmptyString(message["id"])
                    .map { "assistant.message.usage:\($0)" }
                    ?? "assistant.message.usage:\(anchorLine)",
                observedAt: observedAt,
                anchorLine: anchorLine,
                usageFamily: Self.usageFamily,
                ownership: .session,
                model: model ?? timeline.model,
                reasoningEffort: timeline.effort,
                speed: Self.speed,
                freshInputTokens: components.freshInput,
                cacheReadTokens: components.cacheRead,
                cacheWrite5mTokens: components.cacheWrite,
                cacheWrite1hTokens: 0,
                outputTokens: components.output,
                reasoningOutputTokens: components.reasoning,
                contextInputTokens: contextInput))
        }
    }

    private func finish() -> SessionTelemetry {
        let summary: TelemetryUsageSummary?
        let outputSlices: [TelemetryUsageSlice]
        let outputEvents: [TelemetryUsageEvent]

        if invalidUsage {
            outputSlices = []
            outputEvents = []
            summary = TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [Self.usageFamily],
                usageFamilyConflict: false,
                unavailableReason: Self.malformedUsageReason)
        } else if sawUsageRecord {
            outputSlices = slices.ordered
            outputEvents = usageEvents
            summary = TelemetryUsageSummary(
                topLineTokens: slices.topLineTokens,
                hasComponentBreakdown: true,
                recordedTotalTokens: totals.components.recordedTotal,
                usageFamilies: [Self.usageFamily],
                usageFamilyConflict: false,
                displayTotalTokens: slices.topLineTokens)
        } else if sawRelevantRecord {
            outputSlices = []
            outputEvents = []
            summary = TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: Self.missingUsageReason)
        } else {
            outputSlices = []
            outputEvents = []
            summary = nil
        }

        return SessionTelemetry(
            source: .deepseekHarness,
            initialConfiguration: timeline.initialConfiguration,
            currentConfiguration: timeline.currentConfiguration,
            configurationChanges: timeline.changes,
            usageSlices: outputSlices,
            usageEvents: outputEvents,
            usageSummary: summary,
            costEstimate: nil)
    }

    private static func parseUsage(_ raw: Any?) -> Components? {
        guard let usage = raw as? [String: Any],
              let freshInput = DeepSeekHarnessJSON.count(usage["inputTokens"]),
              let output = DeepSeekHarnessJSON.count(usage["outputTokens"]) else {
            return nil
        }
        let cacheRead = optionalCount(usage, key: "cacheReadTokens")
        let cacheWrite = optionalCount(usage, key: "cacheWriteTokens")
        let reasoning = optionalCount(usage, key: "reasoningTokens")
        guard cacheRead != nil || !usage.keys.contains("cacheReadTokens"),
              cacheWrite != nil || !usage.keys.contains("cacheWriteTokens"),
              reasoning != nil || !usage.keys.contains("reasoningTokens") else {
            return nil
        }
        let resolvedCacheRead = cacheRead ?? 0
        let resolvedCacheWrite = cacheWrite ?? 0
        let resolvedReasoning = reasoning ?? 0
        guard resolvedReasoning <= output else { return nil }
        guard let contextInput = DeepSeekHarnessJSON.safeAdd(freshInput, resolvedCacheRead),
              let contextWithWrites = DeepSeekHarnessJSON.safeAdd(contextInput, resolvedCacheWrite),
              let topLine = DeepSeekHarnessJSON.safeAdd(contextWithWrites, output) else {
            return nil
        }
        let recordedTotal: Int?
        if usage.keys.contains("totalTokens") {
            guard let total = DeepSeekHarnessJSON.count(usage["totalTokens"]), total == topLine else {
                return nil
            }
            recordedTotal = total
        } else {
            recordedTotal = nil
        }
        return Components(freshInput: freshInput,
                          cacheRead: resolvedCacheRead,
                          cacheWrite: resolvedCacheWrite,
                          output: output,
                          reasoning: resolvedReasoning,
                          recordedTotal: recordedTotal)
    }

    private static func optionalCount(_ object: [String: Any], key: String) -> Int? {
        guard object.keys.contains(key) else { return 0 }
        return DeepSeekHarnessJSON.count(object[key])
    }

    private static func streamUsage(_ raw: Any?)
        -> (values: [Components], malformed: Bool, isConsistent: Bool) {
        guard let raw else { return ([], false, true) }
        guard let entries = raw as? [Any] else { return ([], true, false) }
        var values: [Components] = []
        for entryValue in entries {
            if Task.isCancelled { return ([], false, true) }
            guard let entry = entryValue as? [String: Any] else { continue }
            guard entry["type"] as? String == "chunk" else { continue }
            guard let chunk = entry["chunk"] as? [String: Any] else { return ([], true, false) }
            guard chunk["type"] as? String == "usage" else { continue }
            guard let components = parseUsage(chunk["usage"]) else { return ([], true, false) }
            values.append(components)
        }
        guard let first = values.first else { return (values, false, true) }
        return (values, false, values.dropFirst().allSatisfy { $0 == first })
    }
}
