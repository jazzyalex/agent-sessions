import CryptoKit
import Dispatch
import Foundation

/// Explicit launch opt-in for the in-memory search and transcript diagnostic recorder.
/// A normal app launch leaves this disabled. This is deliberately separate from product
/// preferences and feature flags.
public struct SearchResponsivenessBenchmarkInvocation: Sendable {
    public static let argument = "--benchmark-search-responsiveness"
    public static let environmentKey = "AGENTSESSIONS_BENCHMARK_SEARCH_RESPONSIVENESS"

    public let isEnabled: Bool

    public init(arguments: [String], environment: [String: String]) {
        isEnabled = arguments.contains(Self.argument)
            || environment[Self.environmentKey] == "1"
    }

    public static var currentProcess: Self {
        Self(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
    }
}

public struct SearchResponsivenessSessionIdentity: Hashable, Sendable {
    /// A stable source key such as `SessionSource.rawValue`. It is salted and hashed
    /// before it enters an event.
    public let source: String
    /// A stable provider-owned session key. It is salted and hashed before export.
    public let sessionID: String

    public init(source: String, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }
}

public struct SearchResponsivenessRevision: Hashable, Sendable {
    /// A source or content revision value. It is salted and hashed before export.
    public let value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum SearchResponsivenessHydration: String, Codable, Sendable {
    case notApplicable = "not_applicable"
    case notRequested = "not_requested"
    case unknown
    case provisional
    case partial
    case full
}

/// Raw inputs stay at the caller. The recorder immediately converts identity and
/// revision strings to salted digests and retains only those digests in open spans.
public struct SearchResponsivenessMetricContext: Equatable, Sendable {
    public let session: SearchResponsivenessSessionIdentity?
    public let contentRevision: SearchResponsivenessRevision?
    public let storageRevision: SearchResponsivenessRevision?
    public let hydration: SearchResponsivenessHydration
    public let presentationGeneration: Int64?
    public let credentialEpoch: UInt64?

    public init(
        session: SearchResponsivenessSessionIdentity? = nil,
        contentRevision: SearchResponsivenessRevision? = nil,
        storageRevision: SearchResponsivenessRevision? = nil,
        hydration: SearchResponsivenessHydration = .notApplicable,
        presentationGeneration: Int64? = nil,
        credentialEpoch: UInt64? = nil
    ) {
        self.session = session
        self.contentRevision = contentRevision
        self.storageRevision = storageRevision
        self.hydration = hydration
        self.presentationGeneration = presentationGeneration
        self.credentialEpoch = credentialEpoch
    }

    public static let none = SearchResponsivenessMetricContext()
}

/// The allow-listed event names used by the profiling specification. Values supplied
/// by callers never become event names, status strings, or counter keys.
public enum SearchResponsivenessStage: String, Codable, CaseIterable, Sendable {
    case discovery
    case selectionAccepted = "selection_accepted"
    case parseRequested = "parse_requested"
    case workerStarted = "worker_started"
    case tailRead = "tail_read"
    case provisionalHydrationPublished = "provisional_hydration_published"
    case fullReadDecode = "full_read_decode"
    case fullHydrationPublished = "full_hydration_published"
    case snapshot
    case snapshotCoalescing = "snapshot_coalescing"
    case snapshotDigests = "snapshot_digests"
    case invocationIndex = "invocation_index"
    case turnIndex = "turn_index"
    case anchorIndexes = "anchor_indexes"
    case markerDerivation = "marker_derivation"
    case groupDerivation = "group_derivation"
    case countDerivation = "count_derivation"
    case presentationPublished = "presentation_published"
    case tableApply = "table_apply"
    case layoutDisplayCompleted = "layout_display_completed"
    case firstContentVisible = "first_content_visible"
    case fullContentVisible = "full_content_visible"
    case partialContentVisible = "partial_content_visible"
    case findReady = "find_ready"
    case imageReady = "image_ready"
    case staleContentRejected = "stale_content_rejected"

