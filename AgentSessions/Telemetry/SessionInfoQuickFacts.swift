import Foundation

/// The source of a value shown in the immediate Session Info surface.
///
/// A quick fact is deliberately honest about whether it came from the session
/// row or from a transcript-derived observation. The row currently exposes the
/// source's current/selected model, while first-observed values require the
/// optional telemetry pass.
public enum SessionInfoProvenance: String, Codable, Hashable, Sendable {
    case currentModel
    case currentConfiguration
    case firstObserved
    case sessionMetadata

    public var displayName: String {
        switch self {
        case .currentModel: return "Current model"
        case .currentConfiguration: return "Current configuration"
        case .firstObserved: return "First observed"
        case .sessionMetadata: return "Session metadata"
        }
    }
}

/// Why a quick Session Info value cannot be shown yet.
public enum SessionInfoUnavailableReason: String, Codable, Hashable, Sendable {
    case notRecorded
    case notLoaded
    case unsupported
    case parseFailed
    case ambiguous
    case redacted

    public var displayName: String {
        switch self {
        case .notRecorded: return "Not recorded"
        case .notLoaded: return "Not loaded"
        case .unsupported: return "Not supported"
        case .parseFailed: return "Could not read"
        case .ambiguous: return "Ambiguous"
        case .redacted: return "Redacted"
        }
    }
}

/// Lifecycle of the optional detailed telemetry pass for the visible Session Info panel.
/// This keeps a completed failed read distinct from a scan that has not started yet.
public enum SessionInfoTelemetryLoadState: Equatable, Sendable {
    case notStarted
    case loading
    case loaded
    case unavailable(SessionInfoUnavailableReason)
}

/// A value with provenance, or an explicit unavailable state.
public enum SessionInfoField<Value: Hashable & Sendable>: Hashable, Sendable {
    case known(Value, provenance: SessionInfoProvenance)
    case unavailable(SessionInfoUnavailableReason)

    public var value: Value? {
        guard case let .known(value, _) = self else { return nil }
        return value
    }

    public var provenance: SessionInfoProvenance? {
        guard case let .known(_, provenance) = self else { return nil }
        return provenance
    }

    public var unavailableReason: SessionInfoUnavailableReason? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

/// The stable identity of one quick-info paint episode.
///
/// Model/title/configuration updates should refresh the displayed rows, but they
/// are not a new session selection and must not inflate first-paint metrics.
public struct SessionInfoQuickPaintIdentity: Hashable, Sendable {
    public let source: SessionSource
    public let sessionID: String

    public init(source: SessionSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }
}

/// Pure state for one quick-info paint episode. Keeping arming and recording
/// together makes selection changes, refreshes, and close/reopen transitions
/// testable without depending on SwiftUI task scheduling.
public struct SessionInfoQuickPaintState: Equatable, Sendable {
    public private(set) var identity: SessionInfoQuickPaintIdentity?
    public private(set) var startedAt: Date?
    private var recordedIdentity: SessionInfoQuickPaintIdentity?

    public init() {}

    public mutating func arm(identity: SessionInfoQuickPaintIdentity?, at date: Date) {
        guard let identity else {
            reset()
            return
        }
        guard self.identity != identity else { return }
        self.identity = identity
        startedAt = date
        recordedIdentity = nil
    }

    public mutating func reset() {
        identity = nil
        startedAt = nil
        recordedIdentity = nil
    }

    public mutating func recordIfNeeded(
        identity: SessionInfoQuickPaintIdentity,
        at date: Date
    ) -> TimeInterval? {
        guard self.identity == identity,
              let startedAt,
              recordedIdentity != identity else { return nil }
        recordedIdentity = identity
        return max(0, date.timeIntervalSince(startedAt))
    }

