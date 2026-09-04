import Foundation
import CryptoKit

// MARK: - Weekly quota calibration
//
// `Wk` answers "what share of my weekly quota is this session burning per hour?".
// Provider quota percentages are account-wide and coarse; local token activity is
// per-session and fine. Neither alone yields a per-session %/h, so we LEARN the
// conversion between them:
//
//     calibration = quota drop (percentage points) ÷ priced activity ($) in the
//                   same interval                       [pp per API-equiv dollar]
//     session %/h = calibration × session current $/h
//
// Absolute price level cancels between the two lines; correct RELATIVE prices
// still matter, because models, cache reads, cache writes, input and output must
// be weighted differently.
//
// This deliberately does NOT reuse `UsageLimitBurnRateTracker`. That tracker
// measures a short-lived *account rate* and must stay fresh (30-min cap, 3-min
// retention). A calibration is a conversion CONSTANT — a property of the plan,
// near-static — so it tolerates a much longer interval. Inheriting the freshness
// caps would make calibration unacquirable on Codex, whose weekly percent is
// integer-quantized at 1pp (see `acceptance` below).

/// What a calibration is valid for. Any change here invalidates the stored set:
/// a different account, a different usage source, a re-priced table or a changed
/// limit shape all break the pp-per-dollar relationship.
struct WeeklyQuotaCalibrationScope: Equatable, Codable, Sendable {
    let provider: String
    /// Locally hashed account identifier. `nil` means the provider exposes no
    /// account scope (Claude today) — such a calibration is memory-only and must
    /// never be persisted, or it would survive an account switch.
    let accountHash: String?
    let sourceFamily: String
    let limitShape: String
    let priceRevision: Int

    var isPersistable: Bool { accountHash != nil }

    /// Truncated SHA-256. The raw account id never reaches disk.
    static func hashAccount(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// One accepted observation of the conversion.
struct WeeklyQuotaCalibration: Equatable, Codable, Sendable {
    let percentPointsPerDollar: Double
    let acquiredAt: Date
    let intervalSeconds: Double
    let dropPercentPoints: Double
}

/// A session's cumulative token counters as of `capturedAt`, keyed by the log path
/// that produced them. Cumulative (not a rate) on purpose: the ledger banks
/// DELTAS between cycles, so a session that ends mid-interval keeps everything it
/// burned before ending instead of vanishing from the denominator.
struct WeeklyQuotaTokenObservation: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let input: Double
    let cachedInput: Double
    let output: Double
    let cacheCreation: Double
    let modelSlug: String?
}

/// One already-incremental usage record. Claude reports `message.usage` per call;
/// Codex cumulative counters are split at each recorded request boundary so its
/// long-context tier can be priced without merging requests.
struct WeeklyQuotaTokenEvent: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let input: Double
    let cachedInput: Double
    let output: Double
    /// Cache writes at the 5-minute rate, and — split out because it bills at 2×
    /// input rather than 1.25× — those at the 1-hour rate.
    let cacheCreation: Double
    let cacheCreation1h: Double
    let modelSlug: String?
    /// Billing tier from `usage.speed`; fast mode doubles Opus rates.
    let speed: RunwaySpeedTier
    let contextInputTokens: Double?

    init(logPath: String,
         capturedAt: Date,
         input: Double,
         cachedInput: Double,
         output: Double,
         cacheCreation: Double,
         cacheCreation1h: Double = 0,
         modelSlug: String?,
         speed: RunwaySpeedTier = .standard,
         contextInputTokens: Double? = nil) {
        self.logPath = logPath
        self.capturedAt = capturedAt
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheCreation1h = cacheCreation1h
        self.modelSlug = modelSlug
        self.speed = speed
        self.contextInputTokens = contextInputTokens
    }
}

/// Priced activity accumulated over time, so an arbitrary quota interval can be
/// integrated exactly rather than extrapolated from a point-in-time rate.
///
/// Ended sessions are the reason this exists. Activity parsed from *live*
/// identities misses a session that burned half the interval and then closed;
/// its quota drop would land in the numerator with no matching dollars,
/// inflating the calibration and overstating every remaining row.
final class WeeklyQuotaActivityLedger {
    private struct Bucket {
        let at: Date
        let dollars: Double
        let hadUnpriced: Bool
    }

    private struct Cumulative {
        var input: Double
        var cachedInput: Double
        var output: Double
        var cacheCreation: Double
    }

    /// Matches the tracker's max interval — nothing older can ever be integrated.
    static let retention: TimeInterval = 6 * 60 * 60

