import Foundation

/// Reads the two Droid storage shapes that can carry telemetry without making
/// claims the files cannot prove.
///
/// Interactive Droid sessions have a JSONL transcript and an adjacent
/// `<session-id>.settings.json`. The settings file contains a cumulative
/// `tokenUsage` snapshot. Factory can aggregate that snapshot across multiple
/// model calls and delegated work, so it is deliberately kept as an
/// unattributed summary rather than turned into model- or ownership-labelled
/// usage events.
///
/// Stream-json sessions may carry a `completion.usage.total_tokens` value. That
/// is also kept as a session summary. The reader only exposes a total when the
/// provider stated one explicitly; it does not invent a cache normalization or
/// sum fields whose semantics are not established by the stored record.
enum DroidTelemetryReader {
    private static let usageUnavailableReason =
        "Droid records aggregate token components without an audited disjoint total or request attribution."
    private static let missingUsageReason = "Droid did not record a usable token total for this session."
    private static let malformedUsageReason = "Droid token usage evidence is incomplete or malformed."
    private static let identityReason = "Droid telemetry files do not agree on the selected session identity."

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard session.source == .droid,
              let transcriptStat = SessionFileStat.precise(from: transcriptURL(for: session)) else {
            return nil
        }

        let settings = settingsURL(for: session)
        return logicalRevision(transcript: transcriptURL(for: session),
                               transcriptStat: transcriptStat,
                               settings: settings,
                               settingsStat: SessionFileStat.precise(from: settings))
    }

    static func loadTelemetry(for session: Session,
                              cancellationCheck: () -> Bool = { Task.isCancelled }) -> SessionTelemetryProviderScan? {
        loadTelemetryImplementation(for: session,
                                    cancellationCheck: cancellationCheck,
                                    readChunk: nil)
    }

    /// Test seam for proving that a descriptor read error reaches the provider's
    /// explicit unavailable result instead of being silently treated as EOF.
    static func loadTelemetryForTesting(
        for session: Session,
        cancellationCheck: () -> Bool = { Task.isCancelled },
        readChunk: @escaping (FileHandle, Int) throws -> Data
    ) -> SessionTelemetryProviderScan? {
        loadTelemetryImplementation(for: session,
                                    cancellationCheck: cancellationCheck,
                                    readChunk: readChunk)
    }

    private static func loadTelemetryImplementation(
        for session: Session,
        cancellationCheck: () -> Bool,
        readChunk: ((FileHandle, Int) throws -> Data)?) -> SessionTelemetryProviderScan? {
        guard session.source == .droid, !cancellationCheck() else {
            return nil
        }

        let transcript = transcriptURL(for: session)
        guard let transcriptHandle = try? FileHandle(forReadingFrom: transcript) else {
            return nil
        }
        let transcriptDescriptor = transcriptHandle.fileDescriptor
        guard let transcriptStat = SessionFileStat.precise(fromFileDescriptor: transcriptDescriptor) else {
            try? transcriptHandle.close()
            return nil
        }
        guard !cancellationCheck() else {
            try? transcriptHandle.close()
            return nil
        }
        defer { try? transcriptHandle.close() }

        let settingsURL = settingsURL(for: session)
        let settingsHandle = try? FileHandle(forReadingFrom: settingsURL)
        defer { try? settingsHandle?.close() }
        let settingsDescriptor = settingsHandle?.fileDescriptor
        let settingsStat = settingsDescriptor.flatMap { SessionFileStat.precise(fromFileDescriptor: $0) }
        let settingsData: Data?
        var settingsReadFailed = false
        if let settingsHandle {
            do {
                settingsData = try settingsHandle.readToEnd() ?? Data()
            } catch {
                settingsData = nil
                settingsReadFailed = true
            }
        } else {
            settingsData = nil
        }
        let inputRevision = logicalRevision(transcript: transcript,
                                            transcriptStat: transcriptStat,
                                            settings: settingsURL,
                                            settingsStat: settingsStat)
        let settingsBytes = settingsData?.count ?? 0

        var transcriptBytes: UInt64 = 0
        var observedSessionIDs = Set<String>()
        var identityConflict = false
        var isInteractive = false
        var timeline = ConfigurationTimeline(
            provenance: .providerChangeRecord,
            initialProvenance: .inferredFirstObservation)
        var sawConfiguration = false
        var completionTotals: [Int] = []
        var completionUsageWasMalformed = false
        var completionUsageWasAmbiguous = false
        var completionUsageWasSeen = false
        var transcriptEvidenceWasMalformed = false
        var transcriptReadCompleted = false
        var lineIndex = 0

        do {
            transcriptReadCompleted = try JSONLReader(url: transcript,
                                                      propagatesReadErrors: true,
                                                      readChunk: readChunk).forEachLineWhile(
                using: transcriptHandle,
                { rawLine in
                    guard !cancellationCheck() else { return false }
                    let currentLine = lineIndex
                    lineIndex += 1
                    guard let object = jsonObject(rawLine),
                          let rawType = object["type"] as? String else {
                        transcriptEvidenceWasMalformed = true
                        return true
                    }

                    let type = normalizedType(rawType)
                    guard !type.isEmpty else {
                        transcriptEvidenceWasMalformed = true
                        return true
                    }
                    if type == "omitted" {
                        transcriptEvidenceWasMalformed = true
                        return true
                    }

                    let identities = sessionIDs(in: object)
                    if identities.hasConflict {
                        identityConflict = true
                    }
                    observedSessionIDs.formUnion(identities.values)

                    if type == "sessionstart" || (type == "message" && object["message"] is [String: Any]) {
                        isInteractive = true
                    }

                    switch type {
                    case "system":
                        let model = stringValue(object, keys: ["model", "modelId", "model_name"])
                        let effort = stringValue(object, keys: ["reasoningEffort", "reasoning_effort", "effort"])
                        if model != nil || effort != nil {
                            sawConfiguration = true
                            timeline.observe(model: model,
                                             effort: effort,
                                             observedAt: date(object["timestamp"]),
                                             anchorLine: currentLine,
                                             provenance: .inferredFirstObservation)
                        }

                    case "modelchange":
                        let model = stringValue(object, keys: ["newModel", "new_model", "model", "modelId"])
                        let effort = stringValue(object, keys: ["reasoningEffort", "reasoning_effort", "effort"])
                        if model != nil || effort != nil {
                            sawConfiguration = true
                            timeline.observe(model: model,
                                             effort: effort,
                                             observedAt: date(object["timestamp"]),
                                             anchorLine: currentLine,
                                             provenance: .providerChangeRecord)
                        }

                    case "completion":
                        guard object["usage"] != nil else { return true }
                        completionUsageWasSeen = true
                        guard let usage = object["usage"] as? [String: Any] else {
                            completionUsageWasMalformed = true
                            return true
                        }
                        let totalEvidence = aliasedCount(in: usage,
                                                         keys: ["total_tokens", "totalTokens", "total"])
                        guard !totalEvidence.malformed, let total = totalEvidence.value else {
                            completionUsageWasMalformed = true
                            return true
                        }
                        if totalEvidence.conflicting {
                            completionUsageWasAmbiguous = true
                            return true
                        }
                        completionTotals.append(total)

                    default:
                        break
                    }
                    return true
                },
                reportBytesRead: { transcriptBytes = $0 },
                reportMalformedLine: { transcriptEvidenceWasMalformed = true })
        } catch {
            return invalidScan(bytesScanned: checkedByteCount(settingsBytes, transcriptBytes) ?? transcriptBytes,
                               currentConfiguration: nil,
                               reason: malformedUsageReason,
                               inputRevision: inputRevision)
        }

        let transcriptEndStat = SessionFileStat.precise(fromFileDescriptor: transcriptDescriptor)
        let settingsEndStat = settingsDescriptor.flatMap { SessionFileStat.precise(fromFileDescriptor: $0) }
        guard transcriptEndStat == transcriptStat,
              settingsEndStat == settingsStat else {
            return unstableScan(bytesScanned: checkedByteCount(settingsBytes, transcriptBytes) ?? transcriptBytes,
                                inputRevision: inputRevision)
        }

        guard let totalBytes = checkedByteCount(settingsBytes, transcriptBytes) else {
            return cancelledScan(bytesScanned: transcriptBytes, inputRevision: inputRevision)
        }
        guard transcriptReadCompleted, !cancellationCheck() else {
            return cancelledScan(bytesScanned: totalBytes, inputRevision: inputRevision)
        }

        let settings = parseSettings(settingsData)
        let selectedID = clean(session.id)
        let transcriptBaseMatches = transcriptBaseName(transcript) == selectedID
        let sidecarIdentityMatches = !isInteractive || settingsData == nil || transcriptBaseMatches
        let transcriptIdentityMatches = !identityConflict
            && observedSessionIDs.count == 1
            && selectedID.map { observedSessionIDs.contains($0) } == true

        guard transcriptIdentityMatches && sidecarIdentityMatches else {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: nil,
                               reason: identityReason,
                               inputRevision: inputRevision)
        }

        let settingsIsForInteractiveSession = isInteractive
            && settingsData != nil
            && transcriptBaseMatches
        let currentConfiguration: SessionConfiguration?
        if settingsIsForInteractiveSession, let settings {
            currentConfiguration = settings.configuration
        } else {
            currentConfiguration = timeline.currentConfiguration
        }

        if transcriptEvidenceWasMalformed {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: currentConfiguration,
                               reason: malformedUsageReason,
                               inputRevision: inputRevision)
        }

        if settingsReadFailed {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: currentConfiguration,
                               reason: malformedUsageReason,
                               inputRevision: inputRevision)
        }

        if settingsIsForInteractiveSession, let settings, settings.invalidConfiguration {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: currentConfiguration,
                               reason: malformedUsageReason,
                               inputRevision: inputRevision)
        }

        if settingsIsForInteractiveSession, let settings {
            if settings.invalidUsage {
                return invalidScan(bytesScanned: totalBytes,
                                   currentConfiguration: currentConfiguration,
                                   reason: malformedUsageReason,
                                   inputRevision: inputRevision)
            }
            if settings.sawUsage {
                let telemetry = makeTelemetry(
                    initialConfiguration: nil,
                    currentConfiguration: currentConfiguration,
                    configurationChanges: [],
                    summary: TelemetryUsageSummary(
                        topLineTokens: 0,
                        hasComponentBreakdown: false,
                        recordedTotalTokens: nil,
                        usageFamilies: ["settings.tokenUsage"],
                        usageFamilyConflict: false,
                        unavailableReason: usageUnavailableReason))
                _ = transcriptStat
                return SessionTelemetryProviderScan(
                    result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                           durableAccountHash: nil),
                    bytesScanned: totalBytes,
                    inputRevision: inputRevision)
            }
        }

        if completionUsageWasAmbiguous {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: currentConfiguration,
                               reason: "Droid completion usage aliases disagree within one record.",
                               inputRevision: inputRevision)
        }

        if completionUsageWasMalformed {
            return invalidScan(bytesScanned: totalBytes,
                               currentConfiguration: currentConfiguration,
                               reason: malformedUsageReason,
                               inputRevision: inputRevision)
        }

        if completionUsageWasSeen {
            guard completionTotals.count == 1,
                  let total = completionTotals.first else {
                return invalidScan(bytesScanned: totalBytes,
                                   currentConfiguration: currentConfiguration,
                                   reason: "Droid recorded multiple completion usage summaries with ambiguous scope.",
                                   inputRevision: inputRevision)
            }
            let summary = TelemetryUsageSummary(
                topLineTokens: total,
                hasComponentBreakdown: false,
                recordedTotalTokens: total,
                usageFamilies: ["completion.usage"],
                usageFamilyConflict: false,
                displayTotalTokens: total)
            let telemetry = makeTelemetry(
                initialConfiguration: timeline.initialConfiguration,
                currentConfiguration: currentConfiguration,
                configurationChanges: timeline.changes,
                summary: summary)
            _ = transcriptStat
            return SessionTelemetryProviderScan(
                result: SessionTelemetryProviderResult(telemetry: telemetry,
                                                       durableAccountHash: nil),
                bytesScanned: totalBytes,
                inputRevision: inputRevision)
        }

        let summary: TelemetryUsageSummary? = settingsIsForInteractiveSession || sawConfiguration
            ? TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: missingUsageReason)
            : nil
        let telemetry = makeTelemetry(
            initialConfiguration: timeline.initialConfiguration,
            currentConfiguration: currentConfiguration,
            configurationChanges: timeline.changes,
            summary: summary)
        _ = transcriptStat
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: totalBytes,
            inputRevision: inputRevision)
    }

    private struct SettingsEvidence {
        let configuration: SessionConfiguration?
        let sawUsage: Bool
        let invalidUsage: Bool
        let invalidConfiguration: Bool
    }

    private static func parseSettings(_ data: Data?) -> SettingsEvidence? {
        guard let data else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SettingsEvidence(configuration: nil,
                                    sawUsage: false,
                                    invalidUsage: true,
                                    invalidConfiguration: true)
        }

        let rawModel = object["model"]
        let rawEffort = object["reasoningEffort"]
        let model = clean(rawModel as? String)
        let effort = clean(rawEffort as? String)
        let invalidConfiguration = (rawModel != nil && model == nil)
            || (rawEffort != nil && effort == nil)
        let configuration: SessionConfiguration? = (model != nil || effort != nil)
            ? SessionConfiguration(model: model,
                                   reasoningEffort: effort,
                                   observedAt: nil,
                                   anchorLine: 0,
                                   provenance: .sessionMetadata)
            : nil

        guard let rawUsage = object["tokenUsage"] else {
            return SettingsEvidence(configuration: configuration,
                                    sawUsage: false,
                                    invalidUsage: false,
                                    invalidConfiguration: invalidConfiguration)
        }
        guard let usage = rawUsage as? [String: Any],
              count(usage["inputTokens"]) != nil,
              count(usage["cacheReadTokens"]) != nil,
              count(usage["cacheCreationTokens"]) != nil,
              count(usage["outputTokens"]) != nil,
              count(usage["thinkingTokens"]) != nil else {
            return SettingsEvidence(configuration: configuration,
                                    sawUsage: true,
                                    invalidUsage: true,
                                    invalidConfiguration: invalidConfiguration)
        }
        return SettingsEvidence(configuration: configuration,
                                sawUsage: true,
                                invalidUsage: false,
                                invalidConfiguration: invalidConfiguration)
    }

    private static func makeTelemetry(initialConfiguration: SessionConfiguration?,
                                      currentConfiguration: SessionConfiguration?,
                                      configurationChanges: [ConfigurationChange],
                                      summary: TelemetryUsageSummary?) -> SessionTelemetry {
        SessionTelemetry(source: .droid,
                         initialConfiguration: initialConfiguration,
                         currentConfiguration: currentConfiguration,
                         configurationChanges: configurationChanges,
                         usageSlices: [],
                         usageEvents: [],
                         usageSummary: summary,
                         costEstimate: nil)
    }

    private static func invalidScan(bytesScanned: UInt64,
                                    currentConfiguration: SessionConfiguration?,
                                    reason: String,
                                    inputRevision: SessionTelemetryRevision? = nil) -> SessionTelemetryProviderScan {
        let telemetry = makeTelemetry(
            initialConfiguration: nil,
            currentConfiguration: currentConfiguration,
            configurationChanges: [],
            summary: TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: [],
                usageFamilyConflict: false,
                unavailableReason: reason))
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }

    private static func cancelledScan(bytesScanned: UInt64,
                                      inputRevision: SessionTelemetryRevision? = nil) -> SessionTelemetryProviderScan {
        SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(
                telemetry: makeTelemetry(initialConfiguration: nil,
                                         currentConfiguration: nil,
                                         configurationChanges: [],
                                         summary: nil),
                durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }

    private static func unstableScan(bytesScanned: UInt64,
                                     inputRevision: SessionTelemetryRevision?) -> SessionTelemetryProviderScan {
        SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(
                telemetry: makeTelemetry(initialConfiguration: nil,
                                         currentConfiguration: nil,
                                         configurationChanges: [],
                                         summary: nil),
                durableAccountHash: nil),
            bytesScanned: bytesScanned,
            inputRevision: inputRevision,
            revisionChanged: true)
    }

    private static func transcriptURL(for session: Session) -> URL {
        URL(fileURLWithPath: session.filePath)
    }

    private static func settingsURL(for session: Session) -> URL {
        transcriptURL(for: session)
            .deletingPathExtension()
            .appendingPathExtension("settings.json")
    }

    private static func transcriptBaseName(_ url: URL) -> String? {
        clean(url.deletingPathExtension().lastPathComponent)
    }

    private static func sessionIDs(in object: [String: Any]) -> (values: Set<String>, hasConflict: Bool) {
        var values = Set<String>()
        for key in ["session_id", "sessionId", "session"] {
            if let value = clean(object[key] as? String) {
                values.insert(value)
            }
        }
        if normalizedType(object["type"] as? String) == "sessionstart",
           let value = clean(object["id"] as? String) {
            values.insert(value)
        }
        return (values, values.count > 1)
    }

    private static func normalizedType(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = clean(object[key] as? String) { return value }
        }
        return nil
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func aliasedCount(in object: [String: Any],
                                     keys: [String]) -> (value: Int?, malformed: Bool, conflicting: Bool) {
        var values: [Int] = []
        for key in keys {
            guard object.keys.contains(key) else { continue }
            guard let value = count(object[key]) else {
                return (nil, true, false)
            }
            values.append(value)
        }
        guard let first = values.first else {
            return (nil, true, false)
        }
        return (first, false, Set(values).count > 1)
    }

    private static func count(_ value: Any?) -> Int? {
        guard let value else { return nil }
        guard let numberValue = value as? NSNumber,
              CFGetTypeID(numberValue) != CFBooleanGetTypeID() else {
            return nil
        }
        if let int = value as? Int {
            guard int >= 0 else { return nil }
            return int
        }
        let number = numberValue.doubleValue
        guard number.isFinite,
              number >= 0,
              number < Double(Int.max),
              number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let string = value as? String {
            return ClaudeRunwayLog.date(string)
        }
        guard let milliseconds = count(value) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func checkedByteCount(_ first: Int, _ second: UInt64) -> UInt64? {
        guard first >= 0 else { return nil }
        let firstUInt = UInt64(first)
        let (total, overflow) = firstUInt.addingReportingOverflow(second)
        return overflow ? nil : total
    }

    private static func signature(path: URL, stat: SessionFileStat) -> String {
        "\(path.standardizedFileURL.path):mtime=\(stat.mtime):size=\(stat.size):fingerprint=\(stat.fingerprint ?? "")"
    }

    private static func logicalRevision(transcript: URL,
                                        transcriptStat: SessionFileStat,
                                        settings: URL,
                                        settingsStat: SessionFileStat?) -> SessionTelemetryRevision {
        let transcriptIdentity = signature(path: transcript, stat: transcriptStat)
        let settingsIdentity = settingsStat.map { signature(path: settings, stat: $0) } ?? "missing"
        return .logical("droid:v1|transcript=\(transcriptIdentity)|settings=\(settingsIdentity)")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