    public mutating func recordModelFirstPaintIfNeeded(
        identity: SessionInfoQuickPaintIdentity,
        modelIsKnown: Bool,
        at date: Date
    ) -> TimeInterval? {
        guard modelIsKnown else { return nil }
        return recordIfNeeded(identity: identity, at: date)
    }
}

/// The stable identity of the quick facts shown for a session.
///
/// This is a value object rather than a delimiter-joined string so arbitrary
/// session IDs and provider values cannot collide.
public struct SessionInfoQuickFactsIdentity: Hashable, Sendable {
    public let source: SessionSource
    public let sessionID: String
    public let currentModel: SessionInfoField<String>
    public let firstObservedModel: SessionInfoField<String>
    public let reasoningEffort: SessionInfoField<String>
    public let title: SessionInfoField<String>

    public init(
        source: SessionSource,
        sessionID: String,
        currentModel: SessionInfoField<String>,
        firstObservedModel: SessionInfoField<String>,
        reasoningEffort: SessionInfoField<String>,
        title: SessionInfoField<String>
    ) {
        self.source = source
        self.sessionID = sessionID
        self.currentModel = currentModel
        self.firstObservedModel = firstObservedModel
        self.reasoningEffort = reasoningEffort
        self.title = title
    }
}

/// Metadata that can be rendered immediately from an already-loaded Session.
///
/// This type intentionally does not inspect `events`, read `filePath`, or start
/// a parser. It therefore remains useful for all registered sources, including
/// sources whose detailed telemetry is unavailable.
public struct SessionInfoQuickFacts: Hashable, Sendable {
    public let source: SessionSource
    public let sessionID: String
    public let currentModel: SessionInfoField<String>
    public let firstObservedModel: SessionInfoField<String>
    public let reasoningEffort: SessionInfoField<String>
    public let title: SessionInfoField<String>

    /// Changes whenever a value that can affect the immediate surface changes.
    /// The parent view uses this instead of the Session's full value identity.
    public let identity: SessionInfoQuickFactsIdentity
    public let paintIdentity: SessionInfoQuickPaintIdentity

    public init(session: Session) {
        self.source = session.source
        self.sessionID = session.id
        self.currentModel = Self.field(
            session.model,
            provenance: .currentModel,
            missing: .notRecorded)
        self.firstObservedModel = Self.firstObservedModelField(for: session.source)
        self.reasoningEffort = Self.field(
            session.reasoningEffort,
            provenance: .currentConfiguration,
            missing: .notRecorded)

        // `customTitle` and `lightweightTitle` are both already-loaded row
        // metadata. Calling Session.title here could inspect transcript events
        // and would turn quick info back into a parse-triggering surface.
        let metadataTitle = Self.firstNonEmpty(session.customTitle, session.lightweightTitle)
        self.title = Self.field(
            metadataTitle,
            provenance: .sessionMetadata,
            missing: .notLoaded)

        self.identity = SessionInfoQuickFactsIdentity(
            source: session.source,
            sessionID: session.id,
            currentModel: currentModel,
            firstObservedModel: firstObservedModel,
            reasoningEffort: reasoningEffort,
            title: title)
        self.paintIdentity = SessionInfoQuickPaintIdentity(
            source: session.source,
            sessionID: session.id)
    }

    private static func field(
        _ rawValue: String?,
        provenance: SessionInfoProvenance,
        missing: SessionInfoUnavailableReason
    ) -> SessionInfoField<String> {
        guard let rawValue else { return .unavailable(missing) }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .unavailable(missing) }
        return .known(value, provenance: provenance)
    }

    private static func firstObservedModelField(
        for source: SessionSource
    ) -> SessionInfoField<String> {
        // A source without a registry-owned telemetry provider can never move
        // this field from its pending state. Mark that boundary immediately so
        // the quick surface does not promise a scan that the engine cannot run.
        guard SessionSourceRegistry.descriptor(for: source).makeTelemetryProvider != nil else {
            return .unavailable(.unsupported)
        }
        return .unavailable(.notLoaded)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

}