    case credentialServiceWait = "credential_service_wait"
    case credentialPhysicalRead = "credential_physical_read"
    case credentialPhysicalWrite = "credential_physical_write"
    case credentialPhysicalDelete = "credential_physical_delete"
    case credentialMutationAccepted = "credential_mutation_accepted"
    case credentialMutationCompleted = "credential_mutation_completed"
    case credentialCacheLookup = "credential_cache_lookup"
    case credentialCacheWrite = "credential_cache_write"
    case credentialNetwork = "credential_network"
    case credentialPublicationAccepted = "credential_publication_accepted"
    case credentialPublicationRejected = "credential_publication_rejected"

    case searchRequestAccepted = "search_request_accepted"
    case searchEligibleCount = "search_eligible_count"
    case searchInstantFirstPublication = "search_instant_first_publication"
    case searchScanQueued = "search_scan_queued"
    case searchScanStarted = "search_scan_started"
    case searchSourceRevisionCheck = "search_source_revision_check"
    case searchSourceRevisionRetry = "search_source_revision_retry"
    case searchRecordsVisited = "search_records_visited"
    case searchOmission = "search_omission"
    case searchExtraction = "search_extraction"
    case searchMatching = "search_matching"
    case searchProvisionalResults = "search_provisional_results"
    case searchVerifiedResults = "search_verified_results"
    case searchRetainedPayloadPeak = "search_retained_payload_peak"
    case searchCancelRequested = "search_cancel_requested"
    case searchWorkerAcknowledged = "search_worker_acknowledged"
    case searchTerminal = "search_terminal"
    case searchCoverageCounters = "search_coverage_counters"
    case migrationCounts = "migration_counts"
    case migrationConvergence = "migration_convergence"
    case recorderOverflow = "recorder_overflow"

    fileprivate var isVisibleContentClaim: Bool {
        switch self {
        case .firstContentVisible, .fullContentVisible, .partialContentVisible:
            return true
        default:
            return false
        }
    }
}

public enum SearchResponsivenessMetricPhase: String, Codable, Sendable {
    case instant
    case begin
    case end
    case cancel
    case error
    case missing
}

public enum SearchResponsivenessStatus: String, Codable, Sendable {
    case unknown
    case accepted
    case queued
    case started
    case succeeded
    case partial
    case provisional
    case verified
    case published
    case rejected
    case stale
    case notRequested = "not_requested"
    case notReached = "not_reached"
    case notApplicable = "not_applicable"
    case cancelled
    case failed
    case cacheHit = "cache_hit"
    case cacheMiss = "cache_miss"
}

public enum SearchResponsivenessFailureCode: String, Codable, Sendable {
    case readError = "read_error"
    case decodeError = "decode_error"
    case sourceChanged = "source_changed"
    case unavailable
    case superseded
    case rejected
    case staleIdentity = "stale_identity"
    case staleRevision = "stale_revision"
    case unknown
}

public enum SearchResponsivenessMissingReason: String, Codable, Sendable {
    case notRequested = "not_requested"
    case notReached = "not_reached"
    case unsupported
    case notApplicable = "not_applicable"
}

public enum SearchResponsivenessOmissionReason: String, Codable, Sendable {
    case oversized
    case malformed
    case readError = "read_error"
    case unsupported
    case cancelled
    case sourceChanged = "source_changed"
    case staleRevision = "stale_revision"
    case permissionDenied = "permission_denied"
    case decompressionLimit = "decompression_limit"
    case unknown
}

public enum SearchResponsivenessCounter: String, Codable, CaseIterable, Sendable {
    case physicalBytes = "physical_bytes"
    case decodedBytes = "decoded_bytes"
    case recordsVisited = "records_visited"
    case eligibleSessions = "eligible_sessions"
    case omittedRecords = "omitted_records"
    case omittedBytes = "omitted_bytes"
    case provisionalResults = "provisional_results"
    case verifiedResults = "verified_results"
    case retainedPayloadBytes = "retained_payload_bytes"
    case completeSessions = "complete_sessions"
    case incompleteSessions = "incomplete_sessions"
    case sourceChangedRetries = "source_changed_retries"
    case coalescedWaiters = "coalesced_waiters"
    case pendingMigrations = "pending_migrations"
    case currentMigrations = "current_migrations"
    case failedMigrations = "failed_migrations"
    case resultCount = "result_count"
    case cacheHits = "cache_hits"
    case cacheMisses = "cache_misses"
}

public struct SearchResponsivenessOperationID: Hashable, Sendable {
    fileprivate let value: UUID