    private var lastSeen: [String: Cumulative] = [:]
    private var buckets: [Bucket] = []
    /// Dedup for the incremental (Claude) path — see `recordIncremental`.
    private var seenEvents: Set<String> = []
    private var seenEventOrder: [(key: String, at: Date)] = []
    private let lock = NSLock()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        lastSeen.removeAll()
        buckets.removeAll()
        seenEvents.removeAll()
        seenEventOrder.removeAll()
    }

    /// Bank one cycle's worth of activity. Every call appends a bucket — even a
    /// zero-dollar one — because the bucket timeline doubles as the poll-continuity
    /// record the tracker uses to prove it watched the whole interval.
    func record(observations: [WeeklyQuotaTokenObservation],
                priceTable: RunwayPriceTable,
                now: Date) {
        lock.lock(); defer { lock.unlock() }

        var dollars = 0.0
        var hadUnpriced = false

        for obs in observations {
            let previous = lastSeen[obs.logPath]
            let current = Cumulative(input: obs.input,
                                     cachedInput: obs.cachedInput,
                                     output: obs.output,
                                     cacheCreation: obs.cacheCreation)
            lastSeen[obs.logPath] = current
            guard let previous else { continue }  // first sighting establishes a baseline only

            // A counter going backwards means the path was recycled by a new
            // session; bank nothing and re-baseline rather than inventing a
            // negative or a full-cumulative spike.
            let dIn = current.input - previous.input
            let dCached = current.cachedInput - previous.cachedInput
            let dOut = current.output - previous.output
            let dWrite = current.cacheCreation - previous.cacheCreation
            guard dIn >= 0, dCached >= 0, dOut >= 0, dWrite >= 0 else { continue }

            let volume = dIn + dCached + dOut + dWrite
            guard volume > 0 else { continue }

            guard let price = priceTable.price(forModel: obs.modelSlug) else {
                // Material activity we cannot weight. Recorded as a poison flag so
                // any interval containing it is rejected outright: pricing only the
                // known slices would understate the denominator and inflate every
                // row that the resulting calibration touches.
                hadUnpriced = true
                continue
            }
            dollars += dIn * price.inputPerMTok / 1_000_000
                + dCached * price.cachedInputPerMTok / 1_000_000
                + dOut * price.outputPerMTok / 1_000_000
                + dWrite * (price.cacheWritePerMTok ?? price.inputPerMTok) / 1_000_000
        }

        buckets.append(Bucket(at: now, dollars: dollars, hadUnpriced: hadUnpriced))
        let cutoff = now.addingTimeInterval(-Self.retention)
        buckets.removeAll { $0.at < cutoff }
    }

    /// Bank already-incremental usage records. Deduplicated by
    /// path+timestamp because the parser re-reads an overlapping tail every cycle
    /// and double-counting would silently deflate the calibration.
    func recordIncremental(events: [WeeklyQuotaTokenEvent],
                           priceTable: RunwayPriceTable,
                           now: Date) {
        lock.lock(); defer { lock.unlock() }

        var dollars = 0.0
        var hadUnpriced = false
        for event in events {
            let key = "\(event.logPath)|\(event.capturedAt.timeIntervalSinceReferenceDate)"
            guard !seenEvents.contains(key) else { continue }
            seenEvents.insert(key)
            seenEventOrder.append((key: key, at: now))

            let volume = event.input + event.cachedInput + event.output
                + event.cacheCreation + event.cacheCreation1h
            guard volume > 0 else { continue }
            // Same poison flag as an unknown model when the record's billing tier has
            // no rates: the calibration must not be built on a knowingly halved cost.
            guard let price = priceTable.price(forModel: event.modelSlug),
                  let rates = price.rates(for: event.speed,
                                          contextInputTokens: event.contextInputTokens) else {
                hadUnpriced = true
                continue
            }
            dollars += rates.dollars(input: event.input,
                                     cachedInput: event.cachedInput,
                                     output: event.output,
                                     cacheWrite5m: event.cacheCreation,
                                     cacheWrite1h: event.cacheCreation1h)
        }

        buckets.append(Bucket(at: now, dollars: dollars, hadUnpriced: hadUnpriced))
        let cutoff = now.addingTimeInterval(-Self.retention)
        buckets.removeAll { $0.at < cutoff }
        while let first = seenEventOrder.first, first.at < cutoff {
            seenEvents.remove(first.key)
            seenEventOrder.removeFirst()
        }
    }

    struct IntervalActivity: Equatable {
        let dollars: Double
        let hadUnpriced: Bool
        /// Largest gap between consecutive observations inside the interval. A big
        /// gap means we stopped watching (sleep, app quiescence) and cannot claim
        /// the denominator covers the whole interval.
        let maxPollGap: TimeInterval
    }

    func activity(from start: Date, to end: Date) -> IntervalActivity? {
        lock.lock(); defer { lock.unlock() }
        let inRange = buckets.filter { $0.at > start && $0.at <= end }
        guard !inRange.isEmpty else { return nil }

        var dollars = 0.0
        var hadUnpriced = false
        var maxGap: TimeInterval = 0
        var cursor = start
        for bucket in inRange {
            maxGap = max(maxGap, bucket.at.timeIntervalSince(cursor))
            cursor = bucket.at
            dollars += bucket.dollars
            hadUnpriced = hadUnpriced || bucket.hadUnpriced
        }
        maxGap = max(maxGap, end.timeIntervalSince(cursor))
        return IntervalActivity(dollars: dollars, hadUnpriced: hadUnpriced, maxPollGap: maxGap)
    }
}

/// Learns and retains the pp-per-dollar conversion.
struct WeeklyQuotaCalibrationTracker {
    // MARK: Acceptance bounds
    //
    // These are NOT the burn-rate tracker's bounds and must not be unified with
    // them. A conversion constant tolerates a long interval; a "current pace"
    // reading does not.

    /// Below this, timing noise dominates the measurement.
    static let minimumInterval: TimeInterval = 60
    /// Six hours, not thirty minutes. Codex's weekly percent moves in whole
    /// points, and burning 1pp of a WEEKLY quota inside 30 minutes is heavy usage —
    /// under the old cap an ordinary day produced no acceptable interval at all.
    static let maximumInterval: TimeInterval = 6 * 60 * 60
    /// We must have been watching throughout, or untracked activity is missing
    /// from the denominator.
    static let maximumPollGap: TimeInterval = 15 * 60
    /// One whole quantum when only integer percent is available (Codex).
    static let minimumDropInteger: Double = 1.0
    /// Claude's OAuth path supplies fractional percent, so it can learn sooner.
    static let minimumDropExact: Double = 0.25
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// Above this the calibration is contaminated, not the session extraordinary.
    static let maximumDisplayablePercentPerHour: Double = 999

    private struct Anchor {
        let remainingPercent: Double
        let observedAt: Date
        let resetAt: Date
    }

    private var anchor: Anchor?
    private var scope: WeeklyQuotaCalibrationScope?
    private var accepted: [WeeklyQuotaCalibration] = []
    /// When this scope first started being observed. Retained for diagnostics;
    /// the user-facing wait is budgeted from app launch in
    /// `WeeklyQuotaCalibrationStore.calibrationAbandoned`, not from here.
    private var firstObservedAt: Date?

    var currentScope: WeeklyQuotaCalibrationScope? { scope }

    /// Total quota movement represented by the current contiguous live span.
    func conditioningPercentPoints(now: Date) -> Double {
        accepted
            .filter { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge }
            .last?.dropPercentPoints ?? 0
    }

    /// One ratio of aggregate quota movement to aggregate priced dollars. Adjacent
    /// integer ticks share endpoint quantization error, so treating them as
    /// independent ratios and taking a median would give tiny intervals equal vote.
    func percentPointsPerDollar(now: Date) -> Double? {
        accepted.last(where: { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge })?
            .percentPointsPerDollar
    }

    var acceptedCount: Int { accepted.count }

    mutating func invalidate() {
        anchor = nil
        accepted.removeAll()
        firstObservedAt = nil
    }

