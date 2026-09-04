import Foundation

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
    private var cache: [String: Entry] = [:]
    /// Least-recently-used last.
    private var order: [String] = []
    private let priceTable: RunwayPriceTable
    private let quotaStore: WeeklyQuotaCalibrationStore
    private let now: @Sendable () -> Date

    /// The sources `compute` can actually dispatch. A source whose descriptor
    /// declares telemetry available but is missing here returns nil forever, and
    /// silently — the `default` arm cannot tell that case from a source that
    /// correctly declares nothing. `SessionTelemetryEngineTests` asserts this set
    /// matches the descriptors, so adding a provider cannot half-land.
    static let dispatchableSources: Set<SessionSource> = [.codex, .claude, .pi, .copilot]

    /// Counts full parses, so cache tests can prove a second call did no work.
    private var _parseCount = 0
    /// Lock-guarded: `compute` runs on a detached task, so an unsynchronized read
    /// from the test thread is a data race even though the value is only a counter.
    var parseCount: Int { lock.lock(); defer { lock.unlock() }; return _parseCount }

    init(priceTable: RunwayPriceTable = .shared,
         quotaStore: WeeklyQuotaCalibrationStore = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.priceTable = priceTable
        self.quotaStore = quotaStore
        self.now = now
    }

    private struct Entry {
        let signature: RunwayFileSignature
        let parserVersion: Int
        let priceTableRevision: Int
        let telemetry: SessionTelemetry
    }

    /// nil when the source cannot produce telemetry, or the file is unreadable.
    func telemetry(for session: Session) async -> SessionTelemetry? {
        let capabilities = SessionSourceRegistry.descriptor(for: session.source).telemetry
        // Capability-gated rather than a hardcoded provider list: adding a provider
        // later is a descriptor edit plus an accumulator, with no change here.
        guard capabilities.configuration.isAvailable || capabilities.tokens.isAvailable else { return nil }

        let path = session.filePath
        guard !path.isEmpty else { return nil }

        // A nil signature means the file is missing or unstat-able. Bypass the cache
        // entirely rather than risk serving a stale result for a file we cannot check.
        guard let signature = RunwayFileSignature.read(path: path) else { return nil }
        if let cached = cachedTelemetry(path: path, signature: signature,
                                        priceTableRevision: priceTable.revision) {
            return applyingWeeklyQuota(to: cached, source: session.source,
                                       capabilities: capabilities, now: now())
        }

        let source = session.source
        let priceTable = self.priceTable
        let computed = await Task.detached(priority: .utility) { [weak self] in
            self?.compute(path: path, source: source, capabilities: capabilities,
                          priceTable: priceTable)
        }.value

        guard let computed else { return nil }
        store(computed, path: path, signature: signature)
        return applyingWeeklyQuota(to: computed, source: source,
                                   capabilities: capabilities, now: now())
    }

    // MARK: - Computation

    private func compute(path: String,
                         source: SessionSource,
                         capabilities: TelemetryCapabilities,
                         priceTable: RunwayPriceTable) -> SessionTelemetry? {
        let url = URL(fileURLWithPath: path)
        var telemetry: SessionTelemetry?

        // Streamed, never materialized: the largest local Codex rollout is 256 MB.
        switch source {
        case .codex:
            var accumulator = CodexTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .claude:
            var accumulator = ClaudeTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .pi:
            var accumulator = PiTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        case .copilot:
            var accumulator = CopilotTelemetryAccumulator()
            guard streamLines(at: url, into: { accumulator.consume(line: $0, index: $1) }) else { return nil }
            telemetry = accumulator.finish()
        default:
            return nil
        }

        guard let base = telemetry else { return nil }
        lock.lock(); _parseCount += 1; lock.unlock()

        // Pricing needs both permission and component tokens: a legacy total-only
        // transcript reports a token count but can never be priced.
        guard capabilities.cost.isAvailable, base.usageSummary?.hasComponentBreakdown == true else {
            return base
        }
        let priced = TelemetryCostCalculator.price(events: base.usageEvents,
                                                   fallbackSlices: base.usageSlices,
                                                   priceTable: priceTable)
        return SessionTelemetry(source: base.source,
                                initialConfiguration: base.initialConfiguration,
                                currentConfiguration: base.currentConfiguration,
                                configurationChanges: base.configurationChanges,
                                usageSlices: base.usageSlices,
                                usageEvents: priced.events,
                                usageSummary: base.usageSummary,
                                costEstimate: priced.estimate,
                                weeklyQuotaEstimate: nil,
                                parserVersion: base.parserVersion)
    }

    /// Weekly attribution depends on live account calibration, not transcript
    /// bytes. Apply it after the transcript cache so a new quota observation can
    /// update the estimate without forcing a full re-parse of a large session.
    private func applyingWeeklyQuota(to telemetry: SessionTelemetry,
                                     source: SessionSource,
                                     capabilities: TelemetryCapabilities,
                                     now: Date) -> SessionTelemetry {
        let weekly = weeklyQuotaEstimate(source: source,
                                         capabilities: capabilities,
                                         cost: telemetry.costEstimate,
                                         quotaStore: quotaStore,
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
                                     quotaStore: WeeklyQuotaCalibrationStore,
                                     now: Date) -> TelemetryWeeklyQuotaEstimate? {
        guard capabilities.weeklyQuota.isAvailable else { return nil }
        guard let cost else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "session has no priceable component breakdown",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
                calculatedAt: now, priceTableRevision: priceTable.revision)
        }
        guard let dollars = cost.apiEquivalentUSD else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "session has unpriced usage",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
                calculatedAt: now, priceTableRevision: cost.priceTableRevision)
        }
        guard let context = quotaStore.attributionContext(provider: source.rawValue, now: now),
              context.scope.priceRevision == cost.priceTableRevision else {
            return TelemetryWeeklyQuotaEstimate(
                status: .unavailable, percentPoints: nil,
                unavailableReason: "no compatible account-window calibration",
                percentPointsPerAPIDollar: nil, accountScoped: false,
                sourceFamily: nil, quotaResetAt: nil, quotaObservedAt: nil, quotaPrecision: nil,
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
            calculatedAt: now,
            priceTableRevision: cost.priceTableRevision)
    }

    /// Feeds the shared JSONL reader's emitted records, numbering them as it goes.
    /// That numbering is what `anchorLine` refers to — the reader drops blank lines,
    /// so it is a record index, not a raw file line.
    private func streamLines(at url: URL, into consume: (String, Int) -> Void) -> Bool {
        var index = 0
        do {
            try JSONLReader(url: url).forEachLine { line in
                consume(line, index)
                index += 1
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Cache

    private func cachedTelemetry(path: String,
                                 signature: RunwayFileSignature,
                                 priceTableRevision: Int) -> SessionTelemetry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = cache[path],
              entry.signature == signature,
              entry.parserVersion == SessionTelemetry.parserVersion,
              entry.priceTableRevision == priceTableRevision else { return nil }
        touch(path)
        return entry.telemetry
    }

    private func store(_ telemetry: SessionTelemetry, path: String, signature: RunwayFileSignature) {
        lock.lock(); defer { lock.unlock() }
        cache[path] = Entry(signature: signature,
                            parserVersion: SessionTelemetry.parserVersion,
                            priceTableRevision: telemetry.costEstimate?.priceTableRevision ?? priceTable.revision,
                            telemetry: telemetry)
        touch(path)
        while order.count > Self.cacheCapacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    /// Caller holds `lock`.
    private func touch(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }
}