    public var rawValue: String { value.uuidString.lowercased() }

    fileprivate init(_ value: UUID) {
        self.value = value
    }
}

public struct SearchResponsivenessSpan: Sendable {
    fileprivate let tokenID: UUID
    public let operationID: SearchResponsivenessOperationID

    fileprivate init(tokenID: UUID, operationID: SearchResponsivenessOperationID) {
        self.tokenID = tokenID
        self.operationID = operationID
    }
}

public struct SearchResponsivenessMetricCounterValue: Codable, Equatable, Sendable {
    public let key: SearchResponsivenessCounter
    public let value: Int64
}

/// JSONL row. Optional owner fields are encoded explicitly as JSON `null`, so global
/// stages remain distinguishable from accidentally missing schema data.
public struct SearchResponsivenessMetricEvent: Codable, Equatable, Sendable {
    public struct SessionOwner: Codable, Equatable, Sendable {
        public let sourceID: String
        public let sessionID: String

        private enum CodingKeys: String, CodingKey {
            case sourceID = "source_id"
            case sessionID = "session_id"
        }
    }

    public let schemaVersion: Int
    public let eventID: String
    public let runID: String
    public let operationID: String
    public let parentID: String?
    public let stage: SearchResponsivenessStage
    public let phase: SearchResponsivenessMetricPhase
    public let timestampNanoseconds: UInt64
    public let durationNanoseconds: UInt64?
    public let session: SessionOwner?
    public let contentRevision: String?
    public let storageRevision: String?
    public let hydration: SearchResponsivenessHydration
    public let presentationGeneration: Int64?
    public let credentialEpoch: UInt64?
    public let status: SearchResponsivenessStatus
    public let failureCode: SearchResponsivenessFailureCode?
    public let omissionReason: SearchResponsivenessOmissionReason?
    public let counters: [SearchResponsivenessMetricCounterValue]
    public let droppedEventCount: Int