    /// Feed one quota observation. Returns the calibration accepted on this call,
    /// or nil when the sample only re-anchors.
    @discardableResult
    mutating func update(remainingPercent: Double,
                         hasExactPercent: Bool,
                         resetAt: Date,
                         observedAt: Date,
                         scope newScope: WeeklyQuotaCalibrationScope,
                         ledger: WeeklyQuotaActivityLedger,
                         now: Date) -> WeeklyQuotaCalibration? {
        // Any scope change breaks the learned relationship outright.
        if scope != newScope {
            scope = newScope
            invalidate()
            firstObservedAt = observedAt
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }
        if firstObservedAt == nil { firstObservedAt = observedAt }

        guard let previous = anchor else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        // A weekly reset re-anchors measurement but keeps the conversion: the plan
        // did not change, only the counter.
        guard abs(previous.resetAt.timeIntervalSince(resetAt)) < 120 else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        // Quota recovered (or a stale/reordered sample). Re-anchor, learn nothing.
        guard remainingPercent <= previous.remainingPercent else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        let elapsed = observedAt.timeIntervalSince(previous.observedAt)
        guard elapsed >= Self.minimumInterval else { return nil }
        guard elapsed <= Self.maximumInterval else {
            // Interval ran too long to trust; start a fresh one.
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        let drop = previous.remainingPercent - remainingPercent
        let minimumDrop = hasExactPercent ? Self.minimumDropExact : Self.minimumDropInteger
        // Deliberately does NOT advance the anchor: a coarse 1pp tick must divide
        // by the time since the anchor was FIRST seen. Advancing on every unchanged
        // poll would turn it into an artificial last-poll spike.
        guard drop >= minimumDrop else { return nil }

        guard let activity = ledger.activity(from: previous.observedAt, to: observedAt) else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }
        // A drop with no local activity is somebody else's usage (another device,
        // another client). Re-anchor without learning.
        // Unpriceable material activity poisons the whole interval — see the ledger.
        guard activity.dollars > 0,
              !activity.hadUnpriced,
              activity.maxPollGap <= Self.maximumPollGap else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        let calibration = WeeklyQuotaCalibration(
            percentPointsPerDollar: drop / activity.dollars,
            acquiredAt: observedAt,
            intervalSeconds: elapsed,
            dropPercentPoints: drop
        )
        guard calibration.percentPointsPerDollar.isFinite,
              calibration.percentPointsPerDollar > 0 else {
            anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
            return nil
        }

        // Keep the original anchor so later ticks expand this same live span. The
        // newest aggregate replaces the prior aggregate; overlapping tick ratios
        // are never retained as if they were independent observations.
        accepted = [calibration]
        return calibration
    }

    // MARK: - Persistence
    //
    // Only a scoped calibration is ever written. An unscoped one (Claude, which
    // exposes no account identity) stays in memory for the life of the process, so
    // it cannot survive a possible account switch.

    /// Version 1 predates record-family-specific activity accounting. Codex's v1
    /// samples may have mixed per-request and cumulative counters. Version 2 could
    /// also drop a whole ordinary tail when its first byte split a UTF-8 scalar;
    /// version 3 preserved those records but could assign a later model switch to
    /// leading token records. Version 4 preserves record and model chronology.
    /// No older denominator may survive the parser corrections. Claude already
    /// supplied incremental events and remains compatible with v1.
    private static let legacyActivityAccountingRevision = 1
    private static let codexActivityAccountingRevision = 4

    private static func activityAccountingRevision(for provider: String) -> Int {
        provider == "codex"
            ? codexActivityAccountingRevision
            : legacyActivityAccountingRevision
    }

    private struct Payload: Codable {
        /// Optional so records written before the stamp decode as legacy revision 1.
        let activityAccountingRevision: Int?
        let scope: WeeklyQuotaCalibrationScope
        let accepted: [WeeklyQuotaCalibration]
    }

    func persistedData() -> Data? {
        guard let scope, scope.isPersistable, !accepted.isEmpty else { return nil }
        return try? JSONEncoder().encode(Payload(
            activityAccountingRevision: Self.activityAccountingRevision(for: scope.provider),
            scope: scope,
            accepted: accepted))
    }

    mutating func restore(from data: Data, scope expected: WeeklyQuotaCalibrationScope, now: Date) {
        guard expected.isPersistable,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (payload.activityAccountingRevision ?? Self.legacyActivityAccountingRevision)
                == Self.activityAccountingRevision(for: expected.provider),
              payload.scope == expected else { return }
        scope = expected
        firstObservedAt = nil
        accepted = payload.accepted
            .filter { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge }
            .suffix(1)
            .map { $0 }
    }
}

/// Process-wide home for the weekly calibration state, one entry per provider.
///
/// The ledger is fed every runway cycle (it needs continuous coverage to prove it
/// watched a whole interval); the tracker is fed whenever a usage poll delivers a
/// weekly percentage. Those arrive on different clocks, which is exactly why the
/// two live behind one lock here rather than inside either caller.
final class WeeklyQuotaCalibrationStore: @unchecked Sendable {
    static let shared = WeeklyQuotaCalibrationStore()

    typealias BootstrapScanRunner = @Sendable (
        _ provider: String,
        _ root: URL,
        _ resetsAt: Date,
        _ windowMinutes: Int,
        _ usedPercentPoints: Double,
        _ priceTable: RunwayPriceTable,
        _ now: Date
    ) -> WeeklyQuotaBootstrapResult?

    /// `launchedAt` is injectable because it is wall-clock state on a singleton,
    /// which is a trap for tests: `.shared` is constructed the first time ANY test
    /// touches it, so a later test inherits an already-expired waiting budget and
    /// sees "abandoned" before it has waited at all — passing in isolation and
    /// failing in the suite. Tests should use `makeForTesting()` and get a clean
    /// store by construction rather than remembering to reset a shared one.
    init(launchedAt: Date = Date(),
         scanRunner: BootstrapScanRunner? = nil,
         priceRevisionProvider: (@Sendable () -> Int)? = nil) {
        self.launchedAt = launchedAt
        self.scanRunner = scanRunner ?? Self.runBootstrapScan
        self.priceRevisionProvider = priceRevisionProvider ?? { RunwayPriceTable.shared.revision }
    }

#if DEBUG
    /// A private store with its own clock and no shared state. Mirrors
    /// `RunwayPriceTable.makeForTesting()`. Pair it with a scratch `UserDefaults`
    /// suite so persistence assertions never touch the real domain.
    static func makeForTesting(
        launchedAt: Date = Date(),
        scanRunner: BootstrapScanRunner? = nil,
        priceRevisionProvider: (@Sendable () -> Int)? = nil
    ) -> WeeklyQuotaCalibrationStore {
        WeeklyQuotaCalibrationStore(
            launchedAt: launchedAt,
            scanRunner: scanRunner,
            priceRevisionProvider: priceRevisionProvider)
    }
#endif

