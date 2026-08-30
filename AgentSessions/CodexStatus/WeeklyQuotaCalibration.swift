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

/// One already-incremental usage record. Claude reports `message.usage` per call
/// rather than as a running total, so its activity arrives as events instead of
/// cumulative counters.
struct WeeklyQuotaTokenEvent: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let input: Double
    let cachedInput: Double
    let output: Double
    let cacheCreation: Double
    let modelSlug: String?
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

    /// Bank already-incremental usage records (Claude's `message.usage` is per-call,
    /// not a running total, so there is no delta to take). Deduplicated by
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

            let volume = event.input + event.cachedInput + event.output + event.cacheCreation
            guard volume > 0 else { continue }
            guard let price = priceTable.price(forModel: event.modelSlug) else {
                hadUnpriced = true
                continue
            }
            dollars += event.input * price.inputPerMTok / 1_000_000
                + event.cachedInput * price.cachedInputPerMTok / 1_000_000
                + event.output * price.outputPerMTok / 1_000_000
                + event.cacheCreation * (price.cacheWritePerMTok ?? price.inputPerMTok) / 1_000_000
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
    static let retainedCount = 5
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

    /// Median pp-per-dollar across the retained set — one contaminated tick cannot
    /// move it. `nil` until something has been accepted.
    func percentPointsPerDollar(now: Date) -> Double? {
        let fresh = accepted.filter { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge }
        guard !fresh.isEmpty else { return nil }
        let sorted = fresh.map(\.percentPointsPerDollar).sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
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

        accepted.append(calibration)
        accepted = accepted
            .filter { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge }
            .suffix(Self.retainedCount)
            .map { $0 }
        anchor = Anchor(remainingPercent: remainingPercent, observedAt: observedAt, resetAt: resetAt)
        return calibration
    }

    // MARK: - Persistence
    //
    // Only a scoped calibration is ever written. An unscoped one (Claude, which
    // exposes no account identity) stays in memory for the life of the process, so
    // it cannot survive a possible account switch.

    private struct Payload: Codable {
        let scope: WeeklyQuotaCalibrationScope
        let accepted: [WeeklyQuotaCalibration]
    }

    func persistedData() -> Data? {
        guard let scope, scope.isPersistable, !accepted.isEmpty else { return nil }
        return try? JSONEncoder().encode(Payload(scope: scope, accepted: accepted))
    }

    mutating func restore(from data: Data, scope expected: WeeklyQuotaCalibrationScope, now: Date) {
        guard expected.isPersistable,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.scope == expected else { return }
        scope = expected
        firstObservedAt = nil
        accepted = payload.accepted
            .filter { now.timeIntervalSince($0.acquiredAt) <= Self.maximumAge }
            .suffix(Self.retainedCount)
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

    /// `launchedAt` is injectable because it is wall-clock state on a singleton,
    /// which is a trap for tests: `.shared` is constructed the first time ANY test
    /// touches it, so a later test inherits an already-expired waiting budget and
    /// sees "abandoned" before it has waited at all — passing in isolation and
    /// failing in the suite. Tests should use `makeForTesting()` and get a clean
    /// store by construction rather than remembering to reset a shared one.
    init(launchedAt: Date = Date()) {
        self.launchedAt = launchedAt
    }

#if DEBUG
    /// A private store with its own clock and no shared state. Mirrors
    /// `RunwayPriceTable.makeForTesting()`. Pair it with a scratch `UserDefaults`
    /// suite so persistence assertions never touch the real domain.
    static func makeForTesting(launchedAt: Date = Date()) -> WeeklyQuotaCalibrationStore {
        WeeklyQuotaCalibrationStore(launchedAt: launchedAt)
    }
#endif

    private let lock = NSLock()
    private var ledgers: [String: WeeklyQuotaActivityLedger] = [:]
    private var trackers: [String: WeeklyQuotaCalibrationTracker] = [:]
    private var restored: Set<String> = []
    /// Historical calibration computed from transcripts at launch — the reason
    /// `Wk` shows a number in seconds instead of waiting hours for a 1pp tick.
    private var bootstraps: [String: WeeklyQuotaBootstrapResult] = [:]
    /// Latest weekly consumption seen per provider, so a stored bootstrap's
    /// numerator can be kept current without rescanning.
    private var latestUsedPercentPoints: [String: Double] = [:]
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
    private static func bestBootstrapKey(provider: String, accountHash: String?) -> String {
        "quotaMeter.weeklyBootstrapBest.\(provider).\(accountHash ?? "unscoped")"
    }

    /// Re-scan once the window has consumed this much more than the stored
    /// bootstrap measured. Integer quantization means a ratio learned at 1pp can
    /// be ~50% off while the same window at 10pp is ~5% off, so a frozen early
    /// reading is a real accuracy bug, not just staleness.
    static let bootstrapRefreshGrowthPercentPoints: Double = 3

    func ledger(provider: String) -> WeeklyQuotaActivityLedger {
        lock.lock(); defer { lock.unlock() }
        if let existing = ledgers[provider] { return existing }
        let created = WeeklyQuotaActivityLedger()
        ledgers[provider] = created
        return created
    }

    /// Conversion for this provider, or nil while uncalibrated.
    ///
    /// Order matters. Two or more accepted live ticks beat the bootstrap: they
    /// median out, and the tracker rejects intervals with no local activity, so
    /// they are structurally clean of another device's usage in a way a historical
    /// scan can never be. But ONE tick does not — a single 1pp reading carries up
    /// to ±50% quantization error, while a bootstrap over 20pp carries ~±2.5%.
    func percentPointsPerDollar(provider: String, now: Date) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let tracker = trackers[provider]
        if (tracker?.acceptedCount ?? 0) >= 2, let live = tracker?.percentPointsPerDollar(now: now) {
            return live
        }
        if let bootstrap = bestConditionedBootstrap(provider: provider) {
            return freshenedBootstrapRatio(provider: provider, bootstrap: bootstrap, now: now)
                ?? bootstrap.percentPointsPerDollar
        }
        return tracker?.percentPointsPerDollar(now: now)
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
        // Midpoint, not the reported floor. A provider reporting "2" means true
        // consumption is somewhere in [2, 3); taking 2 biases every estimate low,
        // and the bias is worst exactly where the numerator is smallest.
        let used = reported + 0.5
        guard now.timeIntervalSince(bootstrap.scannedAt) <= WeeklyQuotaActivityLedger.retention else { return nil }
        guard let ledger = ledgers[provider],
              let since = ledger.activity(from: bootstrap.scannedAt, to: now) else { return nil }
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
    private func bestConditionedBootstrap(provider: String) -> WeeklyQuotaBootstrapResult? {
        let current = bootstraps[provider]
        guard let best = bestBootstraps[provider] else { return current }
        guard let current else { return best }
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
        if bestConditionedBootstrap(provider: provider)?.percentPointsPerDollar != nil { return false }
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

    /// Compute the historical calibration for the current weekly window, once per
    /// anchor, off the main thread. Safe to call on every usage poll.
    func ensureBootstrap(provider: String,
                         root: URL,
                         resetsAt: Date,
                         windowMinutes: Int,
                         usedPercentPoints: Double,
                         accountHash: String? = nil,
                         now: Date = Date(),
                         defaults: UserDefaults = .standard) {
        let storeKey = Self.bootstrapKey(provider: provider, accountHash: accountHash, resetsAt: resetsAt)
        let bestKey = Self.bestBootstrapKey(provider: provider, accountHash: accountHash)
        var promoted: WeeklyQuotaBootstrapResult?
        lock.lock()
        latestUsedPercentPoints[provider] = usedPercentPoints
        // Restore the carried-over measurement once per process. Without this the
        // cross-reset carry only works while the app keeps running.
        if bestBootstraps[provider] == nil,
           let data = defaults.data(forKey: bestKey),
           let cached = try? JSONDecoder().decode(WeeklyQuotaBootstrapResult.self, from: data),
           cached.percentPointsPerDollar != nil {
            bestBootstraps[provider] = cached
        }
        lock.unlock()

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
           cached.percentPointsPerDollar != nil {
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
        lock.unlock()
        if let promoted, let encoded = try? JSONEncoder().encode(promoted) {
            defaults.set(encoded, forKey: bestKey)
        }

        // Re-scan when the window has moved on enough that the stored ratio is
        // materially less accurate than a fresh one would be.
        let anchorKey = "\(provider)|\(Int(resetsAt.timeIntervalSince1970))|\(Int(usedPercentPoints / Self.bootstrapRefreshGrowthPercentPoints))"
        let staleEnough = stored.map {
            usedPercentPoints - $0.usedPercentPoints >= Self.bootstrapRefreshGrowthPercentPoints
        } ?? true
        guard staleEnough else { return }

        lock.lock()
        let alreadyHandled = scannedAnchors.contains(anchorKey) || scansInFlight.contains(provider)
        if !alreadyHandled { scannedAnchors.insert(anchorKey) }
        lock.unlock()
        guard !alreadyHandled else { return }
        lock.lock()
        scansInFlight.insert(provider)
        scanStartedAt[provider] = now
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            defer {
                self.lock.lock()
                self.scansInFlight.remove(provider)
                self.scanStartedAt[provider] = nil
                self.lock.unlock()
            }
            // Same ratio, different transcript shape per provider: Codex counters
            // are cumulative and carry a quota anchor; Claude's are per-call and
            // carry none.
            let scan = provider == "claude"
                ? ClaudeWeeklyQuotaBootstrapScanner.scan
                : CodexWeeklyQuotaBootstrapScanner.scan
            guard let result = scan(
                root,
                resetsAt,
                windowMinutes,
                usedPercentPoints,
                RunwayPriceTable.shared,
                now,
                FileManager.default
            ) else { return }
            // A week can contain one slug the price table has never seen without
            // meaningfully moving the ratio; a large unknown share cannot.
            guard result.unpricedVolumeShare <= CodexWeeklyQuotaBootstrapScanner.maximumUnpricedShare,
                  result.percentPointsPerDollar != nil else { return }
            self.lock.lock()
            self.bootstraps[provider] = result
            let isBest = (self.bestBootstraps[provider]?.usedPercentPoints ?? 0) <= result.usedPercentPoints
            if isBest { self.bestBootstraps[provider] = result }
            self.lock.unlock()
            if isBest, let encoded = try? JSONEncoder().encode(result) {
                defaults.set(encoded, forKey: bestKey)
            }
            if let encoded = try? JSONEncoder().encode(result) {
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

    func recordUsedPercentForTesting(provider: String, usedPercentPoints: Double) {
        lock.lock(); defer { lock.unlock() }
        latestUsedPercentPoints[provider] = usedPercentPoints
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