    fileprivate init(
        eventID: String,
        runID: String,
        operationID: String,
        parentID: String?,
        stage: SearchResponsivenessStage,
        phase: SearchResponsivenessMetricPhase,
        timestampNanoseconds: UInt64,
        durationNanoseconds: UInt64? = nil,
        owner: SearchResponsivenessSanitizedContext,
        status: SearchResponsivenessStatus,
        failureCode: SearchResponsivenessFailureCode? = nil,
        omissionReason: SearchResponsivenessOmissionReason? = nil,
        counters: [SearchResponsivenessMetricCounterValue] = [],
        droppedEventCount: Int = 0
    ) {
        schemaVersion = 1
        self.eventID = eventID
        self.runID = runID
        self.operationID = operationID
        self.parentID = parentID
        self.stage = stage
        self.phase = phase
        self.timestampNanoseconds = timestampNanoseconds
        self.durationNanoseconds = durationNanoseconds
        session = owner.session
        contentRevision = owner.contentRevision
        storageRevision = owner.storageRevision
        hydration = owner.hydration
        presentationGeneration = owner.presentationGeneration
        credentialEpoch = owner.credentialEpoch
        self.status = status
        self.failureCode = failureCode
        self.omissionReason = omissionReason
        self.counters = counters
        self.droppedEventCount = droppedEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case runID = "run_id"
        case operationID = "operation_id"
        case parentID = "parent_id"
        case stage
        case phase
        case timestampNanoseconds = "timestamp_ns"
        case durationNanoseconds = "duration_ns"
        case session = "session_identity"
        case contentRevision = "content_revision"
        case storageRevision = "storage_revision"
        case hydration = "hydration_completeness"
        case presentationGeneration = "presentation_generation"
        case credentialEpoch = "credential_epoch"
        case status
        case failureCode = "failure_code"
        case omissionReason = "omission_reason"
        case counters
        case droppedEventCount = "dropped_event_count"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(runID, forKey: .runID)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(parentID, forKey: .parentID)
        try container.encode(stage, forKey: .stage)
        try container.encode(phase, forKey: .phase)
        try container.encode(timestampNanoseconds, forKey: .timestampNanoseconds)
        try container.encode(durationNanoseconds, forKey: .durationNanoseconds)
        try container.encode(session, forKey: .session)
        try container.encode(contentRevision, forKey: .contentRevision)
        try container.encode(storageRevision, forKey: .storageRevision)
        try container.encode(hydration, forKey: .hydration)
        try container.encode(presentationGeneration, forKey: .presentationGeneration)
        try container.encode(credentialEpoch, forKey: .credentialEpoch)
        try container.encode(status, forKey: .status)
        try container.encode(failureCode, forKey: .failureCode)
        try container.encode(omissionReason, forKey: .omissionReason)
        try container.encode(counters, forKey: .counters)
        try container.encode(droppedEventCount, forKey: .droppedEventCount)
    }
}

fileprivate struct SearchResponsivenessSanitizedContext: Equatable, Sendable {
    let session: SearchResponsivenessMetricEvent.SessionOwner?
    let contentRevision: String?
    let storageRevision: String?
    let hydration: SearchResponsivenessHydration
    let presentationGeneration: Int64?
    let credentialEpoch: UInt64?
}

/// Bounded, lock-protected, in-memory diagnostic recorder. It emits no events and reads
/// no clock when the process was not explicitly launched for a benchmark. Export is a
/// separate caller-requested JSONL write to exactly the supplied URL.
public final class SearchResponsivenessMetrics: @unchecked Sendable {
    public enum ExportError: Error, Equatable {
        case disabled
        case noEvents
        case openSpans(Int)
    }

    public static let shared = SearchResponsivenessMetrics()
    private var operations: [String: SearchResponsivenessOperationID] = [:]
    private var selectedOperation: SearchResponsivenessOperationID?

    public static let defaultMaximumEventCount = 100_000

    private struct ActiveSpan {
        let operationID: SearchResponsivenessOperationID
        let parentID: SearchResponsivenessOperationID?
        let stage: SearchResponsivenessStage
        let startedAt: UInt64
        let owner: SearchResponsivenessSanitizedContext
    }

    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private let maximumEventCount: Int
    private let runID: UUID?
    private let hashSalt: String?
    private var events: [SearchResponsivenessMetricEvent] = []
    private var activeSpans: [UUID: ActiveSpan] = [:]
    private var reservedSpanEndEvents = 0
    private var droppedEventCount = 0

    public let isEnabled: Bool

    public convenience init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        maximumEventCount: Int = defaultMaximumEventCount
    ) {
        self.init(invocation: .currentProcess, now: now, maximumEventCount: maximumEventCount)
    }

    public init(
        invocation: SearchResponsivenessBenchmarkInvocation,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        maximumEventCount: Int = defaultMaximumEventCount
    ) {
        isEnabled = invocation.isEnabled
        self.now = now
        self.maximumEventCount = max(1, maximumEventCount)
        runID = invocation.isEnabled ? UUID() : nil
        hashSalt = invocation.isEnabled ? UUID().uuidString : nil
    }