    private let lock = NSLock()
    private let scanRunner: BootstrapScanRunner
    private let priceRevisionProvider: @Sendable () -> Int
    private var ledgers: [String: WeeklyQuotaActivityLedger] = [:]
    private var trackers: [String: WeeklyQuotaCalibrationTracker] = [:]
    private var restored: Set<String> = []
    /// Historical calibration computed from transcripts at launch — the reason
    /// `Wk` shows a number in seconds instead of waiting hours for a 1pp tick.
    private var bootstraps: [String: WeeklyQuotaBootstrapResult] = [:]
    /// Latest weekly consumption seen per provider, so a stored bootstrap's
    /// numerator can be kept current without rescanning.
    private var latestUsedPercentPoints: [String: Double] = [:]
    /// The window that `latestUsedPercentPoints` was reported against. Freshening
    /// pairs a numerator with a denominator, and the two must describe the SAME
    /// window — see `freshenedBootstrapRatio`.
    private var latestResetsAt: [String: Date] = [:]
    /// Scope (account) each provider's in-memory state belongs to. The persisted
    /// keys are account-scoped, but the maps here are keyed by provider alone, so
    /// without this an in-process account switch keeps serving the previous
    /// account's calibration.
    private struct BootstrapScopeKey: Equatable {
        let accountHash: String
        let priceRevision: Int
        let limitShape: String?
    }
    private var activeScopeKeys: [String: BootstrapScopeKey] = [:]
    /// Providers whose older anchor-keyed caches have been folded into the
    /// carry-over slot. Once per process; see `migrateHistoricalBootstraps`.
    private var migratedProviders: Set<String> = []
    /// Earliest retry after a failed scan, so a provider whose transcripts cannot
    /// be priced does not rescan on every 5s runway cycle.
    private var scanCooldownUntil: [String: Date] = [:]
    /// Scans dispatched per provider. Test observability only: dispatch and
    /// success must be distinguishable, since retry-after-failure is the behavior
    /// under test, and a second attempt must be distinguishable from the first.
    private var dispatchedScans: [String: Int] = [:]
    /// Bumped whenever a provider's scope changes. A scan captures the value at
    /// dispatch and its completion is discarded if it no longer matches, so an old
    /// account's in-flight walk cannot land in the new account's state.
    private var scopeGenerations: [String: Int] = [:]
    /// Backoff after a scan that returned nothing usable. Long enough that a
    /// permanently unscannable root costs one walk per interval, short enough that
    /// a transient read failure self-heals well inside a weekly window.
    static let failedScanCooldown: TimeInterval = 600
    /// Best-conditioned bootstrap ever seen for a provider (largest numerator),
    /// retained across weekly resets. See `bestConditionedBootstrap`.
    private var bestBootstraps: [String: WeeklyQuotaBootstrapResult] = [:]
    /// Anchors already scanned (or being scanned), so the week is walked once per
    /// window rather than once per 5s runway cycle.
    private var scannedAnchors: Set<String> = []
    /// Providers with a bootstrap scan currently running. The waiting clock must
    /// not flip to "n/a" mid-scan and then flip back to a number when it lands.
    private var scansInFlight: Set<String> = []
    /// When each in-flight scan began, so a stalled one cannot suppress the
    /// waiting budget forever (see `calibrationAbandoned`).
    private var scanStartedAt: [String: Date] = [:]
    /// A scan that has run this long is not coming back in a useful timeframe;
    /// stop letting it hold the UI in the waiting state.
    static let scanDeadline: TimeInterval = 120
    /// When this process started serving quota state. The waiting indicator is
    /// budgeted against THIS, not against any per-session or per-attempt clock:
    /// the user is waiting from the moment they open the app.
    private var launchedAt: Date

    /// How long the waiting clock may run before the row admits defeat with "n/a".
    /// One minute: the bootstrap scan is a few seconds, so anything past this means
    /// it failed or the window has too little history to divide by.
    static let waitingBudget: TimeInterval = 60

    private static func runBootstrapScan(
        provider: String,
        root: URL,
        resetsAt: Date,
        windowMinutes: Int,
        usedPercentPoints: Double,
        priceTable: RunwayPriceTable,
        now: Date
    ) -> WeeklyQuotaBootstrapResult? {
        if provider == "claude" {
            return ClaudeWeeklyQuotaBootstrapScanner.scan(
                root: root,
                resetsAt: resetsAt,
                windowMinutes: windowMinutes,
                usedPercentPoints: usedPercentPoints,
                priceTable: priceTable,
                now: now,
                fileManager: FileManager.default)
        }
        return CodexWeeklyQuotaBootstrapScanner.scan(
            root: root,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes,
            usedPercentPoints: usedPercentPoints,
            priceTable: priceTable,
            now: now,
            fileManager: FileManager.default)
    }

    private static func defaultsKey(provider: String, scope: WeeklyQuotaCalibrationScope) -> String {
        "quotaMeter.weeklyCalibration.\(provider).\(scope.accountHash ?? "unscoped")"
    }

    /// Bootstrap cache key. Includes the weekly anchor, so a new window never
    /// reads the previous one's ratio, and the account hash where the provider
    /// exposes one. Claude has no account scope, but its anchor is an account's
    /// own reset instant at second precision, which discriminates in practice —
    /// and a wrong hit is corrected by the refresh scan on the same launch.
    private static func bootstrapKey(provider: String, accountHash: String?, resetsAt: Date) -> String {
        "quotaMeter.weeklyBootstrap.\(provider).\(accountHash ?? "unscoped").\(Int(resetsAt.timeIntervalSince1970))"
    }

    /// Deliberately NOT anchor-keyed. The pp-per-dollar conversion describes the
    /// plan, not the window, so the best measurement must outlive the window it
    /// came from — otherwise every weekly reset orphans it and the fresh window
    /// has ~0% consumed to divide by, stranding the UI on "n/a" for hours.
    /// Prefix shared by every anchor-keyed bootstrap cache for one provider+scope.
    /// Used to sweep prior windows into the carry-over slot.
    private static func bootstrapKeyPrefix(provider: String, accountHash: String?) -> String {
        "quotaMeter.weeklyBootstrap.\(provider).\(accountHash ?? "unscoped")."
    }

    private static func bestBootstrapKey(provider: String, accountHash: String?) -> String {
        "quotaMeter.weeklyBootstrapBest.\(provider).\(accountHash ?? "unscoped")"
    }

    /// Re-scan once the window has consumed this much more than the stored
    /// bootstrap measured. Integer quantization means a ratio learned at 1pp can
    /// be ~50% off while the same window at 10pp is ~5% off, so a frozen early
    /// reading is a real accuracy bug, not just staleness.
    static let bootstrapRefreshGrowthPercentPoints: Double = 3

