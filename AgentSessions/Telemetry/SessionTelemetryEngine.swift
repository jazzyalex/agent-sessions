import Foundation

/// Account identity is only trustworthy when the transcript itself records it
/// in a durable session metadata record. The current signed-in auth file cannot
/// identify a historical transcript: an account switch leaves old files in
/// place. Unknown, conflicting, or free-form message fields therefore produce
/// no identity and make weekly attribution fail closed.
struct CodexTranscriptAccountIdentity {
    private static let metadataRecordTypes: Set<String> = [
        "session_meta",
        "session_started",
        "session_start"
    ]

    private var hash: String?
    private var isAmbiguous = false

    var durableAccountHash: String? {
        isAmbiguous ? nil : hash
    }

    var hasConflictingDurableAccounts: Bool { isAmbiguous }

    mutating func consume(line: String) {
        // The accumulator below already decodes every record. Avoid doing a
        // second JSON decode for ordinary messages and token events; durable
        // account identity can only occur in one of these metadata records.
        guard line.contains("session_meta")
                || line.contains("session_started")
                || line.contains("session_start") else { return }
        guard line.contains("account_id") || line.contains("accountId") else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              Self.metadataRecordTypes.contains(type.lowercased()) else { return }

        var candidates = Set<String>()
        if let payload = object["payload"] as? [String: Any] {
            candidates.formUnion(Self.accountIDs(in: payload).compactMap(
                WeeklyQuotaCalibrationScope.hashAccount))
        }
        candidates.formUnion(Self.accountIDs(in: object).compactMap(
            WeeklyQuotaCalibrationScope.hashAccount))
        guard !candidates.isEmpty else { return }

        for next in candidates {
            if let hash, hash != next {
                isAmbiguous = true
            } else {
                hash = next
            }
        }
    }