    public var eventsSnapshot: [SearchResponsivenessMetricEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.map { $0.replacingDroppedEventCount(droppedEventCount) }
    }

    public var droppedEventCountSnapshot: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedEventCount
    }

    public func newOperationID() -> SearchResponsivenessOperationID? {
        guard isEnabled else { return nil }
        return SearchResponsivenessOperationID(UUID())
    }

    /// Records a point event. Keep counters numeric and allow-listed; arbitrary labels,
    /// queries, paths, error descriptions and content are not accepted by this API.
    public func record(
        _ stage: SearchResponsivenessStage,
        operationID: SearchResponsivenessOperationID? = nil,
        parentID: SearchResponsivenessOperationID? = nil,
        context: SearchResponsivenessMetricContext = .none,
        status: SearchResponsivenessStatus = .unknown,
        counters: [SearchResponsivenessCounter: Int64] = [:]
    ) {
        guard !stage.isVisibleContentClaim else { return }
        recordEvent(
            stage,
            operationID: operationID,
            parentID: parentID,
            context: context,
            status: status,
            counters: counters)
    }

    @discardableResult
    private func recordEvent(
        _ stage: SearchResponsivenessStage,
        operationID: SearchResponsivenessOperationID?,
        parentID: SearchResponsivenessOperationID?,
        context: SearchResponsivenessMetricContext,
        status: SearchResponsivenessStatus,
        counters: [SearchResponsivenessCounter: Int64]
    ) -> Bool {
        guard isEnabled, let runID else { return false }
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        return appendIfAvailable(makeEvent(
            runID: runID,
            operationID: operationID ?? SearchResponsivenessOperationID(UUID()),
            parentID: parentID,
            stage: stage,
            phase: .instant,
            timestamp: timestamp,
            owner: sanitize(context),
            status: status,
            counters: counterValues(counters)))
    }

    /// Starts a span and reserves room for its terminal event, so normal point events
    /// cannot evict a matching end, cancel or error row at the event bound.
    @discardableResult
    public func beginSpan(
        _ stage: SearchResponsivenessStage,
        parentID: SearchResponsivenessOperationID? = nil,
        operationID: SearchResponsivenessOperationID? = nil,
        context: SearchResponsivenessMetricContext = .none,
        counters: [SearchResponsivenessCounter: Int64] = [:]
    ) -> SearchResponsivenessSpan? {
        guard isEnabled, let runID, !stage.isVisibleContentClaim else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard events.count + reservedSpanEndEvents + 2 <= maximumEventCount else {
            droppedEventCount += 1
            return nil
        }

        let tokenID = UUID()
        let spanOperationID = operationID ?? SearchResponsivenessOperationID(UUID())
        let owner = sanitize(context)
        let startedAt = now()
        activeSpans[tokenID] = ActiveSpan(
            operationID: spanOperationID,
            parentID: parentID,
            stage: stage,
            startedAt: startedAt,
            owner: owner)
        reservedSpanEndEvents += 1
        appendReserved(makeEvent(
            runID: runID,
            operationID: spanOperationID,
            parentID: parentID,
            stage: stage,
            phase: .begin,
            timestamp: startedAt,
            owner: owner,
            status: .started,
            counters: counterValues(counters)))
        return SearchResponsivenessSpan(tokenID: tokenID, operationID: spanOperationID)
    }

    public func end(
        _ span: SearchResponsivenessSpan,
        status: SearchResponsivenessStatus = .succeeded,
        counters: [SearchResponsivenessCounter: Int64] = [:]
    ) {
        finish(span, phase: .end, status: status, counters: counters)
    }

    public func cancel(
        _ span: SearchResponsivenessSpan,
        counters: [SearchResponsivenessCounter: Int64] = [:]
    ) {
        finish(span, phase: .cancel, status: .cancelled, counters: counters)
    }

    public func fail(
        _ span: SearchResponsivenessSpan,
        code: SearchResponsivenessFailureCode,
        counters: [SearchResponsivenessCounter: Int64] = [:]
    ) {
        finish(span, phase: .error, status: .failed, failureCode: code, counters: counters)
    }