    /// A numerator this large carries ~±5% from integer quantization, which is
    /// close enough that being from the CURRENT quota regime matters more than
    /// being the largest number ever recorded.
    static let wellConditionedPercentPoints: Double = 10

    /// How long a carried-over measurement may outlive its own window. Three weekly
    /// windows: long enough that an idle fortnight still starts on a real number,
    /// short enough that a quota-regime change cannot be served indefinitely.
    static let carryOverMaximumAge: TimeInterval = 21 * 24 * 60 * 60

    func ledger(provider: String) -> WeeklyQuotaActivityLedger {
        lock.lock(); defer { lock.unlock() }
        if let existing = ledgers[provider] { return existing }
        let created = WeeklyQuotaActivityLedger()
        ledgers[provider] = created
        return created
    }

    /// Conversion for this provider, or nil while uncalibrated.
    ///
    /// Prefer the measurement with the better-conditioned quota numerator. A live
    /// sample is structurally cleaner than a historical scan, but two integer 1pp
    /// ticks are still much noisier than (for example) a 33pp bootstrap. Once the
    /// live span reaches 10pp it is good enough to represent the current quota
    /// regime directly; before then it must cover at least as many points as the
    /// bootstrap it would replace.
    func percentPointsPerDollar(provider: String, now: Date) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let tracker = trackers[provider]
        let live = tracker?.percentPointsPerDollar(now: now)
        let livePoints = tracker?.conditioningPercentPoints(now: now) ?? 0
        if let bootstrap = bestConditionedBootstrap(provider: provider, now: now) {
            let requiredLivePoints = min(
                Self.wellConditionedPercentPoints,
                bootstrap.usedPercentPoints
            )
            if livePoints >= requiredLivePoints, let live { return live }
            return freshenedBootstrapRatio(provider: provider, bootstrap: bootstrap, now: now)
                ?? bootstrap.calibratedPercentPointsPerDollar
        }
        return live
    }

    /// Ledger activity since a bootstrap was measured, or nil when the ledger
    /// cannot vouch for that span.
    ///
    /// The poll-gap check is the part that matters and was missing. `activity` is
    /// happy to answer from a single bucket, so after a restart — the ledger is
    /// memory-only and starts empty — freshening got the spend banked since launch
    /// and silently dropped everything between the cached scan and it. That is an
    /// undercounted denominator, which overstates the burn rate rather than
    /// failing safe. Observed live: a cache of 4pp/$13.56 restored while actual
    /// spend had reached $28.07 served 0.332 pp/$ against a true 0.232 — 43% high,
    /// and neither the growth (+3pp) nor the age (6h) trigger could clear it.
    ///
    /// Callers must hold `lock`.
    private func ledgerCoverage(provider: String,
                                since bootstrap: WeeklyQuotaBootstrapResult,
                                now: Date) -> WeeklyQuotaActivityLedger.IntervalActivity? {
        guard now.timeIntervalSince(bootstrap.scannedAt) <= WeeklyQuotaActivityLedger.retention,
              let ledger = ledgers[provider],
              let since = ledger.activity(from: bootstrap.scannedAt, to: now),
              since.maxPollGap <= WeeklyQuotaCalibrationTracker.maximumPollGap else { return nil }
        return since
    }

    /// The stored ratio with BOTH terms brought up to date.
    ///
    /// A frozen bootstrap drifts high, and measurably so: the numerator is
    /// integer-quantized, so it sits on one value for hours while real spending
    /// keeps accruing. Measured on a live account, a ratio scanned at $20 was
    /// still being served once actual spend had reached $28 — a 43% overestimate
    /// of every session's %/h. The activity ledger is already banking priced
    /// dollars every cycle, so the denominator can be extended for free.
    ///
    /// Returns nil when the ledger cannot cover the span (its buckets are trimmed
    /// to 6h), leaving the caller on the stored ratio plus the growth-triggered
    /// rescan.
    private func freshenedBootstrapRatio(provider: String,
                                         bootstrap: WeeklyQuotaBootstrapResult,
                                         now: Date) -> Double? {
        guard let reported = latestUsedPercentPoints[provider], reported > 0 else { return nil }
        // Both terms must describe the same window. `bestConditionedBootstrap` may
        // hand back a measurement carried over from a PREVIOUS week — that ratio is
        // still the best estimate of the plan's conversion, but its dollars are the
        // old window's. Pairing them with this window's percent yields a number that
        // belongs to neither: a carried 77pp/$1240 alongside a fresh week reporting
        // 1pp would serve 1.5/1240 instead of 77/1240, understating by ~50x.
        guard let currentAnchor = latestResetsAt[provider],
              abs(bootstrap.resetsAt.timeIntervalSince(currentAnchor))
                < CodexWeeklyQuotaBootstrapScanner.anchorTolerance else { return nil }
        // Midpoint, not the reported floor. A provider reporting "2" means true
        // consumption is somewhere in [2, 3); taking 2 biases every estimate low,
        // and the bias is worst exactly where the numerator is smallest.
        let used = reported + WeeklyQuotaBootstrapResult.quantizationMidpoint
        guard let since = ledgerCoverage(provider: provider, since: bootstrap, now: now) else { return nil }
        let dollars = bootstrap.dollars + since.dollars
        guard dollars > 0 else { return nil }
        let ratio = used / dollars
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }

    /// Numerator size decides which measurement to trust, not recency.
    ///
    /// Weekly percent is integer-quantized, so a ratio measured at 2pp carries
    /// ~±25% and slides badly as spending accrues inside that quantum, while one
    /// measured over a completed 72pp week is stable to a few percent. Keeping the
    /// best-conditioned observation also carries a good ratio across a weekly
    /// reset, where the fresh window has nothing to divide by yet — the conversion
    /// is a property of the plan, not of the window.
    private func bestConditionedBootstrap(provider: String,
                                          now: Date = Date()) -> WeeklyQuotaBootstrapResult? {
        let current = bootstraps[provider]
        guard let best = bestBootstraps[provider] else { return current }
        // A carry-over describes the quota REGIME it was measured under, and a
        // regime can change without touching anything the compatibility stamp can
        // see. Promotional weekly limits are the live example: both vendors have run
        // them, they move capacity by tens of percent, and they start and end with no
        // price change and no limit-shape change — so a measurement taken under one
        // stays formally compatible while describing a plan that no longer exists.
        // (Do not encode a specific promotion's terms or dates here: they are vendor
        // announcements, they change, and the code cannot verify them.)
        //
        // Nothing in the payload announces a regime change, so recency has to win
        // eventually: once the CURRENT window is well enough conditioned to stand on
        // its own it is preferred outright, and a carry-over that no fresh
        // measurement has displaced expires rather than being trusted indefinitely.
        if now.timeIntervalSince(best.scannedAt) > Self.carryOverMaximumAge {
            return current
        }
        guard let current else { return best }
        if current.usedPercentPoints >= Self.wellConditionedPercentPoints { return current }
        return current.usedPercentPoints >= best.usedPercentPoints ? current : best
    }

    func bootstrap(provider: String) -> WeeklyQuotaBootstrapResult? {
        lock.lock(); defer { lock.unlock() }
        return bootstraps[provider]
    }

    /// True once the waiting budget has elapsed with nothing to show. Measured
    /// from APP LAUNCH, deliberately: a per-attempt or per-session timer would
    /// restart under the user and let the spinner run indefinitely in practice.
    func calibrationAbandoned(provider: String, now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if (trackers[provider]?.percentPointsPerDollar(now: now)) != nil { return false }
        // Must consult the SAME selection the reader uses, or a carried-over
        // measurement satisfies `percentPointsPerDollar` while this still reports
        // "give up" — the row would show n/a next to a perfectly good number.
        if bestConditionedBootstrap(provider: provider, now: now)?.percentPointsPerDollar != nil { return false }
        // A scan still running WILL produce a number, so don't show "n/a" only to
        // contradict it seconds later. Bounded by `scanDeadline`: without that, a
        // stalled scan would pin the clock on screen forever, which is the exact
        // failure the launch budget exists to prevent.
        if scansInFlight.contains(provider),
           let startedAt = scanStartedAt[provider],
           now.timeIntervalSince(startedAt) <= Self.scanDeadline {
            return false
        }
        return now.timeIntervalSince(launchedAt) > Self.waitingBudget
    }

    /// Feed one weekly quota observation. Restores persisted calibration on first
    /// sight of a persistable scope, and writes back whenever one is accepted.
    @discardableResult
    func observeQuota(provider: String,
                      remainingPercent: Double,
                      hasExactPercent: Bool,
                      resetAt: Date,
                      observedAt: Date,
                      scope: WeeklyQuotaCalibrationScope,
                      now: Date,
                      defaults: UserDefaults = .standard) -> WeeklyQuotaCalibration? {
        let ledger = self.ledger(provider: provider)
        lock.lock(); defer { lock.unlock() }

        var tracker = trackers[provider] ?? WeeklyQuotaCalibrationTracker()
        let restoreKey = Self.defaultsKey(provider: provider, scope: scope)
        if scope.isPersistable, !restored.contains(restoreKey) {
            restored.insert(restoreKey)
            if let data = defaults.data(forKey: restoreKey) {
                tracker.restore(from: data, scope: scope, now: now)
            }
        }

        let accepted = tracker.update(remainingPercent: remainingPercent,
                                      hasExactPercent: hasExactPercent,
                                      resetAt: resetAt,
                                      observedAt: observedAt,
                                      scope: scope,
                                      ledger: ledger,
                                      now: now)
        trackers[provider] = tracker
        // Captured under the lock, written outside it: a synchronous defaults write
        // must not block the 5s runway cycle's reader on disk I/O.
        let payload = accepted != nil ? tracker.persistedData() : nil
        lock.unlock()
        if let payload { defaults.set(payload, forKey: restoreKey) }
        lock.lock()
        return accepted
    }

    /// Fold every stored window's measurement into the carry-over slot, once per
    /// process.
    ///
    /// The carry-over slot is meant to hold the best-conditioned ratio ever seen,
    /// but the restore path only ever read two keys: the slot itself and the
    /// CURRENT anchor's cache. Anchor caches from previous windows were therefore
    /// invisible, and the very first launch after the slot was introduced seeded it
    /// from whatever the current window happened to hold. Observed on a live
    /// account: a completed week measured at 77pp/$1239.83 (0.0621 pp/$) sat on
    /// disk while the slot served the fresh window's 7pp/$142.71 (0.0491 pp/$) —
    /// a 21% understatement of every Claude session's %/h, with the better
    /// measurement already present and simply unread.
    ///
    /// Cheap enough for the poll path: one dictionary snapshot, then decoding only
    /// the handful of keys under this provider's prefix.
    private func migrateHistoricalBootstraps(provider: String,
                                             accountHash: String?,
                                             priceRevision: Int,
                                             limitShape: String?,
                                             bestKey: String,
                                             defaults: UserDefaults) {
        lock.lock()
        let alreadyMigrated = migratedProviders.contains(provider)
        if !alreadyMigrated { migratedProviders.insert(provider) }
        lock.unlock()
        guard !alreadyMigrated else { return }

        let prefix = Self.bootstrapKeyPrefix(provider: provider, accountHash: accountHash)
        var best: WeeklyQuotaBootstrapResult?
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = value as? Data,
                  let cached = try? JSONDecoder().decode(WeeklyQuotaBootstrapResult.self, from: data),
                  cached.percentPointsPerDollar != nil,
                  // A measurement priced under a different table, or taken under a
                  // different plan shape, describes a different conversion. Without
                  // this an old plan could win forever purely by having reached a
                  // larger percentage.
                  cached.isCompatible(priceRevision: priceRevision,
                                      limitShape: limitShape) else { continue }
            if cached.usedPercentPoints > (best?.usedPercentPoints ?? 0) { best = cached }
        }
        guard let best else { return }

        lock.lock()
        let isBetter = (bestBootstraps[provider]?.usedPercentPoints ?? 0) < best.usedPercentPoints
        if isBetter { bestBootstraps[provider] = best }
        lock.unlock()
        guard isBetter, let encoded = try? JSONEncoder().encode(best) else { return }
        defaults.set(encoded, forKey: bestKey)
        CodexWeeklyQuotaBootstrapScanner.debugLog(
            "BOOTSTRAP MIGRATED provider=\(provider) used=\(best.usedPercentPoints)pp "
            + "ppPerDollar=\(best.percentPointsPerDollar ?? -1)")
    }

    /// Compute the historical calibration for the current weekly window, once per
    /// anchor, off the main thread. Safe to call on every usage poll.
    func ensureBootstrap(provider: String,
                         root: URL,
                         resetsAt: Date,
                         windowMinutes: Int,
                         usedPercentPoints: Double,
                         accountHash: String? = nil,
                         limitShape: String? = nil,
                         now: Date = Date(),
                         defaults: UserDefaults = .standard) {
        let storeKey = Self.bootstrapKey(provider: provider, accountHash: accountHash, resetsAt: resetsAt)
        let bestKey = Self.bestBootstrapKey(provider: provider, accountHash: accountHash)
        let priceRevision = priceRevisionProvider()
        let scopeKey = BootstrapScopeKey(
            accountHash: accountHash ?? "unscoped",
            priceRevision: priceRevision,
            limitShape: limitShape)
        var promoted: WeeklyQuotaBootstrapResult?
        lock.lock()
        // The persisted keys are account-scoped but these maps are not, so a
        // same-process account switch would otherwise keep serving the previous
        // account's calibration under the new account's name.
        if let previous = activeScopeKeys[provider], previous != scopeKey {
            bootstraps[provider] = nil
            bestBootstraps[provider] = nil
            trackers[provider] = nil
            ledgers[provider] = nil
            latestResetsAt[provider] = nil
            // `restored` holds full defaults keys ("quotaMeter.weeklyCalibration.
            // codex.<hash>"), never a bare provider, so removing the provider
            // string removed nothing — and switching A → B → A then skipped A's
            // restore, leaving its persisted live samples unread.
            restored = restored.filter {
                !$0.hasPrefix("quotaMeter.weeklyCalibration.\(provider).")
            }
            migratedProviders.remove(provider)
            scanCooldownUntil[provider] = nil
            dispatchedScans[provider] = nil
            scannedAnchors = scannedAnchors.filter { !$0.hasPrefix("\(provider)|") }
            // Any scan still walking belongs to the previous account.
            scopeGenerations[provider] = (scopeGenerations[provider] ?? 0) + 1
        }
        activeScopeKeys[provider] = scopeKey
        latestUsedPercentPoints[provider] = usedPercentPoints
        latestResetsAt[provider] = resetsAt
        // Restore the carried-over measurement once per process. Without this the
        // cross-reset carry only works while the app keeps running.
        if bestBootstraps[provider] == nil,
           let data = defaults.data(forKey: bestKey),
           let cached = try? JSONDecoder().decode(WeeklyQuotaBootstrapResult.self, from: data),
           cached.percentPointsPerDollar != nil,
           cached.isCompatible(priceRevision: priceRevision,
                               limitShape: limitShape) {
            bestBootstraps[provider] = cached
        }
        lock.unlock()
        migrateHistoricalBootstraps(provider: provider,
                                    accountHash: accountHash,
                                    priceRevision: priceRevision,
                                    limitShape: limitShape,
                                    bestKey: bestKey,
                                    defaults: defaults)

        // Restore first, synchronously: a cached ratio for this exact window makes
        // the very first frame after launch a real number instead of a clock, and
        // avoids re-reading hundreds of megabytes of transcripts every launch.
        lock.lock()
        if bootstraps[provider] == nil,
           let data = defaults.data(forKey: storeKey),
           let cached = try? JSONDecoder().decode(WeeklyQuotaBootstrapResult.self, from: data),
           // Tolerance, not equality: the provider's reset instant arrives with a
           // varying sub-second component (…200.038 one poll, …200.279 the next),
           // so an exact Double compare never matches and every launch rescans.
           abs(cached.resetsAt.timeIntervalSince(resetsAt)) < CodexWeeklyQuotaBootstrapScanner.anchorTolerance,
           cached.percentPointsPerDollar != nil,
           cached.isCompatible(priceRevision: priceRevision,
                               limitShape: limitShape) {
            bootstraps[provider] = cached
        }
        // Promote on RESTORE too, not only after a scan. A launch that restores
        // from the anchor-keyed cache never scans, so without this the carry-over
        // slot stays empty and the next weekly reset has nothing to fall back on —
        // exactly the gap this was added to close.
        if let current = bootstraps[provider],
           (bestBootstraps[provider]?.usedPercentPoints ?? 0) <= current.usedPercentPoints {
            bestBootstraps[provider] = current
            promoted = current
        }
        let stored = bootstraps[provider]
        let storedIsFreshenable = stored.map {
            ledgerCoverage(provider: provider, since: $0, now: now) != nil
        } ?? false
        lock.unlock()
        if let promoted, let encoded = try? JSONEncoder().encode(promoted) {
            defaults.set(encoded, forKey: bestKey)
        }

        // Re-scan when the window has moved on enough that the stored ratio is
        // materially less accurate than a fresh one would be.
        let anchorKey = "\(provider)|\(Int(resetsAt.timeIntervalSince1970))|\(Int(usedPercentPoints / Self.bootstrapRefreshGrowthPercentPoints))"
        // Two independent triggers, because either alone leaves a stale ratio.
        //
        // Growth: the window has consumed enough more that a fresh scan is better
        // conditioned than the stored one.
        //
        // Age: the ledger can only extend a denominator within its own retention
        // window, so once the stored scan is older than that, nothing can freshen
        // it. Observed on a live account — a ratio scanned the previous day was
        // still being served while real spend against the same integer percent had
        // grown 14%, and the growth trigger could never fire because the reported
        // percent had not moved.
        //
        // Unfreshenable: the ledger cannot vouch for the span since the stored scan,
        // so its denominator is frozen while spending continues. The ledger is
        // memory-only, so EVERY restart lands here with a same-anchor cache that
        // neither other trigger can clear — the 43% live overstatement in
        // `ledgerCoverage`. Rescanning is the only way to re-measure the denominator.
        let staleEnough = stored.map {
            usedPercentPoints - $0.usedPercentPoints >= Self.bootstrapRefreshGrowthPercentPoints
                || now.timeIntervalSince($0.scannedAt) > WeeklyQuotaActivityLedger.retention
                || !storedIsFreshenable
        } ?? true
        guard staleEnough else { return }

        // `scannedAnchors` records SUCCESSES, never attempts. Marking on dispatch
        // looks equivalent and is not: every failure path below returns without
        // clearing it, so one unreadable root or unpriced week would retire this
        // bucket permanently and pin the very stale ratio the rescan exists to
        // replace. It also created a startup dead zone — a window at 0pp is
        // rejected by the scanner for having nothing to divide, and 0pp/1pp/2pp
        // share a bucket, so the burnt attempt blocked any retry until 3pp.
        // Failures back off on a cooldown instead.
        lock.lock()
        let blocked = scannedAnchors.contains(anchorKey)
            || scansInFlight.contains(provider)
            || (scanCooldownUntil[provider].map { now < $0 } ?? false)
        if !blocked {
            scansInFlight.insert(provider)
            scanStartedAt[provider] = now
            dispatchedScans[provider, default: 0] += 1
        }
        let generation = scopeGenerations[provider] ?? 0
        lock.unlock()
        guard !blocked else { return }

        DispatchQueue.global(qos: .utility).async {
            defer {
                self.lock.lock()
                self.scansInFlight.remove(provider)
                self.scanStartedAt[provider] = nil
                self.lock.unlock()
            }
            func backOff() {
                self.lock.lock()
                // A failed scan belongs to the scope that dispatched it just as
                // much as a successful result does. Without this guard, account A
                // can fail after a switch and impose its ten-minute cooldown on B.
                guard (self.scopeGenerations[provider] ?? 0) == generation else {
                    self.lock.unlock()
                    return
                }
                self.scanCooldownUntil[provider] = now.addingTimeInterval(Self.failedScanCooldown)
                self.lock.unlock()
            }
            guard let result = self.scanRunner(
                provider, root, resetsAt, windowMinutes, usedPercentPoints,
                RunwayPriceTable.shared, now
            ) else { backOff(); return }
            // A week can contain one slug the price table has never seen without
            // meaningfully moving the ratio; a large unknown share cannot.
            guard result.unpricedVolumeShare <= CodexWeeklyQuotaBootstrapScanner.maximumUnpricedShare,
                  result.percentPointsPerDollar != nil else { backOff(); return }
            var stamped = result
            stamped.limitShape = limitShape
            self.lock.lock()
            // The account may have changed while this walk was running. Its
            // result describes the PREVIOUS account and must not land here — the
            // dictionaries are keyed by provider, so nothing else would stop it.
            guard (self.scopeGenerations[provider] ?? 0) == generation else {
                self.lock.unlock()
                CodexWeeklyQuotaBootstrapScanner.debugLog(
                    "BOOTSTRAP DISCARDED provider=\(provider) reason=scope-changed-during-scan")
                return
            }
            self.scannedAnchors.insert(anchorKey)
            self.scanCooldownUntil[provider] = nil
            self.bootstraps[provider] = stamped
            let isBest = (self.bestBootstraps[provider]?.usedPercentPoints ?? 0) <= stamped.usedPercentPoints
            if isBest { self.bestBootstraps[provider] = stamped }
            self.lock.unlock()
            if isBest, let encoded = try? JSONEncoder().encode(stamped) {
                defaults.set(encoded, forKey: bestKey)
            }
            if let encoded = try? JSONEncoder().encode(stamped) {
                defaults.set(encoded, forKey: storeKey)
            }
            CodexWeeklyQuotaBootstrapScanner.debugLog(
                "BOOTSTRAP STORED provider=\(provider) ppPerDollar=\(result.percentPointsPerDollar ?? -1)")
        }
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        ledgers.removeAll()
        trackers.removeAll()
        restored.removeAll()
        bootstraps.removeAll()
        bestBootstraps.removeAll()
        latestUsedPercentPoints.removeAll()
        latestResetsAt.removeAll()
        activeScopeKeys.removeAll()
        migratedProviders.removeAll()
        scanCooldownUntil.removeAll()
        dispatchedScans.removeAll()
        scopeGenerations.removeAll()
        scannedAnchors.removeAll()
        scansInFlight.removeAll()
        scanStartedAt.removeAll()
        // Also rewind the waiting budget — see the note on `init(launchedAt:)`.
        // Prefer `makeForTesting()` over resetting `.shared`.
        launchedAt = Date()
    }

    #if DEBUG
    func setBootstrapForTesting(provider: String, result: WeeklyQuotaBootstrapResult?) {
        lock.lock(); defer { lock.unlock() }
        bootstraps[provider] = result
        if let result, (bestBootstraps[provider]?.usedPercentPoints ?? 0) <= result.usedPercentPoints {
            bestBootstraps[provider] = result
        }
    }

    func setBestBootstrapForTesting(provider: String, result: WeeklyQuotaBootstrapResult) {
        lock.lock(); defer { lock.unlock() }
        bestBootstraps[provider] = result
    }

    /// Whether a rescan was DISPATCHED for this provider. Distinct from
    /// `scanSucceededForTesting`: a dispatched scan may still fail, and the whole
    /// point of the cooldown is that failure stays retryable.
    func scanWasDispatchedForTesting(provider: String) -> Bool {
        scanDispatchCountForTesting(provider: provider) > 0
    }

    /// How many scans have been dispatched. A provider-level Boolean cannot tell a
    /// retry from the first attempt, so a "still retryable" assertion against one
    /// passes even when no second scan happened.
    func scanDispatchCountForTesting(provider: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return dispatchedScans[provider] ?? 0
    }

    /// Whether a scan for this provider completed with a usable result.
    func scanSucceededForTesting(provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scannedAnchors.contains { $0.hasPrefix("\(provider)|") }
    }

    /// True while a failed scan is backing off. A blocked retry here is a bug when
    /// the cooldown has elapsed.
    func scanIsCoolingDownForTesting(provider: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scanCooldownUntil[provider].map { now < $0 } ?? false
    }

    func scanIsInFlightForTesting(provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return scansInFlight.contains(provider)
    }

    func clearScanCooldownForTesting(provider: String) {
        lock.lock(); defer { lock.unlock() }
        scanCooldownUntil[provider] = nil
    }

    func recordUsedPercentForTesting(provider: String,
                                     usedPercentPoints: Double,
                                     resetsAt: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        latestUsedPercentPoints[provider] = usedPercentPoints
        if let resetsAt { latestResetsAt[provider] = resetsAt }
    }
    #endif
}

/// Synchronous, cached read of the Codex account id for calibration scoping.
///
/// `CodexOAuthCredentials` is an actor and the usage-poll callback that needs this
/// is synchronous, so this reads the same file directly rather than forcing the
/// whole status path async. Only the account id is read, and only its hash is ever
/// stored — see `WeeklyQuotaCalibrationScope.hashAccount`.
enum CodexCalibrationAccountScope {
    private static let lock = NSLock()
    private static var cached: String?
    private static var readAt: Date = .distantPast
    private static let ttl: TimeInterval = 10 * 60

    static func accountId(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        if now.timeIntervalSince(readAt) < ttl { return cached }
        readAt = now
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cached = nil
            return nil
        }
        let tokens = json["tokens"] as? [String: Any]
        cached = (json["account_id"] as? String) ?? (tokens?["account_id"] as? String)
        return cached
    }
}
