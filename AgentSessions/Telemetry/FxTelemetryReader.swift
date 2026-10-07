import Foundation
import CryptoKit

/// Reads the audited aggregate telemetry in an fx session's `session.json`.
///
/// fx records the current model/effort and session-wide input/output totals in
/// the manifest. It does not provide a per-turn model timeline, cache split, or
/// pricing identity, so this reader exposes the total-token display only and
/// never manufactures request events or a cost estimate. The newer
/// `usage-v2.json` and append-only `events.jsonl` files are deliberately not
/// consumed until their ownership and schema are independently audited.
struct FxTelemetryReader {
    private static let manifestName = "session.json"
    private static let checkpointName = "checkpoint.json"

    private enum UsageEvidence {
        case absent
        case complete(input: Int, output: Int)
        case unavailable(String)
    }

    private struct Manifest {
        let data: Data
        let id: String
        let model: String?
        let effort: String?
        let usage: UsageEvidence

        var bytesScanned: UInt64 { UInt64(data.count) }
    }

    static func telemetryRevision(for session: Session) -> SessionTelemetryRevision? {
        guard isSupported(session),
              let manifest = readManifest(for: session) else {
            return nil
        }
        return .logical(revision(for: session, manifest: manifest))
    }

    static func loadTelemetry(for session: Session) -> SessionTelemetryProviderScan? {
        guard isSupported(session), !Task.isCancelled,
              let manifest = readManifest(for: session) else {
            return nil
        }
        let inputRevision = SessionTelemetryRevision.logical(revision(for: session, manifest: manifest))
        guard !Task.isCancelled else {
            return cancelledScan(bytesScanned: manifest.bytesScanned,
                                 inputRevision: inputRevision)
        }

        let model = clean(manifest.model) ?? clean(session.model)
        let effort = clean(manifest.effort) ?? clean(session.reasoningEffort)
        let currentConfiguration: SessionConfiguration? = {
            if let model {
                return SessionConfiguration(
                    unanchoredModel: model,
                    reasoningEffort: effort,
                    observedAt: nil,
                    anchorLine: nil,
                    provenance: .sessionMetadata,
                    reasoningEffortObservedAt: nil,
                    reasoningEffortAnchorLine: nil,
                    reasoningEffortProvenance: nil)
            }
            guard let effort else { return nil }
            return SessionConfiguration(
                model: nil,
                reasoningEffort: effort,
                observedAt: nil,
                anchorLine: nil,
                provenance: .sessionMetadata,
                reasoningEffortObservedAt: nil,
                reasoningEffortAnchorLine: nil,
                reasoningEffortProvenance: nil)
        }()

        let telemetry = SessionTelemetry(
            source: .fx,
            initialConfiguration: nil,
            currentConfiguration: currentConfiguration,
            configurationChanges: [],
            usageSlices: [],
            usageEvents: [],
            usageSummary: usageSummary(for: manifest.usage),
            costEstimate: nil,
            weeklyQuotaEstimate: nil)
        return SessionTelemetryProviderScan(
            result: SessionTelemetryProviderResult(telemetry: telemetry, durableAccountHash: nil),
            bytesScanned: manifest.bytesScanned,
            inputRevision: inputRevision)
    }

    static func isSupported(_ session: Session) -> Bool {
        session.source == .fx
            && URL(fileURLWithPath: session.filePath).lastPathComponent.lowercased() == checkpointName
    }

    private static func manifestURL(for session: Session) -> URL {
        URL(fileURLWithPath: session.filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(manifestName)
    }

    private static func readManifest(for session: Session) -> Manifest? {
        let url = manifestURL(for: session)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              nonNegativeInteger(object["schema_version"]) == 3,
              object["storage_format"] as? String == "event_log_v1",
              let id = clean(object["id"] as? String) else {
            return nil
        }

        let preferences = object["preferences"] as? [String: Any]
        let inputKeyPresent = object.keys.contains("total_input_tokens")
        let outputKeyPresent = object.keys.contains("total_output_tokens")
        let usage: UsageEvidence
        if !inputKeyPresent && !outputKeyPresent {
            usage = .absent
        } else if let input = nonNegativeInteger(object["total_input_tokens"]),
                  let output = nonNegativeInteger(object["total_output_tokens"]),
                  input.addingReportingOverflow(output).overflow == false {
            usage = .complete(input: input, output: output)
        } else {
            usage = .unavailable(
                "fx session.json total_input_tokens and total_output_tokens are incomplete or malformed.")
        }

        return Manifest(
            data: data,
            id: id,
            model: preferences?["model"] as? String,
            effort: preferences?["effort"] as? String,
            usage: usage)
    }

    private static func usageSummary(for evidence: UsageEvidence) -> TelemetryUsageSummary? {
        switch evidence {
        case .absent:
            return nil
        case let .complete(input, output):
            let total = input + output
            return TelemetryUsageSummary(
                topLineTokens: total,
                hasComponentBreakdown: false,
                recordedTotalTokens: total,
                usageFamilies: ["session.json.totals"],
                usageFamilyConflict: false,
                displayTotalTokens: total)
        case let .unavailable(reason):
            return TelemetryUsageSummary(
                topLineTokens: 0,
                hasComponentBreakdown: false,
                recordedTotalTokens: nil,
                usageFamilies: ["session.json.totals"],
                usageFamilyConflict: false,
                unavailableReason: reason)
        }
    }

    private static func revision(for session: Session, manifest: Manifest) -> String {
        let manifestDigest = SHA256.hash(data: manifest.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let fields: [String] = [
            session.id,
            manifest.id,
            manifestDigest
        ]
        let payload = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(("fx:v1|" + payload).utf8))
        return "fx:v1:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number),
              integer >= 0 else {
            return nil
        }
        return integer
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cancelledScan(bytesScanned: UInt64,
                                      inputRevision: SessionTelemetryRevision) -> SessionTelemetryProviderScan {
        let telemetry = SessionTelemetry(
            source: .fx,
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
            bytesScanned: bytesScanned,
            inputRevision: inputRevision)
    }
}