    /// Emits an explicit missing row. Missing/not-requested work has no duration field.
    public func recordMissing(
        _ stage: SearchResponsivenessStage,
        reason: SearchResponsivenessMissingReason,
        operationID: SearchResponsivenessOperationID? = nil,
        parentID: SearchResponsivenessOperationID? = nil,
        context: SearchResponsivenessMetricContext = .none
    ) {
        guard isEnabled, let runID else { return }
        lock.lock()
        defer { lock.unlock() }
        let status: SearchResponsivenessStatus
        switch reason {
        case .notRequested: status = .notRequested
        case .notReached: status = .notReached
        case .unsupported: status = .failed
        case .notApplicable: status = .notApplicable
        }
        appendIfAvailable(makeEvent(
            runID: runID,
            operationID: operationID ?? SearchResponsivenessOperationID(UUID()),
            parentID: parentID,
            stage: stage,
            phase: .missing,
            timestamp: now(),
            owner: sanitize(context),
            status: status,
            failureCode: reason == .unsupported ? .unavailable : nil))
    }

    /// Records only a matching selected identity and revision as first visible content.
    /// A delayed row from a prior selection is represented as a rejection event instead.
    @discardableResult
    public func recordFirstContentVisible(
        selected: SearchResponsivenessMetricContext,
        presented: SearchResponsivenessMetricContext,
        operationID: SearchResponsivenessOperationID? = nil,
        parentID: SearchResponsivenessOperationID? = nil
    ) -> Bool {
        recordVisibleContent(
            .firstContentVisible,
            selected: selected,
            presented: presented,
            operationID: operationID,
            parentID: parentID)
    }

    /// Records full or partial visible presentation only after the same owner check
    /// used for first content. Generic `record` and `beginSpan` reject visibility stages.
    @discardableResult
    public func recordVisibleContent(
        _ stage: SearchResponsivenessStage,
        selected: SearchResponsivenessMetricContext,
        presented: SearchResponsivenessMetricContext,
        operationID: SearchResponsivenessOperationID? = nil,
        parentID: SearchResponsivenessOperationID? = nil
    ) -> Bool {
        guard stage.isVisibleContentClaim, isEnabled else { return false }

        let hasMatchingOwner = selected.session != nil
            && selected.session == presented.session
            && selected.contentRevision != nil
            && selected.contentRevision == presented.contentRevision
            && selected.storageRevision != nil
            && selected.storageRevision == presented.storageRevision
        let readable = [.provisional, .partial, .full].contains(presented.hydration)
        let correctCompleteness = stage != .fullContentVisible || presented.hydration == .full
        if hasMatchingOwner && readable && correctCompleteness {
            return recordEvent(
                stage,
                operationID: operationID,
                parentID: parentID,
                context: presented,
                status: .published,
                counters: [:])
        }

        recordEvent(
            .staleContentRejected,
            operationID: operationID,
            parentID: parentID,
            context: selected,
            status: .stale,
            counters: [:])
        return false
    }

    /// Records a safe, typed omission cause without serializing provider error text.
    public func recordOmission(
        _ reason: SearchResponsivenessOmissionReason,
        operationID: SearchResponsivenessOperationID? = nil,
        parentID: SearchResponsivenessOperationID? = nil,
        context: SearchResponsivenessMetricContext = .none,
        count: Int64 = 1
    ) {
        guard isEnabled, let runID else { return }
        lock.lock()
        defer { lock.unlock() }
        appendIfAvailable(makeEvent(
            runID: runID,
            operationID: operationID ?? SearchResponsivenessOperationID(UUID()),
            parentID: parentID,
            stage: .searchOmission,
            phase: .instant,
            timestamp: now(),
            owner: sanitize(context),
            status: .partial,
            omissionReason: reason,
            counters: counterValues([.omittedRecords: max(0, count)])))
    }

