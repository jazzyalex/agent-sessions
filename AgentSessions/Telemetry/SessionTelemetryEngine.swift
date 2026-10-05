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
    private var inFlight: [TelemetryRequestKey: Task<TelemetryScanResult, Never>] = [:]
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

    /// Sources with a registry-owned telemetry provider. This remains a derived
    /// compatibility surface for tests and diagnostics; provider dispatch itself
    /// reads the factory from the selected source descriptor.
    static var dispatchableSources: Set<SessionSource> {
        Set(SessionSourceRegistry.ordered.compactMap { adapter in
            adapter.descriptor.makeTelemetryProvider == nil ? nil : adapter.descriptor.source
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
         afterFirstTelemetryLine: (@Sendable () -> Void)? = nil) {
        self.priceTable = priceTable
        self.quotaStore = quotaStore
        self.now = now
        self.metrics = metrics
        self.beforeTelemetryScan = beforeTelemetryScan
        self.afterFirstTelemetryLine = afterFirstTelemetryLine
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
        let fileRevision: RunwayFileSignature
        let parserVersion: Int
        let pricing: TelemetryPricingIdentity
    }

    private struct TelemetryWorkSelection {
        let cached: ComputedTelemetry?
        let worker: Task<TelemetryScanResult, Never>?
        let joinedInFlight: Bool
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
        let descriptor = SessionSourceRegistry.descriptor(for: session.source)
        let capabilities = descriptor.telemetry
        // Capability- and registry-gated: adding a provider is a descriptor edit
        // plus an accumulator, with no engine switch or provider list to update.
        guard capabilities.configuration.isAvailable || capabilities.tokens.isAvailable else { return nil }
        guard let makeTelemetryProvider = descriptor.makeTelemetryProvider else { return nil }

        let path = session.filePath
        guard !path.isEmpty else { return nil }

        // A nil signature means the file is missing or unstat-able. Bypass the cache
        // entirely rather than risk serving a stale result for a file we cannot check.
        guard let signature = RunwayFileSignature.read(path: path) else { return nil }

        let pricingSnapshot = priceTable.snapshot()
        let pricing = TelemetryPricingIdentity(snapshot: pricingSnapshot)
        let key = TelemetryRequestKey(
            source: session.source,
            path: path,
            fileRevision: signature,
            parserVersion: SessionTelemetry.parserVersion,
            pricing: pricing)

        let selection = selectWork(
            key: key,
            path: path,
            signature: signature,
            capabilities: capabilities,
            makeTelemetryProvider: makeTelemetryProvider,
            pricingSnapshot: pricingSnapshot)

        if let cached = selection.cached {
            metrics.recordCacheHit()
            return applyingWeeklyQuota(to: cached.telemetry,
                                       source: session.source,
                                       capabilities: capabilities,
                                       durableAccountHash: cached.durableAccountHash,
                                       pricing: cached.pricing,
                                       now: now())
        }

        if selection.joinedInFlight {
            metrics.recordInFlightJoin()
        }
        guard let worker = selection.worker else { return nil }
        // This is a shared producer. Do not cancel it when this subscriber is
        // cancelled; another visible Session Info consumer may still need it.
        guard let scan = await awaitSharedScan(worker) else { return nil }

        guard !Task.isCancelled else { return nil }
        guard let computed = scan.computed else {
            guard scan.revisionChanged, revisionRetryCount < 1 else { return nil }
            return await telemetry(for: session, revisionRetryCount: revisionRetryCount + 1)
        }
        return applyingWeeklyQuota(to: computed.telemetry,
                                   source: session.source,
                                   capabilities: capabilities,
                                   durableAccountHash: computed.durableAccountHash,
                                   pricing: computed.pricing,
                                   now: now())
    }

    /// Waits for a shared producer without allowing subscriber cancellation to
    /// cancel that producer. The small cancellation waiter lets a replaced
    /// Session Info selection return promptly while another subscriber can keep
    /// the producer alive.
    private func awaitSharedScan(_ worker: Task<TelemetryScanResult, Never>) async -> TelemetryScanResult? {
        guard !Task.isCancelled else { return nil }
        let relay = TelemetryResultRelay()
        // This observer is intentionally unstructured. A cancelled subscriber
        // must not remain attached to `worker.value`, and cancelling this
        // observer would not cancel the shared producer either.
        _ = Task.detached(priority: .utility) {
            relay.resolve(await worker.value)
        }
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else {
                relay.resolve(nil)
                return nil
            }
            return await relay.wait()
        }, onCancel: {
            relay.resolve(nil)
        })
    }

    /// Selects a cached result, an existing producer, or a new shared producer.
    /// This helper stays synchronous so all lock operations remain outside the
    /// async caller's isolation context.
    private func selectWork(
        key: TelemetryRequestKey,
        path: String,
        signature: RunwayFileSignature,
        capabilities: TelemetryCapabilities,
        makeTelemetryProvider: @escaping @Sendable () -> any SessionTelemetryProvider,
        pricingSnapshot: RunwayPriceSnapshot
    ) -> TelemetryWorkSelection {
        lock.lock()
        if let cached = cachedTelemetryLocked(for: key) {
            lock.unlock()
            return TelemetryWorkSelection(cached: cached, worker: nil, joinedInFlight: false)
        }
        if let existing = inFlight[key] {
            lock.unlock()
            return TelemetryWorkSelection(cached: nil, worker: existing, joinedInFlight: true)
        }

        let metrics = self.metrics
        let beforeTelemetryScan = self.beforeTelemetryScan
        let afterFirstTelemetryLine = self.afterFirstTelemetryLine
        let newWorker: Task<TelemetryScanResult, Never> = Task.detached(priority: .utility) { [weak self] in
            let startedAt = Date()
            metrics.beginTelemetry(path: path)
            var result = TelemetryScanResult(computed: nil, bytesScanned: 0, revisionChanged: false)
            defer {
                metrics.endTelemetry(path: path)
                metrics.recordTelemetryFinished(
                    duration: Date().timeIntervalSince(startedAt),
                    bytesScanned: result.bytesScanned)
                self?.finishInFlight(for: key)
            }
            guard let self = self else { return result }
            beforeTelemetryScan?()
            result = self.compute(
                path: path,
                expectedSignature: signature,
                capabilities: capabilities,
                makeTelemetryProvider: makeTelemetryProvider,
                priceSnapshot: pricingSnapshot,
                afterFirstTelemetryLine: afterFirstTelemetryLine)
            if let computed = result.computed {
                self.store(computed, for: key)
            }
            return result
        }
        inFlight[key] = newWorker
        lock.unlock()
        return TelemetryWorkSelection(cached: nil, worker: newWorker, joinedInFlight: false)
    }

    // MARK: - Computation

    private func compute(path: String,
                         expectedSignature: RunwayFileSignature,
                         capabilities: TelemetryCapabilities,
                         makeTelemetryProvider: @Sendable () -> any SessionTelemetryProvider,
                         priceSnapshot: RunwayPriceSnapshot,
                         afterFirstTelemetryLine: (@Sendable () -> Void)?) -> TelemetryScanResult {
        guard !Task.isCancelled else {
            return TelemetryScanResult(computed: nil, bytesScanned: 0, revisionChanged: false)
        }
        let url = URL(fileURLWithPath: path)
        // Streamed, never materialized: the largest local Codex rollout is 256 MB.
        var provider = makeTelemetryProvider()
        let streamed = streamLines(at: url,
                                   maximumBytes: expectedSignature.size,
                                   afterFirstLine: afterFirstTelemetryLine,
                                   into: {
            provider.consume(line: $0, index: $1)
        })
        let revisionChanged = RunwayFileSignature.read(path: path) != expectedSignature
        guard streamed.completed, !revisionChanged, !Task.isCancelled else {
            return TelemetryScanResult(computed: nil,
                                       bytesScanned: streamed.bytesRead,
                                       revisionChanged: revisionChanged)
        }

        let parsed = provider.finish()
        let base = parsed.telemetry
        let durableAccountHash = parsed.durableAccountHash
        lock.lock(); _parseCount += 1; lock.unlock()

        // Pricing needs both permission and component tokens: a legacy total-only
        // transcript reports a token count but can never be priced.
        guard capabilities.cost.isAvailable, base.usageSummary?.hasComponentBreakdown == true else {
            return TelemetryScanResult(
                computed: ComputedTelemetry(
                    telemetry: base,
                    durableAccountHash: durableAccountHash,
                    pricing: TelemetryPricingIdentity(snapshot: priceSnapshot)),
                bytesScanned: streamed.bytesRead,
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
            bytesScanned: streamed.bytesRead,
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

    private func store(_ computed: ComputedTelemetry, for key: TelemetryRequestKey) {
        lock.lock()
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
    }

    /// Caller holds `lock`.
    private func touch(_ key: TelemetryRequestKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func finishInFlight(for key: TelemetryRequestKey) {
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
    }
}