    private static func accountIDs(in object: [String: Any]) -> [String] {
        ["account_id", "accountId"].compactMap { key in
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// On-demand telemetry for one session.
///
/// Telemetry is not stored on `Session`, not in SQLite, and NOT derived from
/// hydrated `SessionEvent`s: both transcript parsers truncate `rawJSON` (Claude at
/// 8 KB, Codex sanitizes lines over 100 KB), so `message.usage` on a large assistant
/// line is already gone by the time events exist. The file is therefore re-read.
///
/// Recompute is a FULL re-read, so callers must not poll this on a timer — a live
/// session's file signature changes on every append. It is built for "the user
/// selected this session and wants its numbers".
///
/// `@unchecked Sendable`: lock-guarded mutable cache, mirroring `RunwayPriceTable`.
final class SessionTelemetryEngine: @unchecked Sendable {
    static let shared = SessionTelemetryEngine()

    /// One selected transcript at a time in practice; sized generously so revisiting
    /// a handful of sessions stays instant.
    private static let cacheCapacity = 16

    private let lock = NSLock()
    private var cache: [TelemetryRequestKey: Entry] = [:]
    /// Least-recently-used last.
    private var order: [TelemetryRequestKey] = []
    /// One producer task per exact transcript/pricing revision. Subscribers await
    /// the same task; cancellation of one subscriber never cancels the producer.
    private var inFlight: [TelemetryRequestKey: InFlightEntry] = [:]
    private let priceTable: RunwayPriceTable
    private let quotaStore: WeeklyQuotaCalibrationStore
    private let now: @Sendable () -> Date
    private let metrics: SessionInfoMetrics
    /// Test seam for changing-file and changing-manifest regression tests. The
    /// production singleton leaves this nil.
    private let beforeTelemetryScan: (@Sendable () -> Void)?
    /// Test seam invoked after the first streamed record. The production
    /// singleton leaves this nil.
    private let afterFirstTelemetryLine: (@Sendable () -> Void)?
    /// Test seam invoked after a scan/cache lookup and immediately before
    /// publication. The production singleton leaves this nil.
    private let beforeTelemetryPublication: (@Sendable () -> Void)?

    /// Sources with a registry-owned telemetry provider. This remains a derived
    /// compatibility surface for tests and diagnostics; provider dispatch itself
    /// reads the factory from the selected source descriptor.
    static var dispatchableSources: Set<SessionSource> {
        Set(SessionSourceRegistry.ordered.compactMap { adapter in
            adapter.descriptor.hasTelemetryBackend ? adapter.descriptor.source : nil
        })
    }

    /// Counts full parses, so cache tests can prove a second call did no work.
    private var _parseCount = 0
    /// Lock-guarded: `compute` runs on a detached task, so an unsynchronized read
    /// from the test thread is a data race even though the value is only a counter.
    var parseCount: Int { lock.lock(); defer { lock.unlock() }; return _parseCount }

    init(priceTable: RunwayPriceTable = .shared,
         quotaStore: WeeklyQuotaCalibrationStore = .shared,
         now: @escaping @Sendable () -> Date = { Date() },
         metrics: SessionInfoMetrics = .shared,
         beforeTelemetryScan: (@Sendable () -> Void)? = nil,
         afterFirstTelemetryLine: (@Sendable () -> Void)? = nil,
         beforeTelemetryPublication: (@Sendable () -> Void)? = nil) {
        self.priceTable = priceTable
        self.quotaStore = quotaStore
        self.now = now
        self.metrics = metrics
        self.beforeTelemetryScan = beforeTelemetryScan
        self.afterFirstTelemetryLine = afterFirstTelemetryLine
        self.beforeTelemetryPublication = beforeTelemetryPublication
    }

    private struct Entry {
        let computed: ComputedTelemetry
    }

    private struct ComputedTelemetry: Sendable {
        let telemetry: SessionTelemetry
        let durableAccountHash: String?
        let pricing: TelemetryPricingIdentity
    }

    private struct TelemetryPricingIdentity: Hashable, Sendable {
        let revision: Int
        let updated: String
        let manifestFingerprint: String

        init(snapshot: RunwayPriceSnapshot) {
            revision = snapshot.revision
            updated = snapshot.updatedDate
            manifestFingerprint = snapshot.manifestFingerprint
        }
    }

    private struct TelemetryRequestKey: Hashable, Sendable {
        let source: SessionSource
        let path: String
        let sessionID: String
        let revision: SessionTelemetryRevision
        let parserVersion: Int
        let pricing: TelemetryPricingIdentity
    }

    private struct TelemetryWorkSelection {
        let cached: ComputedTelemetry?
        let worker: Task<TelemetryScanResult, Never>?
        let workerID: UUID?
        let joinedInFlight: Bool
    }

    private struct InFlightEntry {
        let id: UUID
        let task: Task<TelemetryScanResult, Never>
        var waiters: Int
    }

    /// A subscriber owns one lease on a shared producer. The lease is
    /// idempotent because Swift cancellation handlers and the normal result
    /// path can race. When the final lease leaves, the producer is cancelled
    /// and removed so a rapid selection change cannot leave an orphaned scan
    /// competing with the newly selected session.
    private final class TelemetryWaiterLease: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private let releaseAction: @Sendable () -> Void

        init(releaseAction: @escaping @Sendable () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            lock.unlock()
            releaseAction()
        }
    }

    private struct TelemetryStreamResult: Sendable {
        let completed: Bool
        let bytesRead: UInt64
    }

    private struct TelemetryScanResult: Sendable {
        let computed: ComputedTelemetry?
        let bytesScanned: UInt64
        let revisionChanged: Bool
    }

    private final class TelemetryResultRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<TelemetryScanResult?, Never>?
        private var hasResult = false
        private var result: TelemetryScanResult?

        func wait() async -> TelemetryScanResult? {
            await withCheckedContinuation { continuation in
                lock.lock()
                if hasResult {
                    let result = self.result
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func resolve(_ result: TelemetryScanResult?) {
            lock.lock()
            guard !hasResult else {
                lock.unlock()
                return
            }
            hasResult = true
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    /// nil when the source cannot produce telemetry, or the file is unreadable.
    func telemetry(for session: Session) async -> SessionTelemetry? {
        await telemetry(for: session, revisionRetryCount: 0)
    }

    private func telemetry(for session: Session, revisionRetryCount: Int) async -> SessionTelemetry? {
        guard !Task.isCancelled else { return nil }
        let descriptor = SessionSourceRegistry.descriptor(for: session.source)
        let capabilities = descriptor.telemetry
        // Capability- and registry-gated: adding a provider is a descriptor edit
        // plus an accumulator, with no engine switch or provider list to update.
        guard capabilities.configuration.isAvailable || capabilities.tokens.isAvailable else { return nil }
        guard descriptor.hasTelemetryBackend(for: session) else { return nil }

        let path = session.filePath
        guard !path.isEmpty else { return nil }

        // Shared-storage backends provide a logical, session-scoped revision;
        // file-backed sources use the physical signature. A missing revision
        // means the source cannot be proven current, so fail closed.
        guard let expectedRevision = resolveTelemetryRevision(
            for: session,
            telemetryRevision: descriptor.telemetryRevision) else { return nil }

        let pricingSnapshot = priceTable.snapshot()
        let pricing = TelemetryPricingIdentity(snapshot: pricingSnapshot)
        let key = TelemetryRequestKey(
            source: session.source,
            path: path,
            sessionID: session.id,
            revision: expectedRevision,
            parserVersion: SessionTelemetry.parserVersion,
            pricing: pricing)

        let selection = selectWork(
            key: key,
            session: session,
            expectedRevision: expectedRevision,
            capabilities: capabilities,
            makeTelemetryProvider: descriptor.makeTelemetryProvider,
            scanTelemetry: descriptor.scanTelemetry,
            telemetryRevision: descriptor.telemetryRevision,
            pricingSnapshot: pricingSnapshot)

        if let cached = selection.cached {
            guard !Task.isCancelled else { return nil }
            guard isCurrentTelemetryRevision(
                for: session,
                expectedRevision: expectedRevision,
                telemetryRevision: descriptor.telemetryRevision) else {
                guard revisionRetryCount < 1 else { return nil }
                return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
            }
            let result = applyingWeeklyQuota(to: cached.telemetry,
                                             source: session.source,
                                             capabilities: capabilities,
                                             durableAccountHash: cached.durableAccountHash,
                                             pricing: cached.pricing,
                                             now: now())
            beforeTelemetryPublication?()
            guard isCurrentTelemetryRevision(
                for: session,
                expectedRevision: expectedRevision,
                telemetryRevision: descriptor.telemetryRevision) else {
                guard revisionRetryCount < 1 else { return nil }
                return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
            }
            guard !Task.isCancelled else { return nil }
            metrics.recordCacheHit()
            return result
        }

        if selection.joinedInFlight {
            metrics.recordInFlightJoin()
        }
        guard let worker = selection.worker,
              let workerID = selection.workerID else { return nil }
        // This is a shared producer. Do not cancel it when this subscriber is
        // cancelled while another visible Session Info consumer may still need
        // it. The final subscriber does cancel it, so rapid navigation does not
        // accumulate unowned full-file scans.
        guard let scan = await awaitSharedScan(worker, key: key, workerID: workerID) else { return nil }

        guard !Task.isCancelled else { return nil }
        guard let computed = scan.computed else {
            guard scan.revisionChanged, revisionRetryCount < 1 else { return nil }
            return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
        }
        guard isCurrentTelemetryRevision(
            for: session,
            expectedRevision: expectedRevision,
            telemetryRevision: descriptor.telemetryRevision) else {
            guard revisionRetryCount < 1 else { return nil }
            return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
        }
        guard !Task.isCancelled else { return nil }
        let result = applyingWeeklyQuota(to: computed.telemetry,
                                         source: session.source,
                                         capabilities: capabilities,
                                         durableAccountHash: computed.durableAccountHash,
                                         pricing: computed.pricing,
                                         now: now())
        beforeTelemetryPublication?()
        guard isCurrentTelemetryRevision(
            for: session,
            expectedRevision: expectedRevision,
            telemetryRevision: descriptor.telemetryRevision) else {
            guard revisionRetryCount < 1 else { return nil }
            return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
        }
        guard !Task.isCancelled else { return nil }
        return result
    }

    private func resolveTelemetryRevision(
        for session: Session,
        telemetryRevision: (@Sendable (Session) -> SessionTelemetryRevision?)?)
        -> SessionTelemetryRevision? {
        if let telemetryRevision {
            return telemetryRevision(session)
        }
        guard let signature = RunwayFileSignature.read(path: session.filePath) else { return nil }
        return .file(signature)
    }

    private func isCurrentTelemetryRevision(
        for session: Session,
        expectedRevision: SessionTelemetryRevision,
        telemetryRevision: (@Sendable (Session) -> SessionTelemetryRevision?)?) -> Bool {
        resolveTelemetryRevision(for: session, telemetryRevision: telemetryRevision) == expectedRevision
    }

    /// Waits for a shared producer without allowing subscriber cancellation to
    /// cancel that producer. The small cancellation waiter lets a replaced
    /// Session Info selection return promptly while another subscriber can keep
    /// the producer alive.
    private func awaitSharedScan(_ worker: Task<TelemetryScanResult, Never>,
                                 key: TelemetryRequestKey,
                                 workerID: UUID) async -> TelemetryScanResult? {
        let relay = TelemetryResultRelay()
        let lease = TelemetryWaiterLease { [weak self] in
            self?.releaseSubscriber(for: key, workerID: workerID)
        }
        guard !Task.isCancelled else {
            lease.release()
            return nil
        }
        // This observer is intentionally unstructured. A cancelled subscriber
        // must not remain attached to `worker.value`, and cancelling this
        // observer does not cancel the producer while another lease remains.
        _ = Task.detached(priority: .utility) {
            relay.resolve(await worker.value)
        }
        return await withTaskCancellationHandler(operation: {
            defer { lease.release() }
            guard !Task.isCancelled else {
                relay.resolve(nil)
                return nil
            }
            return await relay.wait()
        }, onCancel: {
            lease.release()
            relay.resolve(nil)
        })
    }

    /// Selects a cached result, an existing producer, or a new shared producer.
    /// This helper stays synchronous so all lock operations remain outside the
    /// async caller's isolation context.
    private func selectWork(
        key: TelemetryRequestKey,
        session: Session,
        expectedRevision: SessionTelemetryRevision,
        capabilities: TelemetryCapabilities,
        makeTelemetryProvider: (@Sendable () -> any SessionTelemetryProvider)?,
        scanTelemetry: (@Sendable (Session) -> SessionTelemetryProviderScan?)?,
        telemetryRevision: (@Sendable (Session) -> SessionTelemetryRevision?)?,
        pricingSnapshot: RunwayPriceSnapshot
    ) -> TelemetryWorkSelection {
        lock.lock()
        if let cached = cachedTelemetryLocked(for: key) {
            lock.unlock()
            return TelemetryWorkSelection(cached: cached, worker: nil, workerID: nil, joinedInFlight: false)
        }
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            lock.unlock()
            return TelemetryWorkSelection(cached: nil, worker: existing.task, workerID: existing.id, joinedInFlight: true)
        }

        let metrics = self.metrics
        let beforeTelemetryScan = self.beforeTelemetryScan
        let afterFirstTelemetryLine = self.afterFirstTelemetryLine
        let workerID = UUID()
        let newWorker: Task<TelemetryScanResult, Never> = Task.detached(priority: .utility) { [weak self] in
            let startedAt = Date()
            let metricIdentity = scanTelemetry == nil
                ? nil
                : SessionInfoMetricsIdentity(source: session.source, sessionID: session.id)
            if let metricIdentity {
                metrics.beginTelemetry(identity: metricIdentity)
            } else {
                metrics.beginTelemetry(path: session.filePath)
            }
            var result = TelemetryScanResult(computed: nil, bytesScanned: 0, revisionChanged: false)
            defer {
                if let metricIdentity {
                    metrics.endTelemetry(identity: metricIdentity)
                } else {
                    metrics.endTelemetry(path: session.filePath)
                }
                metrics.recordTelemetryFinished(
                    duration: Date().timeIntervalSince(startedAt),
                    bytesScanned: result.bytesScanned)
                self?.finishInFlight(for: key, workerID: workerID)
            }
            guard let self = self else { return result }
            beforeTelemetryScan?()
            result = self.compute(
                session: session,
                expectedRevision: expectedRevision,
                capabilities: capabilities,
                makeTelemetryProvider: makeTelemetryProvider,
                scanTelemetry: scanTelemetry,
                telemetryRevision: telemetryRevision,
                priceSnapshot: pricingSnapshot,
                afterFirstTelemetryLine: afterFirstTelemetryLine)
            if let computed = result.computed {
                // A final-subscriber cancellation can race with the last
                // cancellation checkpoint inside compute(). Store only while
                // this worker still owns an active lease, so an orphaned
                // producer cannot publish into the cache after cancellation.
                _ = self.store(computed, for: key, workerID: workerID)
            }
            return result
        }
        inFlight[key] = InFlightEntry(id: workerID, task: newWorker, waiters: 1)
        lock.unlock()
        return TelemetryWorkSelection(cached: nil, worker: newWorker, workerID: workerID, joinedInFlight: false)
    }

    // MARK: - Computation

    private func compute(
        session: Session,
        expectedRevision: SessionTelemetryRevision,
        capabilities: TelemetryCapabilities,
        makeTelemetryProvider: (@Sendable () -> any SessionTelemetryProvider)?,
        scanTelemetry: (@Sendable (Session) -> SessionTelemetryProviderScan?)?,
        telemetryRevision: (@Sendable (Session) -> SessionTelemetryRevision?)?,
        priceSnapshot: RunwayPriceSnapshot,
        afterFirstTelemetryLine: (@Sendable () -> Void)?) -> TelemetryScanResult {
        guard !Task.isCancelled else {
            return TelemetryScanResult(computed: nil, bytesScanned: 0, revisionChanged: false)
        }
        let parsed: SessionTelemetryProviderResult
        let bytesScanned: UInt64
        let revisionChanged: Bool

        if let scanTelemetry, let scanned = scanTelemetry(session) {
            bytesScanned = scanned.bytesScanned
            guard !Task.isCancelled else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: false)
            }
            guard !scanned.revisionChanged else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: true)
            }
            guard let telemetryRevision else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: false)
            }
            let currentRevision = scanned.inputRevision ?? telemetryRevision(session)
            guard let currentRevision else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: false)
            }
            revisionChanged = currentRevision != expectedRevision
            guard !revisionChanged, !Task.isCancelled else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: revisionChanged)
            }
            parsed = scanned.result
        } else {
            guard case let .file(expectedSignature) = expectedRevision,
                  let makeTelemetryProvider else {
                return TelemetryScanResult(computed: nil, bytesScanned: 0, revisionChanged: false)
            }
            let url = URL(fileURLWithPath: session.filePath)
            // Streamed, never materialized: the largest local Codex rollout is 256 MB.
            var provider = makeTelemetryProvider()
            let streamed = streamLines(at: url,
                                       maximumBytes: expectedSignature.size,
                                       afterFirstLine: afterFirstTelemetryLine,
                                       into: {
                provider.consume(line: $0, index: $1)
            })
            bytesScanned = streamed.bytesRead
            revisionChanged = RunwayFileSignature.read(path: session.filePath) != expectedSignature
            guard streamed.completed, !revisionChanged, !Task.isCancelled else {
                return TelemetryScanResult(computed: nil,
                                           bytesScanned: bytesScanned,
                                           revisionChanged: revisionChanged)
            }
            parsed = provider.finish()
        }

        guard !Task.isCancelled else {
            return TelemetryScanResult(computed: nil,
                                       bytesScanned: bytesScanned,
                                       revisionChanged: false)
        }
        guard let finalRevision = resolveTelemetryRevision(
            for: session,
            telemetryRevision: telemetryRevision),
              finalRevision == expectedRevision else {
            return TelemetryScanResult(computed: nil,
                                       bytesScanned: bytesScanned,
                                       revisionChanged: true)
        }
        let base = parsed.telemetry
        let durableAccountHash = parsed.durableAccountHash
        lock.lock(); _parseCount += 1; lock.unlock()

        // Pricing needs both permission and component tokens: a legacy total-only
        // transcript reports a token count but can never be priced.
        guard capabilities.cost.isAvailable,
              base.usageSummary?.unavailableReason == nil,
              base.usageSummary?.hasComponentBreakdown == true else {
            return TelemetryScanResult(
                computed: ComputedTelemetry(
                    telemetry: base,
                    durableAccountHash: durableAccountHash,
                    pricing: TelemetryPricingIdentity(snapshot: priceSnapshot)),
                bytesScanned: bytesScanned,
                revisionChanged: false)
        }
        let priced = TelemetryCostCalculator.price(events: base.usageEvents,
                                                   fallbackSlices: base.usageSlices,
                                                   snapshot: priceSnapshot)
        return TelemetryScanResult(
            computed: ComputedTelemetry(
                telemetry: SessionTelemetry(source: base.source,
                                            initialConfiguration: base.initialConfiguration,
                                            currentConfiguration: base.currentConfiguration,
                                            configurationChanges: base.configurationChanges,
                                            usageSlices: base.usageSlices,
                                            usageEvents: priced.events,
                                            usageSummary: base.usageSummary,
                                            costEstimate: priced.estimate,
                                            weeklyQuotaEstimate: nil,
                                            parserVersion: base.parserVersion),
                durableAccountHash: durableAccountHash,
                pricing: TelemetryPricingIdentity(snapshot: priceSnapshot)),
            bytesScanned: bytesScanned,
            revisionChanged: false)
    }

    /// Weekly attribution depends on live account calibration, not transcript
    /// bytes. Apply it after the transcript cache so a new quota observation can
    /// update the estimate without forcing a full re-parse of a large session.
    private func applyingWeeklyQuota(to telemetry: SessionTelemetry,
                                     source: SessionSource,
                                     capabilities: TelemetryCapabilities,
                                     durableAccountHash: String?,
                                     pricing: TelemetryPricingIdentity,
                                     now: Date) -> SessionTelemetry {
        let weekly = weeklyQuotaEstimate(source: source,
                                         capabilities: capabilities,
                                         cost: telemetry.costEstimate,
                                         durableAccountHash: durableAccountHash,
                                         quotaStore: quotaStore,
                                         pricing: pricing,
                                         now: now)
        return SessionTelemetry(source: telemetry.source,
                                initialConfiguration: telemetry.initialConfiguration,
                                currentConfiguration: telemetry.currentConfiguration,
                                configurationChanges: telemetry.configurationChanges,
                                usageSlices: telemetry.usageSlices,
                                usageEvents: telemetry.usageEvents,
                                usageSummary: telemetry.usageSummary,
                                costEstimate: telemetry.costEstimate,
                                weeklyQuotaEstimate: weekly,
                                parserVersion: telemetry.parserVersion)
    }

    private func weeklyQuotaEstimate(source: SessionSource,
                                     capabilities: TelemetryCapabilities,
                                     cost: TelemetryCostEstimate?,
                                     durableAccountHash: String?,
                                     quotaStore: WeeklyQuotaCalibrationStore,
                                     pricing: TelemetryPricingIdentity,
                                     now: Date) -> TelemetryWeeklyQuotaEstimate? {
        guard capabilities.weeklyQuota.isAvailable else { return nil }
        guard let cost else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "session has no priceable component breakdown",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
                calibrationProvenance: nil,
                calculatedAt: now, priceTableRevision: pricing.revision)
        }
        guard let dollars = cost.apiEquivalentUSD else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "session has unpriced usage",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
                calibrationProvenance: nil,
                calculatedAt: now, priceTableRevision: cost.priceTableRevision)
        }
        guard let context = quotaStore.attributionContext(provider: source.rawValue, now: now),
              context.scope.priceRevision == cost.priceTableRevision else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "no compatible account-window calibration",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
                calibrationProvenance: nil,
                calculatedAt: now, priceTableRevision: cost.priceTableRevision)
        }
        guard context.scope.accountHash != nil else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "provider does not expose a stable account identity",
                percentPointsPerAPIDollar: context.percentPointsPerDollar,
                accountScoped: false,
                sourceFamily: context.scope.sourceFamily,
                quotaResetAt: context.latestSnapshot?.resetAt,
                quotaObservedAt: context.latestSnapshot?.observedAt,
                quotaPrecision: context.latestSnapshot?.precision.rawValue,
                calibrationProvenance: context.calibrationProvenance,
                calculatedAt: now, priceTableRevision: cost.priceTableRevision)
        }
        guard durableAccountHash == context.scope.accountHash else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "session has no durable account identity matching the calibration account",
                percentPointsPerAPIDollar: context.percentPointsPerDollar,
                accountScoped: false,
                sourceFamily: context.scope.sourceFamily,
                quotaResetAt: context.latestSnapshot?.resetAt,
                quotaObservedAt: context.latestSnapshot?.observedAt,
                quotaPrecision: context.latestSnapshot?.precision.rawValue,
                calibrationProvenance: context.calibrationProvenance,
                calculatedAt: now, priceTableRevision: cost.priceTableRevision)
        }
        return TelemetryWeeklyQuotaEstimate(
            status: .estimated,
            percentPoints: dollars * context.percentPointsPerDollar,
            unavailableReason: nil,
            percentPointsPerAPIDollar: context.percentPointsPerDollar,
            accountScoped: true,
            sourceFamily: context.scope.sourceFamily,
            quotaResetAt: context.latestSnapshot?.resetAt,
            quotaObservedAt: context.latestSnapshot?.observedAt,
            quotaPrecision: context.latestSnapshot?.precision.rawValue,
            calibrationProvenance: context.calibrationProvenance,
            calculatedAt: now,
            priceTableRevision: cost.priceTableRevision)
    }

    /// Feeds the shared JSONL reader's emitted records, numbering them as it goes.
    /// That numbering is what `anchorLine` refers to — the reader drops blank lines,
    /// so it is a record index, not a raw file line.
    private func streamLines(at url: URL,
                             maximumBytes: UInt64,
                             afterFirstLine: (@Sendable () -> Void)?,
                             into consume: (String, Int) -> Void) -> TelemetryStreamResult {
        var index = 0
        var bytesRead: UInt64 = 0
        var didInvokeAfterFirstLine = false
        do {
            let completed = try JSONLReader(url: url,
                                            maximumBytes: maximumBytes,
                                            propagatesReadErrors: true).forEachLineWhile({ line in
                guard !Task.isCancelled else { return false }
                consume(line, index)
                index += 1
                if !didInvokeAfterFirstLine {
                    didInvokeAfterFirstLine = true
                    afterFirstLine?()
                }
                return true
            }, reportBytesRead: { bytesRead = $0 })
            return TelemetryStreamResult(completed: completed && !Task.isCancelled,
                                         bytesRead: bytesRead)
        } catch {
            return TelemetryStreamResult(completed: false, bytesRead: bytesRead)
        }
    }

    // MARK: - Cache

    private func cachedTelemetryLocked(for key: TelemetryRequestKey) -> ComputedTelemetry? {
        guard let entry = cache[key] else { return nil }
        touch(key)
        return entry.computed
    }

    @discardableResult
    private func store(_ computed: ComputedTelemetry,
                       for key: TelemetryRequestKey,
                       workerID: UUID) -> Bool {
        lock.lock()
        guard let inFlightEntry = inFlight[key],
              inFlightEntry.id == workerID,
              inFlightEntry.waiters > 0 else {
            lock.unlock()
            return false
        }
        let replacedExisting = cache[key] != nil
        cache[key] = Entry(computed: computed)
        touch(key)
        while order.count > Self.cacheCapacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        if replacedExisting {
            metrics.recordDuplicateParse()
        }
        return true
    }

    /// Caller holds `lock`.
    private func touch(_ key: TelemetryRequestKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func releaseSubscriber(for key: TelemetryRequestKey, workerID: UUID) {
        var taskToCancel: Task<TelemetryScanResult, Never>?
        lock.lock()
        if var entry = inFlight[key], entry.id == workerID {
            entry.waiters -= 1
            if entry.waiters <= 0 {
                inFlight.removeValue(forKey: key)
                taskToCancel = entry.task
            } else {
                inFlight[key] = entry
            }
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    private func finishInFlight(for key: TelemetryRequestKey, workerID: UUID) {
        lock.lock()
        if inFlight[key]?.id == workerID {
            inFlight.removeValue(forKey: key)
        }
        lock.unlock()
    }
}