    /// Writes the current immutable snapshot as JSON Lines. This method is the only
    /// filesystem operation in the recorder and is never called implicitly.
    public func export(to url: URL) throws {
        guard isEnabled else { throw ExportError.disabled }

        lock.lock()
        let rows = events.map { $0.replacingDroppedEventCount(droppedEventCount) }
        let openSpanCount = activeSpans.count
        lock.unlock()
        guard openSpanCount == 0 else { throw ExportError.openSpans(openSpanCount) }
        guard !rows.isEmpty else { throw ExportError.noEvents }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for row in rows {
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    private func finish(
        _ span: SearchResponsivenessSpan,
        phase: SearchResponsivenessMetricPhase,
        status: SearchResponsivenessStatus,
        failureCode: SearchResponsivenessFailureCode? = nil,
        counters: [SearchResponsivenessCounter: Int64]
    ) {
        guard isEnabled, let runID else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let active = activeSpans.removeValue(forKey: span.tokenID) else { return }

        reservedSpanEndEvents = max(0, reservedSpanEndEvents - 1)
        let finishedAt = now()
        let duration = finishedAt >= active.startedAt ? finishedAt - active.startedAt : 0
        appendReserved(makeEvent(
            runID: runID,
            operationID: active.operationID,
            parentID: active.parentID,
            stage: active.stage,
            phase: phase,
            timestamp: finishedAt,
            duration: duration,
            owner: active.owner,
            status: status,
            failureCode: failureCode,
            counters: counterValues(counters)))
    }

    private func sanitize(_ context: SearchResponsivenessMetricContext) -> SearchResponsivenessSanitizedContext {
        let session = context.session.map { identity in
            SearchResponsivenessMetricEvent.SessionOwner(
                sourceID: opaque("source", identity.source),
                sessionID: opaque("session", identity.source + "\u{0}" + identity.sessionID))
        }
        return SearchResponsivenessSanitizedContext(
            session: session,
            contentRevision: context.contentRevision.map { opaque("content_revision", $0.value) },
            storageRevision: context.storageRevision.map { opaque("storage_revision", $0.value) },
            hydration: context.hydration,
            presentationGeneration: context.presentationGeneration,
            credentialEpoch: context.credentialEpoch)
    }

    private func opaque(_ domain: String, _ value: String) -> String {
        let material = Data("\(hashSalt ?? "")\u{0}\(domain)\u{0}\(value)".utf8)
        return "opaque-" + SHA256.hash(data: material).map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    private func counterValues(
        _ counters: [SearchResponsivenessCounter: Int64]
    ) -> [SearchResponsivenessMetricCounterValue] {
        counters
            .filter { $0.value >= 0 }
            .map { SearchResponsivenessMetricCounterValue(key: $0.key, value: $0.value) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    private func makeEvent(
        runID: UUID,
        operationID: SearchResponsivenessOperationID,
        parentID: SearchResponsivenessOperationID?,
        stage: SearchResponsivenessStage,
        phase: SearchResponsivenessMetricPhase,
        timestamp: UInt64,
        duration: UInt64? = nil,
        owner: SearchResponsivenessSanitizedContext,
        status: SearchResponsivenessStatus,
        failureCode: SearchResponsivenessFailureCode? = nil,
        omissionReason: SearchResponsivenessOmissionReason? = nil,
        counters: [SearchResponsivenessMetricCounterValue] = []
    ) -> SearchResponsivenessMetricEvent {
        SearchResponsivenessMetricEvent(
            eventID: UUID().uuidString.lowercased(),
            runID: runID.uuidString.lowercased(),
            operationID: operationID.rawValue,
            parentID: parentID?.rawValue,
            stage: stage,
            phase: phase,
            timestampNanoseconds: timestamp,
            durationNanoseconds: duration,
            owner: owner,
            status: status,
            failureCode: failureCode,
            omissionReason: omissionReason,
            counters: counters)
    }

    @discardableResult
    private func appendIfAvailable(_ event: SearchResponsivenessMetricEvent) -> Bool {
        guard events.count + reservedSpanEndEvents < maximumEventCount else {
            droppedEventCount += 1
            return false
        }
        events.append(event)
        return true
    }

    private func appendReserved(_ event: SearchResponsivenessMetricEvent) {
        guard events.count < maximumEventCount else {
            // This is unreachable while the reservation invariant is intact. Retain the
            // failure signal rather than growing memory if a future change breaks it.
            droppedEventCount += 1
            return
        }
        events.append(event)
    }
}

private extension SearchResponsivenessMetricEvent {
    func replacingDroppedEventCount(_ count: Int) -> Self {
        Self(
            eventID: eventID,
            runID: runID,
            operationID: operationID,
            parentID: parentID,
            stage: stage,
            phase: phase,
            timestampNanoseconds: timestampNanoseconds,
            durationNanoseconds: durationNanoseconds,
            owner: SearchResponsivenessSanitizedContext(
                session: session,
                contentRevision: contentRevision,
                storageRevision: storageRevision,
                hydration: hydration,
                presentationGeneration: presentationGeneration,
                credentialEpoch: credentialEpoch),
            status: status,
            failureCode: failureCode,
            omissionReason: omissionReason,
            counters: counters,
            droppedEventCount: count)
    }
}

// App wiring keeps operation roots bounded and excludes source text, query and path.
extension SearchResponsivenessMetrics {
    func operation(source: String, sessionID: String, start: Bool = false) -> SearchResponsivenessOperationID? {
        guard isEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = SHA256.hash(data: Data(((hashSalt ?? "") + source + ":" + sessionID).utf8)).map { String(format: "%02x", $0) }.joined()
        if !start, let value = operations[key] { return value }
        if operations.count >= 256 { operations.removeAll(keepingCapacity: true) }
        let value = SearchResponsivenessOperationID(UUID())
        operations[key] = value
        if start { selectedOperation = value }
        return value
    }

    func isCurrentSelection(_ operation: SearchResponsivenessOperationID?) -> Bool {
        guard isEnabled, let operation else { return false }
        lock.lock(); defer { lock.unlock() }
        return selectedOperation == operation
    }

    func clearSelection() {
        lock.lock(); selectedOperation = nil; lock.unlock()
    }

    func measured<T>(_ stage: SearchResponsivenessStage,
                     operationID: SearchResponsivenessOperationID? = nil,
                     parentID: SearchResponsivenessOperationID? = nil,
                     context: SearchResponsivenessMetricContext = .none,
                     _ body: () throws -> T) rethrows -> T {
        let span = beginSpan(stage, parentID: operationID ?? parentID, context: context)
        do {
            let value = try body()
            if let span { Task.isCancelled ? cancel(span) : end(span) }
            return value
        } catch {
            if let span { Task.isCancelled ? cancel(span) : fail(span, code: .unknown) }
            throw error
        }
    }
}

extension SearchResponsivenessMetricContext {
    static func session(_ session: Session, generation: Int? = nil) -> Self {
        guard SearchResponsivenessMetrics.shared.isEnabled else { return .none }
        return .init(session: .init(source: session.source.rawValue, sessionID: session.id),
            contentRevision: .init(session.contentRevision.uuidString),
            storageRevision: .init(session.sourceStorageRevision ?? session.sourceFileStat.map { String(describing: $0) }
                ?? "publication:" + session.contentRevision.uuidString),
            hydration: session.events.isEmpty ? .notRequested : (session.isPartiallyHydrated ? .provisional : .full),
            presentationGeneration: generation.map(Int64.init))
    }
}

/// Request ownership crosses provider/store awaits without logging the query.
enum SearchMetricScope {
    @TaskLocal static var requestID: SearchResponsivenessOperationID?
}
