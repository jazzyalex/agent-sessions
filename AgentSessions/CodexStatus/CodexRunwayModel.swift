import Foundation

/// A file's cheap identity for cache invalidation: its content-modification date
/// and byte size. Two reads of the same path with an unchanged `(mtime, size)`
/// are treated as identical bytes, so an expensive head/tail parse can be reused.
struct RunwayFileSignature: Equatable, Sendable {
    let mtime: TimeInterval
    let size: UInt64

    /// Cheap stat (no file open) via URL resource values. Returns nil when the
    /// file is missing or unstat-able — callers then bypass the cache and read
    /// directly, so a stat failure never serves stale data.
    static func read(path: String) -> RunwayFileSignature? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate else {
            return nil
        }
        return RunwayFileSignature(mtime: mtime.timeIntervalSinceReferenceDate,
                                   size: UInt64(values.fileSize ?? 0))
    }

    init(mtime: TimeInterval, size: UInt64) {
        self.mtime = mtime
        self.size = size
    }

    init(mtime: Date, size: UInt64) {
        self.init(mtime: mtime.timeIntervalSinceReferenceDate, size: size)
    }
}

/// Thread-safe cache of an expensive per-file parse, keyed by the file's
/// `(path, contentModificationDate, size)`. The runway surfaces re-scan every 5s;
/// an unchanged file (same mtime+size) reuses its cached parse instead of
/// re-reading and re-parsing head/tail bytes.
///
/// IMPORTANT: only the *time-independent* artifact of the bytes belongs here
/// (parsed samples, metadata, raw timestamped lines). Time-dependent aggregation
/// — staleness/active windows, burn-rate spans relative to `now` — must be
/// recomputed by the caller each cycle from the cached artifact, so state still
/// advances as `now` moves with the disk unchanged.
final class RunwayFileParseCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (signature: RunwayFileSignature, value: Value)] = [:]

    #if DEBUG
    /// Counts `parse` invocations (cache misses). Tests assert this does not
    /// advance on a second scan of unchanged files.
    private(set) var missCount = 0
    #endif

    /// Cached value for `path` when its signature is unchanged; otherwise runs
    /// `parse`, stores, and returns it. `signature` comes from the caller's
    /// existing stat pass so the hot path issues no extra stat.
    func value(path: String, signature: RunwayFileSignature, parse: () -> Value) -> Value {
        lock.lock()
        if let entry = entries[path], entry.signature == signature {
            let value = entry.value
            lock.unlock()
            return value
        }
        lock.unlock()
        // Parse outside the lock — file IO must not serialize the whole cache.
        // A concurrent miss on the same path simply parses twice and stores the
        // same value (last writer wins); the artifact is a pure function of bytes.
        let value = parse()
        lock.lock()
        entries[path] = (signature, value)
        #if DEBUG
        missCount += 1
        #endif
        lock.unlock()
        return value
    }

    /// Drops entries whose path is not in `paths`. Called once per scan cycle
    /// with the small in-window file set so the cache can't grow unbounded.
    func retain(paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { paths.contains($0.key) }
    }

    #if DEBUG
    func removeAllForTesting() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        missCount = 0
    }
    #endif
}

enum RunwayAttributionConfidence: Equatable, Sendable {
    case direct
    case mixed
    case waiting       // active/working but no burn measured yet → spinner
    case idle          // finished its turn (handed back to user) → calm "—"
    case unsupported
    /// Runs on Anthropic's infrastructure, so no local transcript exists and no burn
    /// can ever be measured for it. Renders the literal "Cloud" instead of a rate —
    /// deliberately NOT `.idle`, which would short-circuit to the calm dash and lose
    /// the distinction between "finished its turn" and "rate is unknowable".
    case cloud
}

enum RunwayDeadline: Equatable, Sendable {
    case afterReset
    case runout(Date)
    case noChange
    case unavailable
}

/// Unit a runway row's rate is expressed in. The 5h window uses the normalized
/// quota-minutes-per-hour yardstick (60 m/h = sustainable-for-5h). When the 5h
/// window is dropped there is no 5h budget to normalize against, so Codex rows
/// fall back to raw token throughput (window-independent, honest) rather than a
/// fabricated m/h that would read on a different scale than Claude's 5h rows.
enum RunwayRateUnit: Equatable, Sendable {
    case quotaMinutesPerHour
    case tokensPerHour
    /// Per-session share of the most recent measured weekly quota tick, expressed
    /// as % of the weekly window per hour.
    case weeklyPercentPerHour
    /// Per-session API-equivalent cost per hour (tokens × per-model prices). Used
    /// by the "$" presentation; falls back to token when no price table is usable.
    case dollarsPerHour
}

struct RunwayProviderBaseline: Equatable, Sendable {
    let source: UsageTrackingSource
    let remainingPercent: Double
    let resetAt: Date
    let currentRunoutAt: Date
    let observedAt: Date
    let hasProjectedRunout: Bool
    /// Length of the window this baseline represents (300 = 5h, 10080 = weekly).
    /// Scales the absolute m/h yardstick so the same real burn reads the same
    /// whether it draws down the 5h or the weekly window. Defaults to the 5h
    /// window, leaving every existing caller (incl. Claude) unchanged.
    let windowMinutes: Int
    /// Unit the runway rows report their rate in. Defaults to the m/h yardstick;
    /// the Codex builder switches to `.tokensPerHour` while the 5h window is
    /// dropped so "m/h" never means two different things across providers.
    let rateUnit: RunwayRateUnit

    init(source: UsageTrackingSource,
         remainingPercent: Double,
         resetAt: Date,
         currentRunoutAt: Date,
         observedAt: Date,
         hasProjectedRunout: Bool = true,
         windowMinutes: Int = 300,
         rateUnit: RunwayRateUnit? = nil) {
        self.source = source
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.currentRunoutAt = currentRunoutAt
        self.observedAt = observedAt
        self.hasProjectedRunout = hasProjectedRunout
        self.windowMinutes = windowMinutes
        // Default the unit from the window length: a long (weekly) window has no 5h
        // budget to normalize against, so it reads in tk/h; a short window uses the
        // m/h yardstick. Deriving it here means a caller that sets a long window but
        // forgets `rateUnit` can't silently render weekly-scaled m/h (the 33.6×
        // mismatch this fix removes). Explicit callers still override (e.g. a future
        // token-mode presentation on the 5h window).
        self.rateUnit = rateUnit
            ?? (windowMinutes >= CodexRateLimitWindowClassifier.shortLongSplitMinutes ? .tokensPerHour : .quotaMinutesPerHour)
    }

    /// A copy with a different rate unit — used for snapshot-wide fallback (e.g.
    /// weekly → token while a recent quota tick is unavailable) so the whole
    /// snapshot stays single-unit.
    func with(rateUnit newUnit: RunwayRateUnit) -> RunwayProviderBaseline {
        RunwayProviderBaseline(source: source, remainingPercent: remainingPercent, resetAt: resetAt,
                               currentRunoutAt: currentRunoutAt, observedAt: observedAt,
                               hasProjectedRunout: hasProjectedRunout, windowMinutes: windowMinutes,
                               rateUnit: newUnit)
    }
}

/// Baseline math shared by the runway request builders.
enum RunwayBaselineMath {
    /// The 5-hour rolling window length used by the "5h" limit.
    static let fiveHourWindow: TimeInterval = 5 * 3600

    /// Floor for elapsed time. A heavy burst in the first minutes after a reset
    /// (e.g. a workflow fanning out many agents) could otherwise divide by a
    /// tiny elapsed and re-introduce small-denominator inflation on the
    /// early-window side — the symmetric twin of the near-reset bug this fix
    /// removes. 10 min over a 5h window is light smoothing that only binds early.
    static let minimumElapsed: TimeInterval = 10 * 60

    /// Even-burn run-out derived from *average usage so far this window*, for
    /// providers that lack a fresh per-account projection (Claude).
    ///
    /// The naive fallback — pinning run-out to the reset time — makes the
    /// implied burn rate `remaining / timeToReset` explode as the reset
    /// approaches (denominator → 0), producing absurd per-session "m/h".
    /// Anchoring run-out to the measured average instead (`used% / elapsed`)
    /// gives `providerRate == averageRate`, which never blows up near reset.
    /// `elapsed` is floored by `minimumElapsed` so the early-window side can't
    /// inflate the same way.
    ///
    /// Returns `nil` when no burn is measurable yet (`used <= 0`) or the
    /// window start is in the future; callers fall back to the reset time.
    static func averageBurnRunout(remainingPercent: Double,
                                  resetAt: Date,
                                  windowLength: TimeInterval,
                                  now: Date) -> Date? {
        let usedPercent = 100 - remainingPercent
        guard usedPercent > 0, remainingPercent > 0 else { return nil }
        let windowStart = resetAt.addingTimeInterval(-windowLength)
        let rawElapsed = now.timeIntervalSince(windowStart)
        guard rawElapsed > 0 else { return nil }
        // Floor elapsed so an early-window burst can't divide by a tiny denominator
        // and project an absurd run-out. Scale the floor to the window (1/30 of its
        // length) so a long window smooths over hours, not the 5h-tuned 10 min; for
        // the 5h window `windowLength/30 == 600s`, so this is unchanged there.
        let elapsed = max(rawElapsed, max(minimumElapsed, windowLength / 30))
        let averageRatePerSecond = usedPercent / elapsed
        guard averageRatePerSecond > 0, averageRatePerSecond.isFinite else { return nil }
        let secondsToRunout = remainingPercent / averageRatePerSecond
        guard secondsToRunout.isFinite, secondsToRunout > 0 else { return nil }
        return now.addingTimeInterval(secondsToRunout)
    }
}

struct RunwaySessionIdentity: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isGoal: Bool
    let logPaths: [String]
    /// The session finished its turn and handed back to the user (not working).
    /// Default false = "working/unknown" so non-Claude sources keep prior behavior.
    var isIdle: Bool = false
}

struct CodexRunwayRateLimitSample: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let remainingPercent: Double
    let resetAt: Date
}

struct CodexRunwayTokenActivitySample: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let totalTokens: Double
    var input: Double = 0
    var cachedInput: Double = 0
    var output: Double = 0
    var modelSlug: String? = nil
}

/// One model's slice of a session's token rate, in the same normalized per-type
/// shape as `RunwaySessionActivity`.
///
/// A session routinely burns SEVERAL models at once: a session's subagent
/// transcripts fold into the parent identity as extra log paths (see the recent-
/// session scanners), and an orchestrator on one model commonly drives subagents on
/// a cheaper one. Summing all their tokens and pricing the total at any single model
/// misprices every other slice — biased toward whichever path sorts first, which is
/// always the parent. `$` therefore prices each slice at its own model and sums.
///
/// A slice is also scoped to one BILLING TIER, for the same reason it is scoped to
/// one model: Claude's fast mode charges double, and a burst can straddle a switch.
struct RunwayModelComponent: Equatable, Sendable {
    let modelSlug: String?
    let inputPerSecond: Double        // FRESH (non-cached) input
    let cachedInputPerSecond: Double
    let outputPerSecond: Double
    /// Cache writes billed at the base 5-minute-TTL rate (1.25× input). Codex's
    /// single write tier lands here too — it has no TTL split.
    let cacheCreationPerSecond: Double
    /// Cache writes billed at the 1-hour-TTL rate (2× input). Claude only; a Claude
    /// record splits its total across this and the field above via
    /// `usage.cache_creation`. Always 0 for Codex.
    let cacheCreation1hPerSecond: Double
    /// Billing tier this slice was served at, taken from the record's `usage.speed`.
    let speed: RunwaySpeedTier
    /// Total input tokens in this request. Some providers switch the entire
    /// request to a higher price tier above a context threshold.
    let contextInputTokens: Double?

    init(modelSlug: String?,
         inputPerSecond: Double,
         cachedInputPerSecond: Double,
         outputPerSecond: Double,
         cacheCreationPerSecond: Double,
         cacheCreation1hPerSecond: Double = 0,
         speed: RunwaySpeedTier = .standard,
         contextInputTokens: Double? = nil) {
        self.modelSlug = modelSlug
        self.inputPerSecond = inputPerSecond
        self.cachedInputPerSecond = cachedInputPerSecond
        self.outputPerSecond = outputPerSecond
        self.cacheCreationPerSecond = cacheCreationPerSecond
        self.cacheCreation1hPerSecond = cacheCreation1hPerSecond
        self.speed = speed
        self.contextInputTokens = contextInputTokens
    }

    var totalPerSecond: Double {
        inputPerSecond + cachedInputPerSecond + outputPerSecond
            + cacheCreationPerSecond + cacheCreation1hPerSecond
    }
}

struct RunwaySessionActivity: Equatable, Sendable {
    let identity: RunwaySessionIdentity
    /// Netted throughput (drives tk/h) — unchanged from Phase 1.
    let tokensPerSecond: Double
    let sampleStart: Date
    let sampleEnd: Date
    /// Per-model slices — the SINGLE source of truth for rates. `$` prices each at
    /// its own model; the totals below are derived from these at init, so tk/h and
    /// `$` can never end up describing different token volumes. There is
    /// deliberately no session-level `modelSlug`: a session can burn several models
    /// at once, and any single "representative" slug invites pricing the totals with
    /// it — which is exactly the parent-biased blend this type exists to prevent.
    let components: [RunwayModelComponent]
    /// Session totals across every model, normalized to ONE shape across providers
    /// so pricing needs no subtraction: `inputPerSecond` is FRESH (non-cached)
    /// input; `cachedInputPerSecond` is cached-input reads; `cacheCreationPerSecond`
    /// and `cacheCreation1hPerSecond` are Claude cache writes at the 5-minute and
    /// 1-hour rates (both 0 for Codex). Derived — never set directly.
    ///
    /// There is deliberately no session-level `speed`, for the same reason there is
    /// no session-level `modelSlug`: a burst can straddle a tier switch, and one
    /// "representative" tier would misprice the half that ran at the other.
    let inputPerSecond: Double
    let cachedInputPerSecond: Double
    let outputPerSecond: Double
    let cacheCreationPerSecond: Double
    let cacheCreation1hPerSecond: Double

    init(identity: RunwaySessionIdentity,
         tokensPerSecond: Double,
         sampleStart: Date,
         sampleEnd: Date,
         components: [RunwayModelComponent]) {
        self.identity = identity
        self.tokensPerSecond = tokensPerSecond
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.components = components
        self.inputPerSecond = components.reduce(0) { $0 + $1.inputPerSecond }
        self.cachedInputPerSecond = components.reduce(0) { $0 + $1.cachedInputPerSecond }
        self.outputPerSecond = components.reduce(0) { $0 + $1.outputPerSecond }
        self.cacheCreationPerSecond = components.reduce(0) { $0 + $1.cacheCreationPerSecond }
        self.cacheCreation1hPerSecond = components.reduce(0) { $0 + $1.cacheCreation1hPerSecond }
    }

    /// Single-model convenience — one transcript on one model, the common case.
    init(identity: RunwaySessionIdentity,
         tokensPerSecond: Double,
         sampleStart: Date,
         sampleEnd: Date,
         inputPerSecond: Double = 0,
         cachedInputPerSecond: Double = 0,
         outputPerSecond: Double = 0,
         cacheCreationPerSecond: Double = 0,
         cacheCreation1hPerSecond: Double = 0,
         modelSlug: String? = nil,
         speed: RunwaySpeedTier = .standard,
         contextInputTokens: Double? = nil) {
        self.init(identity: identity,
                  tokensPerSecond: tokensPerSecond,
                  sampleStart: sampleStart,
                  sampleEnd: sampleEnd,
                  components: [RunwayModelComponent(modelSlug: modelSlug,
                                                    inputPerSecond: inputPerSecond,
                                                    cachedInputPerSecond: cachedInputPerSecond,
                                                    outputPerSecond: outputPerSecond,
                                                    cacheCreationPerSecond: cacheCreationPerSecond,
                                                    cacheCreation1hPerSecond: cacheCreation1hPerSecond,
                                                    speed: speed,
                                                    contextInputTokens: contextInputTokens)])
    }
}

struct RunwaySessionBurn: Equatable, Sendable {
    let identity: RunwaySessionIdentity
    let percentPerSecond: Double
    let confidence: RunwayAttributionConfidence
    let sampleStart: Date
    let sampleEnd: Date
}

struct RunwayPauseImpactRow: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isGoal: Bool
    let deadline: RunwayDeadline
    let gainedSeconds: TimeInterval
    let displayRate: Double
    let confidence: RunwayAttributionConfidence
}

struct RunwayShortBurstSummary: Equatable, Sendable {
    let count: Int
    let deadline: RunwayDeadline
    let gainedSeconds: TimeInterval
    let displayRate: Double
}

struct CodexRunwaySnapshot: Equatable, Sendable {
    let baseline: RunwayProviderBaseline
    let rows: [RunwayPauseImpactRow]
    let burstSummary: RunwayShortBurstSummary?
    /// Aggregate token throughput (tokens/hour) across active sessions this cycle.
    /// Drives the honest "burning" indicator on a limit line that has no run-out to
    /// show — e.g. the 5h line while the 5h window is dropped (a run-out time there
    /// would be a lie). nil when nothing is actively burning.
    var aggregateTokensPerHour: Double? = nil
}

struct CodexRunwaySnapshotRequest: Equatable, Identifiable, Sendable {
    let baseline: RunwayProviderBaseline
    let identities: [RunwaySessionIdentity]
    let now: Date
    let maxRows: Int
    let recentSessionsRoot: URL?
    /// Learned pp-per-API-dollar conversion for `Wk`. nil = not calibrated yet, so
    /// weekly rows wait on the clock rather than inventing a number.
    let weeklyPercentPointsPerDollar: Double?
    /// False when the provider exposes no weekly limit at all — weekly rows then
    /// read "n/a" instead of waiting for a calibration that can never arrive.
    let weeklyWindowAvailable: Bool
    /// True once we have watched long enough that a calibration is evidently not
    /// coming. Stops the waiting clock from spinning indefinitely.
    let weeklyCalibrationAbandoned: Bool

    init(baseline: RunwayProviderBaseline,
         identities: [RunwaySessionIdentity],
         now: Date,
         maxRows: Int,
         recentSessionsRoot: URL? = nil,
         weeklyPercentPointsPerDollar: Double? = nil,
         weeklyWindowAvailable: Bool = true,
         weeklyCalibrationAbandoned: Bool = false) {
        self.baseline = baseline
        self.identities = identities
        self.now = now
        self.maxRows = maxRows
        self.recentSessionsRoot = recentSessionsRoot
        self.weeklyPercentPointsPerDollar = weeklyPercentPointsPerDollar
        self.weeklyWindowAvailable = weeklyWindowAvailable
        self.weeklyCalibrationAbandoned = weeklyCalibrationAbandoned
    }

    var id: String {
        let identityKey = identities.map {
            "\($0.id)|\($0.displayName)|\($0.isGoal ? "goal" : "session")|\($0.logPaths.joined(separator: ","))"
        }
        .joined(separator: ";")
        let refreshBucket = Int(now.timeIntervalSince1970 / 5)
        return [
            "\(baseline.source)",
            "\(baseline.rateUnit)",
            String(format: "%.3f", baseline.remainingPercent),
            baseline.resetAt.timeIntervalSinceReferenceDate.description,
            baseline.currentRunoutAt.timeIntervalSinceReferenceDate.description,
            baseline.observedAt.timeIntervalSinceReferenceDate.description,
            "\(maxRows)",
            recentSessionsRoot?.path ?? "",
            "\(refreshBucket)",
            weeklyPercentPointsPerDollar.map { String(format: "%.6f", $0) } ?? "uncalibrated",
            weeklyWindowAvailable ? "wk" : "nowk",
            weeklyCalibrationAbandoned ? "abandoned" : "learning",
            identityKey
        ].joined(separator: "||")
    }
}

/// Thread-safe hold for the aggregate token-throughput "burning" chip. Token
/// activity only registers when the newest `total_tokens` sample is within
/// `maximumSampleAge` (75s); a longer gap in output makes a cycle's aggregate
/// read zero, so without a hold the chip blinks out and back on the 5s refresh.
/// Pure TTL: the last positive rate is held for up to `window` seconds after the
/// last measured sample, then self-clears. So a transient cycle with no samples
/// can't blank the chip mid-burst, and the rate persists at most `window`s after
/// output truly stops. `@unchecked Sendable` mirrors the sibling
/// `RunwayFileParseCache` — a lock-guarded static touched from the loader's
/// `DispatchQueue.global` closures.
final class RunwayAggregateBurnHold: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPositive: [String: (rate: Double, at: Date)] = [:]

    func resolve(key: String,
                 freshTokensPerSecond: Double,
                 window: TimeInterval,
                 now: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if freshTokensPerSecond > 0 {
            lastPositive[key] = (freshTokensPerSecond, now)
            return freshTokensPerSecond
        }
        // No fresh burn this cycle: hold the last positive rate until the TTL
        // elapses. `max(0, …)` guards sub-second clock skew between the two view
        // loaders that share this hold; prune only once genuinely expired so a
        // transient empty cycle can't clear a still-valid hold.
        guard let last = lastPositive[key] else { return 0 }
        if max(0, now.timeIntervalSince(last.at)) > window {
            lastPositive.removeValue(forKey: key)
            return 0
        }
        return last.rate
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        lastPositive.removeAll()
    }
    #endif
}

enum CodexRunwaySnapshotLoader {
    /// Bridges brief gaps in token output so the "burning" chip stays steady
    /// instead of flickering with the 5s refresh (see `RunwayAggregateBurnHold`).
    static let burnHold = RunwayAggregateBurnHold()
    static let burnHoldWindow: TimeInterval = 120

    /// Explicit per-provider hold key so a future Claude adoption of this loader
    /// can't collide with Codex's held rate under a shared constant.
    private static func burnHoldKey(for request: CodexRunwaySnapshotRequest) -> String {
        "\(request.baseline.source)|\(request.recentSessionsRoot?.path ?? "")"
    }

    static func snapshot(for request: CodexRunwaySnapshotRequest) async -> CodexRunwaySnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let scannerRetention = request.baseline.rateUnit == .weeklyPercentPerHour
                    ? CodexRunwayTokenActivityParser.weeklyWindow
                    : CodexRunwayRecentSessionScanner.maximumActiveSampleAge
                let scannerIdentities = CodexRunwayRecentSessionScanner.identities(
                    root: request.recentSessionsRoot,
                    now: request.now,
                    activeSampleAge: scannerRetention,
                    completionGrace: scannerRetention
                )
                let identities = RunwaySnapshotAssembly.uniqueIdentities(request.identities + scannerIdentities)
                // Once-per-cycle prune: keep only the small in-window path set so
                // the per-parser sample caches track active sessions, not history.
                let activePaths = Set(identities.flatMap { $0.logPaths })
                CodexRunwayRateLimitParser.retainCache(paths: activePaths)
                CodexRunwayTokenActivityParser.retainCache(paths: activePaths)
                // Parse each session's token activity once; both the per-session
                // rows/burns and the aggregate throughput derive from it.
                let activities = CodexRunwayTokenActivityParser.activities(
                    identities: identities,
                    now: request.now
                )
                let weeklyProfile = request.baseline.rateUnit == .weeklyPercentPerHour
                    ? CodexRunwayTokenActivityParser.weeklyProfile(
                        identities: identities,
                        now: request.now
                    )
                    : (activities: [], measuringIDs: Set<String>())
                // Bank this cycle's priced activity for weekly calibration. Done on
                // EVERY cycle regardless of the selected unit: the ledger's bucket
                // timeline is also the poll-continuity record, so skipping cycles
                // while the user is on 5h would make the next weekly interval look
                // like a sleep gap and be rejected.
                WeeklyQuotaCalibrationStore.shared.ledger(provider: "codex").recordIncremental(
                    events: CodexRunwayTokenActivityParser.ledgerEvents(
                        identities: identities,
                        now: request.now
                    ),
                    priceTable: RunwayPriceTable.shared,
                    now: request.now
                )
                let core: CodexRunwaySnapshot?
                // The rendered unit comes from the snapshot's baseline; on a
                // snapshot-wide fallback we swap it so rows never mislabel.
                var effectiveBaseline = request.baseline
                // Identities eligible for a pending row. $ mode narrows this to the
                // ones it can actually price (see .dollarsPerHour below).
                var pendingIdentities = identities
                // Weekly-only: sessions that can never be estimated in this unit and
                // must read "n/a" rather than sit on a waiting clock forever.
                var weeklyUnavailableIDs: Set<String> = []
                // With a calibration in hand, "no current burn" is a measured zero
                // ("flat"), not an unanswered question (the clock).
                let weeklyPendingConfidence: RunwayAttributionConfidence =
                    (request.baseline.rateUnit == .weeklyPercentPerHour
                     && request.weeklyPercentPointsPerDollar != nil) ? .direct : .waiting
                switch request.baseline.rateUnit {
                case .tokensPerHour:
                    // 5h window dropped → no run-out to normalize against, so rows
                    // show raw per-session token throughput (tk/h) directly from
                    // activity. The coarse weekly %-burns (integer 1% ticks) are
                    // deliberately not used here — they can't express a sane rate.
                    core = CodexRunwayCalculator.tokenSnapshot(
                        baseline: request.baseline,
                        activities: activities,
                        maxRows: request.maxRows
                    )
                case .dollarsPerHour:
                    // Lazy, self-throttling (<=1/day): the price manifest is only
                    // ever fetched once someone actually uses the $ presentation.
                    RunwayPriceTable.shared.refreshInBackground(now: request.now)
                    // Per-session $/h from the price table. Sessions we can't price
                    // are dropped; only when NOTHING is priceable do we fall back to
                    // token snapshot-wide (P1) with a token baseline so rows never
                    // mislabel.
                    if let dollars = CodexRunwayCalculator.dollarSnapshot(
                        baseline: request.baseline,
                        activities: activities,
                        priceTable: RunwayPriceTable.shared,
                        maxRows: request.maxRows
                    ) {
                        core = dollars.snapshot
                        // A dropped session must not reappear as a "$0/h" pending row
                        // while it's actively burning. Idle sessions keep their "—".
                        pendingIdentities = identities.filter { !dollars.unpriceableIDs.contains($0.id) }
                    } else {
                        effectiveBaseline = request.baseline.with(rateUnit: .tokensPerHour)
                        core = CodexRunwayCalculator.tokenSnapshot(
                            baseline: effectiveBaseline,
                            activities: activities,
                            maxRows: request.maxRows
                        )
                    }
                case .weeklyPercentPerHour:
                    // Estimated per-session weekly %/h from the learned calibration.
                    // There is deliberately NO fallback to tokens here: `Wk` must
                    // never render tk/h. Without a calibration the rows stay on the
                    // waiting clock; sessions that can never be estimated get "n/a".
                    RunwayPriceTable.shared.refreshInBackground(now: request.now)
                    if !request.weeklyWindowAvailable || request.weeklyCalibrationAbandoned {
                        // No weekly limit on this provider at all, or we have waited
                        // long enough that a calibration is evidently not coming.
                        // Either way the clock would be promising a number that will
                        // not arrive, so say "n/a" instead.
                        core = nil
                        weeklyUnavailableIDs = Set(identities.map(\.id))
                    } else if let calibration = request.weeklyPercentPointsPerDollar,
                              let weekly = CodexRunwayCalculator.weeklyEstimatedSnapshot(
                                  baseline: request.baseline,
                                  activities: weeklyProfile.activities,
                                  priceTable: RunwayPriceTable.shared,
                                  percentPointsPerDollar: calibration,
                                  maxRows: request.maxRows
                              ) {
                        core = weekly.snapshot
                        weeklyUnavailableIDs = weekly.unpriceableIDs
                        pendingIdentities = identities.filter { !weekly.unpriceableIDs.contains($0.id) }
                    } else if request.weeklyPercentPointsPerDollar != nil {
                        // Calibrated, but nothing currently priceable.
                        core = nil
                        weeklyUnavailableIDs = Set(weeklyProfile.activities.map(\.identity.id))
                    } else {
                        // Not calibrated yet — every row waits on the clock.
                        core = nil
                    }
                case .quotaMinutesPerHour:
                    let directBurns = identities.compactMap {
                        CodexRunwayRateLimitParser.burn(identity: $0, now: request.now)
                    }
                    let tokenBurns = request.baseline.hasProjectedRunout
                        ? CodexRunwayTokenActivityParser.burns(
                            activities: activities,
                            baseline: request.baseline
                        )
                        : []
                    let burns = mergeBurns(directBurns: directBurns, tokenBurns: tokenBurns)
                    core = CodexRunwayCalculator.snapshot(
                        baseline: request.baseline,
                        burns: burns,
                        maxRows: request.maxRows
                    )
                }
                let withUnavailable = RunwaySnapshotAssembly.withUnavailableRows(
                    baseline: effectiveBaseline,
                    snapshot: core,
                    identities: identities,
                    unavailableIDs: weeklyUnavailableIDs,
                    maxRows: request.maxRows
                )
                var snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: effectiveBaseline,
                    snapshot: withUnavailable,
                    activeIdentities: pendingIdentities,
                    maxRows: request.maxRows,
                    pendingConfidence: weeklyPendingConfidence,
                    waitingIDs: weeklyProfile.measuringIDs
                )
                // Aggregate token throughput (fine-grained, window-independent) — an
                // honest "burning" signal for a limit line with no run-out to show.
                // Held across brief output gaps so the chip doesn't flicker with the
                // 5s refresh (a >75s pause in token output reads as zero this cycle).
                let aggregateTokensPerSecond = activities.reduce(0) { $0 + $1.tokensPerSecond }
                let stableTokensPerSecond = burnHold.resolve(
                    key: burnHoldKey(for: request),
                    freshTokensPerSecond: aggregateTokensPerSecond,
                    window: burnHoldWindow,
                    now: request.now
                )
                // Surface the "burning" chip only while the HUD still has active
                // sessions. The hold bridges output gaps mid-work (the HUD row stays
                // present), but once every session ends the chip clears with the
                // runway rows instead of lingering for the full hold window — no
                // phantom "burning" with nothing running.
                if stableTokensPerSecond > 0, !request.identities.isEmpty {
                    snapshot?.aggregateTokensPerHour = stableTokensPerSecond * 3600
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

#if DEBUG
    static func uniqueIdentitiesForTesting(_ identities: [RunwaySessionIdentity]) -> [RunwaySessionIdentity] {
        RunwaySnapshotAssembly.uniqueIdentities(identities)
    }
#endif

    private static func mergeBurns(directBurns: [RunwaySessionBurn],
                                   tokenBurns: [RunwaySessionBurn]) -> [RunwaySessionBurn] {
        guard !directBurns.isEmpty else { return tokenBurns }
        guard !tokenBurns.isEmpty else { return directBurns }

        let directIDs = Set(directBurns.map { $0.identity.id })
        let directPaths = Set(directBurns.flatMap(\.identity.logPaths))
        let indirectBurns = tokenBurns.filter { burn in
            !directIDs.contains(burn.identity.id)
                && directPaths.isDisjoint(with: Set(burn.identity.logPaths))
        }
        return directBurns + indirectBurns
    }
}

/// Shared, provider-agnostic helpers for assembling a runway snapshot:
/// deduping/merging session identities and filling pending ("waiting") rows for
/// active sessions whose burn rate hasn't been measured yet. Used by both the
/// Codex and Claude snapshot loaders.
enum RunwaySnapshotAssembly {
    /// Keeps an already-rendered snapshot during ordinary refreshes, but replaces
    /// it with pending rows as soon as the selected rate unit changes. The async
    /// loaders can take long enough for the old tk/h values to remain visibly under
    /// a newly-selected Wk control; this makes the transition honest immediately.
    static func placeholderForUnitTransition(
        current: CodexRunwaySnapshot?,
        request: CodexRunwaySnapshotRequest
    ) -> CodexRunwaySnapshot? {
        guard current?.baseline.rateUnit != request.baseline.rateUnit else { return current }
        return withPendingRows(
            baseline: request.baseline,
            snapshot: nil,
            activeIdentities: request.identities,
            maxRows: request.maxRows
        )
    }

    static func uniqueIdentities(_ identities: [RunwaySessionIdentity]) -> [RunwaySessionIdentity] {
        var byID: [String: RunwaySessionIdentity] = [:]
        var order: [String] = []

        for identity in identities {
            if let existing = byID[identity.id] {
                byID[identity.id] = RunwaySessionIdentity(
                    id: existing.id,
                    displayName: existing.displayName,
                    isGoal: existing.isGoal || identity.isGoal,
                    logPaths: Array(Set(existing.logPaths).union(identity.logPaths)).sorted(),
                    // Idle only if every contributor is idle: any working file
                    // (a live subagent, a HUD presence row) keeps it working.
                    isIdle: existing.isIdle && identity.isIdle
                )
            } else {
                byID[identity.id] = identity
                order.append(identity.id)
            }
        }

        var groups = order.compactMap { id -> IdentityMergeGroup? in
            guard let identity = byID[id] else { return nil }
            return IdentityMergeGroup(
                id: identity.id,
                displayName: identity.displayName,
                isGoal: identity.isGoal,
                logPaths: Set(identity.logPaths),
                isIdle: identity.isIdle,
                order: order.firstIndex(of: id) ?? 0
            )
        }

        var index = 0
        while index < groups.count {
            var scanIndex = index + 1
            while scanIndex < groups.count {
                if groups[index].logPaths.isDisjoint(with: groups[scanIndex].logPaths) {
                    scanIndex += 1
                    continue
                }

                let merged = IdentityMergeGroup.merged(groups[index], groups[scanIndex])
                groups[index] = merged
                groups.remove(at: scanIndex)
                scanIndex = index + 1
            }
            index += 1
        }

        return groups
            .sorted { $0.order < $1.order }
            .map {
                RunwaySessionIdentity(
                    id: $0.id,
                    displayName: $0.displayName,
                    isGoal: $0.isGoal,
                    logPaths: Array($0.logPaths).sorted(),
                    isIdle: $0.isIdle
                )
            }
    }

    /// Appends explicit "n/a" rows for identities that can never be estimated in
    /// the current unit (weekly: an unpriceable model, or no weekly window at all).
    /// Kept distinct from a pending row on purpose — a waiting clock promises a
    /// number is coming, and for these sessions it is not.
    static func withUnavailableRows(baseline: RunwayProviderBaseline,
                                    snapshot: CodexRunwaySnapshot?,
                                    identities: [RunwaySessionIdentity],
                                    unavailableIDs: Set<String>,
                                    maxRows: Int) -> CodexRunwaySnapshot? {
        guard maxRows > 0, !unavailableIDs.isEmpty else { return snapshot }
        let existing = snapshot ?? CodexRunwaySnapshot(baseline: baseline, rows: [], burstSummary: nil)
        let representedIDs = Set(existing.rows.map(\.id))
        let pending = identities.filter { unavailableIDs.contains($0.id) && !representedIDs.contains($0.id) }
        guard !pending.isEmpty else { return existing }

        let candidates = existing.rows + pending.map { identity in
            RunwayPauseImpactRow(
                id: identity.id,
                displayName: identity.displayName,
                isGoal: identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: 0,
                // An idle session still reads as a calm dash; only a working one
                // that genuinely cannot be estimated says "n/a".
                confidence: identity.isIdle ? .idle : .unsupported
            )
        }
        let (visible, overflow) = RunwayOverflowRule.split(candidates, maxRows: maxRows)
        let burstSummary: RunwayShortBurstSummary? = overflow.isEmpty
            ? (existing.burstSummary)
            : RunwayShortBurstSummary(
                count: overflow.count + (existing.burstSummary?.count ?? 0),
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(existing.burstSummary?.displayRate ?? 0) { $0 + $1.displayRate }
            )
        return CodexRunwaySnapshot(baseline: existing.baseline, rows: Array(visible), burstSummary: burstSummary)
    }

    /// `pendingConfidence` is what a working session with no measured burn reports.
    /// It defaults to `.waiting` (the historical "a number is coming" state), but
    /// weekly passes `.direct` once a calibration exists: at that point a session
    /// with no current activity genuinely estimates to zero, which is an honest
    /// "flat" rather than an open question. Leaving it `.waiting` there put a
    /// spinning clock next to a session that was simply idle between turns.
    static func withPendingRows(baseline: RunwayProviderBaseline,
                                snapshot: CodexRunwaySnapshot?,
                                activeIdentities: [RunwaySessionIdentity],
                                maxRows: Int,
                                pendingConfidence: RunwayAttributionConfidence = .waiting,
                                waitingIDs: Set<String> = []) -> CodexRunwaySnapshot? {
        guard maxRows > 0 else { return snapshot }
        let existing = snapshot ?? CodexRunwaySnapshot(baseline: baseline, rows: [], burstSummary: nil)
        let representedIDs = Set(existing.rows.map(\.id))
        let pendingIdentities = activeIdentities.filter { !representedIDs.contains($0.id) }
        guard !pendingIdentities.isEmpty else { return existing }

        if let burnSummary = existing.burstSummary {
            // Rows are already full to maxRows, so every pending identity stays
            // hidden. Merge the counts so "+X" reflects hidden burns AND hidden
            // idle actives; the burn summary keeps the aggregate rate/deadline
            // (pending sessions contribute rate 0).
            return CodexRunwaySnapshot(
                baseline: existing.baseline,
                rows: existing.rows,
                burstSummary: RunwayShortBurstSummary(
                    count: burnSummary.count + pendingIdentities.count,
                    deadline: burnSummary.deadline,
                    gainedSeconds: burnSummary.gainedSeconds,
                    displayRate: burnSummary.displayRate
                )
            )
        }

        let candidates = existing.rows + pendingIdentities.map { identity in
            RunwayPauseImpactRow(
                id: identity.id,
                displayName: identity.displayName,
                isGoal: identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: 0,
                // Idle sessions show a calm "—"; still-working ones use the
                // caller's pending state (see `pendingConfidence`).
                confidence: identity.isIdle
                    ? .idle
                    : (waitingIDs.contains(identity.id) ? .waiting : pendingConfidence)
            )
        }
        let (visible, overflow) = RunwayOverflowRule.split(candidates, maxRows: maxRows)
        let burstSummary: RunwayShortBurstSummary? = overflow.isEmpty
            ? nil
            : RunwayShortBurstSummary(
                count: overflow.count,
                deadline: overflow.first?.deadline ?? .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(0) { $0 + $1.displayRate }
            )

        return CodexRunwaySnapshot(
            baseline: existing.baseline,
            rows: Array(visible),
            burstSummary: burstSummary
        )
    }

    private struct IdentityMergeGroup {
        let id: String
        let displayName: String
        let isGoal: Bool
        let logPaths: Set<String>
        let isIdle: Bool
        let order: Int

        static func merged(_ lhs: IdentityMergeGroup, _ rhs: IdentityMergeGroup) -> IdentityMergeGroup {
            let winner: IdentityMergeGroup
            if lhs.logPaths.count != rhs.logPaths.count {
                winner = lhs.logPaths.count > rhs.logPaths.count ? lhs : rhs
            } else {
                winner = lhs.order > rhs.order ? lhs : rhs
            }
            return IdentityMergeGroup(
                id: winner.id,
                displayName: winner.displayName,
                isGoal: lhs.isGoal || rhs.isGoal,
                logPaths: lhs.logPaths.union(rhs.logPaths),
                isIdle: lhs.isIdle && rhs.isIdle,
                order: min(lhs.order, rhs.order)
            )
        }
    }
}

enum RunwayOverflowRule {
    /// Splits an already-ranked list into visible rows plus overflow.
    /// Orphan rule: a lone overflow item is promoted to a visible row — a
    /// summary row costs the same height as a real row, so "+1 sessions"
    /// would hide the session's name and rate for free. A summary is only
    /// worth emitting when it collapses two or more sessions.
    static func split<T>(_ ranked: [T], maxRows: Int) -> (visible: ArraySlice<T>, overflow: ArraySlice<T>) {
        guard maxRows > 0 else { return (ranked.prefix(0), ranked[...]) }
        if ranked.count - maxRows <= 1 {
            return (ranked[...], ranked.suffix(0))
        }
        return (ranked.prefix(maxRows), ranked.dropFirst(maxRows))
    }
}

enum CodexRunwayCalculator {
    static let minimumDisplayedGain: TimeInterval = 60

    static func snapshot(baseline: RunwayProviderBaseline,
                         burns: [RunwaySessionBurn],
                         maxRows: Int = 3) -> CodexRunwaySnapshot? {
        guard maxRows > 0 else { return nil }
        let currentSeconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        guard currentSeconds > 0,
              baseline.remainingPercent > 0 else {
            return nil
        }

        let providerRate = baseline.remainingPercent / currentSeconds
        guard providerRate > 0, providerRate.isFinite else { return nil }

        let positiveBurns = burns
            .filter { $0.percentPerSecond > 0 && $0.percentPerSecond.isFinite }
        guard !positiveBurns.isEmpty else {
            return CodexRunwaySnapshot(baseline: baseline, rows: [], burstSummary: nil)
        }

        let totalAttributedRate = positiveBurns.reduce(0) { $0 + $1.percentPerSecond }
        let scale = totalAttributedRate > providerRate ? providerRate / totalAttributedRate : 1
        let impacts = positiveBurns.map { burn in
            let normalizedRate = burn.percentPerSecond * scale
            return Impact(
                normalizedRate: normalizedRate,
                row: impactRow(
                    baseline: baseline,
                    providerRate: providerRate,
                    burn: burn,
                    normalizedRate: normalizedRate
                )
            )
        }

        if baseline.currentRunoutAt >= baseline.resetAt {
            let ranked = impacts.sorted { lhs, rhs in
                if lhs.normalizedRate != rhs.normalizedRate {
                    return lhs.normalizedRate > rhs.normalizedRate
                }
                if lhs.row.isGoal != rhs.row.isGoal {
                    return lhs.row.isGoal && !rhs.row.isGoal
                }
                return lhs.row.displayName.localizedCaseInsensitiveCompare(rhs.row.displayName) == .orderedAscending
            }
            let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
            let rows = visible.map {
                RunwayPauseImpactRow(
                    id: $0.row.id,
                    displayName: $0.row.displayName,
                    isGoal: $0.row.isGoal,
                    deadline: .afterReset,
                    gainedSeconds: 0,
                    displayRate: $0.row.displayRate,
                    confidence: $0.row.confidence
                )
            }
            let burstSummary = overflow.isEmpty
                ? nil
                : RunwayShortBurstSummary(
                    count: overflow.count,
                    deadline: .afterReset,
                    gainedSeconds: 0,
                    displayRate: overflow.reduce(0) { $0 + $1.row.displayRate }
                )
            return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary)
        }

        let pressureImpacts = impacts
            .sorted { lhs, rhs in
                if lhs.row.gainedSeconds != rhs.row.gainedSeconds {
                    return lhs.row.gainedSeconds > rhs.row.gainedSeconds
                }
                if lhs.normalizedRate != rhs.normalizedRate {
                    return lhs.normalizedRate > rhs.normalizedRate
                }
                if lhs.row.isGoal != rhs.row.isGoal {
                    return lhs.row.isGoal && !rhs.row.isGoal
                }
                return lhs.row.displayName.localizedCaseInsensitiveCompare(rhs.row.displayName) == .orderedAscending
            }

        let (visible, overflow) = RunwayOverflowRule.split(pressureImpacts, maxRows: maxRows)
        let rows = visible.map(\.row)
        let burstSummary = summary(
            for: Array(overflow),
            baseline: baseline,
            providerRate: providerRate
        )
        return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary)
    }

    /// Token-mode snapshot: rows report raw per-session token throughput
    /// (tokens/hour) instead of the m/h yardstick — used when the active window
    /// has no run-out to normalize against (the 5h window is dropped). There is no
    /// deadline (the tk/h rate is the whole story); the rate rides in the row's
    /// `displayRate` field, interpreted per `baseline.rateUnit`.
    static func tokenSnapshot(baseline: RunwayProviderBaseline,
                              activities: [RunwaySessionActivity],
                              maxRows: Int) -> CodexRunwaySnapshot? {
        guard maxRows > 0 else { return nil }
        let positive = activities.filter { $0.tokensPerSecond > 0 && $0.tokensPerSecond.isFinite }
        guard !positive.isEmpty else {
            return CodexRunwaySnapshot(baseline: baseline, rows: [], burstSummary: nil)
        }
        let ranked = positive.sorted { lhs, rhs in
            if lhs.tokensPerSecond != rhs.tokensPerSecond {
                return lhs.tokensPerSecond > rhs.tokensPerSecond
            }
            if lhs.identity.isGoal != rhs.identity.isGoal {
                return lhs.identity.isGoal && !rhs.identity.isGoal
            }
            return lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName) == .orderedAscending
        }
        let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
        let rows = visible.map { activity in
            RunwayPauseImpactRow(
                id: activity.identity.id,
                displayName: activity.identity.displayName,
                isGoal: activity.identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: activity.tokensPerSecond * 3600,
                confidence: .direct
            )
        }
        let burstSummary = overflow.isEmpty
            ? nil
            : RunwayShortBurstSummary(
                count: overflow.count,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(0) { $0 + $1.tokensPerSecond * 3600 }
            )
        return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary)
    }

    /// Weekly-mode snapshot: each session's ESTIMATED share of the account's weekly
    /// quota per hour, from its own current activity.
    ///
    /// The rate is `calibration × session $/h`, where `calibration` is the learned
    /// pp-per-API-dollar conversion (see `WeeklyQuotaCalibrationTracker`). This is
    /// deliberately NOT the old proportional split of a previously measured account
    /// rate: that redistributed a fixed total, so doubling every session's activity
    /// left the displayed total unchanged. Here each row is computed from its own
    /// current activity, so a session that doubles its burn doubles its `%/h`, and
    /// the account total moves with real activity.
    ///
    /// Absolute price level cancels between calibration and application — only the
    /// RELATIVE weights matter, which is why `$` pricing is reused as the weight
    /// function rather than a bespoke token blend.
    ///
    /// Returns `nil` only when nothing at all can be estimated. The loader must NOT
    /// fall back to tokens on nil: `Wk` never renders `tk/h`.
    static func weeklyEstimatedSnapshot(baseline: RunwayProviderBaseline,
                                        activities: [RunwaySessionActivity],
                                        priceTable: RunwayPriceTable,
                                        percentPointsPerDollar: Double,
                                        maxRows: Int) -> (snapshot: CodexRunwaySnapshot, unpriceableIDs: Set<String>)? {
        guard maxRows > 0 else { return nil }
        guard percentPointsPerDollar > 0, percentPointsPerDollar.isFinite else { return nil }

        var estimated: [(activity: RunwaySessionActivity, percentPerHour: Double)] = []
        var unpriceableIDs: Set<String> = []
        for activity in activities {
            guard let dollarsPerHour = dollarsPerHour(for: activity, priceTable: priceTable) else {
                // Cannot be weighted, so it cannot be estimated. Surfaced as "n/a"
                // rather than silently omitted or shown as a waiting clock.
                unpriceableIDs.insert(activity.identity.id)
                continue
            }
            let percentPerHour = percentPointsPerDollar * dollarsPerHour
            guard percentPerHour.isFinite,
                  percentPerHour <= WeeklyQuotaCalibrationTracker.maximumDisplayablePercentPerHour else {
                // Past this magnitude the calibration is contaminated (untracked
                // usage on another device inflating pp-per-dollar), not the session
                // extraordinary. Say "n/a" instead of a confident wrong number.
                unpriceableIDs.insert(activity.identity.id)
                continue
            }
            estimated.append((activity, percentPerHour))
        }
        guard !estimated.isEmpty else { return nil }

        let ranked = estimated.sorted { lhs, rhs in
            if lhs.percentPerHour != rhs.percentPerHour { return lhs.percentPerHour > rhs.percentPerHour }
            if lhs.activity.identity.isGoal != rhs.activity.identity.isGoal {
                return lhs.activity.identity.isGoal && !rhs.activity.identity.isGoal
            }
            return lhs.activity.identity.displayName.localizedCaseInsensitiveCompare(rhs.activity.identity.displayName) == .orderedAscending
        }
        let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
        let rows = visible.map { entry in
            RunwayPauseImpactRow(
                id: entry.activity.identity.id,
                displayName: entry.activity.identity.displayName,
                isGoal: entry.activity.identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: entry.percentPerHour,
                confidence: .direct
            )
        }
        let burstSummary = overflow.isEmpty
            ? nil
            : RunwayShortBurstSummary(
                count: overflow.count,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(0) { $0 + $1.percentPerHour }
            )
        return (CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary), unpriceableIDs)
    }

    /// $/h for a single session, or nil when it can't be priced: no per-type
    /// breakdown (legacy Codex `token_count` lines carry only a flat total) or an
    /// unknown model slug. Per-type rates are pre-normalized to FRESH input +
    /// cached-read + output + cache-creation, so pricing is a plain sum (no
    /// subtraction). $/h is intentionally non-proportional to tk/h (which nets out
    /// cache) because cache reads/writes cost real money.
    ///
    /// Reasoning tokens are NOT a separate term here, and that is correct rather
    /// than an omission: Codex reports `reasoning_output_tokens` as a SUBSET of
    /// `output_tokens` (verified — `total_tokens == input_tokens + output_tokens`,
    /// with reasoning already inside output), and providers bill reasoning at the
    /// output rate. So output already carries it; adding reasoning would double-count
    /// it, and subtracting it would understate the bill.
    static func dollarsPerHour(for activity: RunwaySessionActivity,
                               priceTable: RunwayPriceTable) -> Double? {
        var perSecond = 0.0
        var pricedAnything = false
        for component in activity.components {
            // A zero-rate slice costs nothing, so it can't make the session
            // unpriceable even if its model is unknown.
            guard component.totalPerSecond > 0 else { continue }
            // Any *contributing* slice we can't price makes the whole session
            // unpriceable: pricing only the known slices would silently understate
            // the session rather than drop it honestly. That covers an unknown model
            // AND a slice served at a billing tier the model has no rates for — a
            // fast-mode record priced at standard would understate it by half.
            guard let p = priceTable.price(forModel: component.modelSlug),
                  let rates = p.rates(for: component.speed,
                                      contextInputTokens: component.contextInputTokens) else { return nil }
            perSecond += rates.dollars(input: component.inputPerSecond,
                                       cachedInput: component.cachedInputPerSecond,
                                       output: component.outputPerSecond,
                                       cacheWrite5m: component.cacheCreationPerSecond,
                                       cacheWrite1h: component.cacheCreation1hPerSecond)
            pricedAnything = true
        }
        guard pricedAnything, perSecond.isFinite else { return nil }
        return perSecond * 3600
    }

    /// $-mode snapshot: each session's API-equivalent cost per hour. Prices every
    /// session it can and DROPS the ones it can't (unknown model / no per-type
    /// data), returning nil only when nothing at all is priceable — then the loader
    /// falls back to token snapshot-wide (never a per-row unit mix). Dropping rather
    /// than nil-ing on the first unpriceable session keeps the unit stable: one
    /// unpriceable session flipping in and out of activity used to flap the whole
    /// provider between $ and tk/h every refresh.
    ///
    /// `unpriceableIDs` is returned rather than recomputed by callers so there is a
    /// single source of truth for what was dropped: the loader MUST keep these out
    /// of the pending rows, or a dropped session reappears as "$0/h" while it is
    /// genuinely burning.
    static func dollarSnapshot(baseline: RunwayProviderBaseline,
                               activities: [RunwaySessionActivity],
                               priceTable: RunwayPriceTable,
                               maxRows: Int) -> (snapshot: CodexRunwaySnapshot, unpriceableIDs: Set<String>)? {
        guard maxRows > 0 else { return nil }
        var priced: [(activity: RunwaySessionActivity, dollarsPerHour: Double)] = []
        var unpriceableIDs: Set<String> = []
        for a in activities {
            if let rate = dollarsPerHour(for: a, priceTable: priceTable) {
                priced.append((a, rate))
            } else {
                unpriceableIDs.insert(a.identity.id)
            }
        }
        guard !priced.isEmpty else { return nil }
        let ranked = priced.sorted { lhs, rhs in
            if lhs.dollarsPerHour != rhs.dollarsPerHour { return lhs.dollarsPerHour > rhs.dollarsPerHour }
            if lhs.activity.identity.isGoal != rhs.activity.identity.isGoal {
                return lhs.activity.identity.isGoal && !rhs.activity.identity.isGoal
            }
            return lhs.activity.identity.displayName.localizedCaseInsensitiveCompare(rhs.activity.identity.displayName) == .orderedAscending
        }
        let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
        let rows = visible.map { e in
            RunwayPauseImpactRow(
                id: e.activity.identity.id,
                displayName: e.activity.identity.displayName,
                isGoal: e.activity.identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: e.dollarsPerHour,
                confidence: .direct
            )
        }
        let burstSummary = overflow.isEmpty
            ? nil
            : RunwayShortBurstSummary(
                count: overflow.count,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(0) { $0 + $1.dollarsPerHour }
            )
        return (CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary), unpriceableIDs)
    }

    private static func impactRow(baseline: RunwayProviderBaseline,
                                  providerRate: Double,
                                  burn: RunwaySessionBurn,
                                  normalizedRate: Double) -> RunwayPauseImpactRow {
        let remainingRate = max(0, providerRate - normalizedRate)
        let deadline = deadline(
            baseline: baseline,
            remainingRate: remainingRate
        )
        let gained = gainedSeconds(
            baseline: baseline,
            deadline: deadline
        )
        return RunwayPauseImpactRow(
            id: burn.identity.id,
            displayName: burn.identity.displayName,
            isGoal: burn.identity.isGoal,
            deadline: gained < minimumDisplayedGain ? .noChange : deadline,
            gainedSeconds: gained < minimumDisplayedGain ? 0 : gained,
            displayRate: quotaMinutesPerHour(normalizedRate, windowMinutes: baseline.windowMinutes),
            confidence: burn.confidence
        )
    }

    private static func summary(for impacts: [Impact],
                                baseline: RunwayProviderBaseline,
                                providerRate: Double) -> RunwayShortBurstSummary? {
        guard !impacts.isEmpty else { return nil }
        let hiddenRate = impacts.reduce(0) { $0 + $1.normalizedRate }
        guard hiddenRate > 0, hiddenRate.isFinite else { return nil }
        let deadline = deadline(
            baseline: baseline,
            remainingRate: max(0, providerRate - hiddenRate)
        )
        let gained = gainedSeconds(baseline: baseline, deadline: deadline)
        return RunwayShortBurstSummary(
            count: impacts.count,
            deadline: gained < minimumDisplayedGain ? .noChange : deadline,
            gainedSeconds: gained < minimumDisplayedGain ? 0 : gained,
            displayRate: impacts.reduce(0) { $0 + $1.row.displayRate }
        )
    }

    private static func deadline(baseline: RunwayProviderBaseline,
                                 remainingRate: Double) -> RunwayDeadline {
        guard remainingRate > 0 else { return .afterReset }
        let seconds = baseline.remainingPercent / remainingRate
        guard seconds.isFinite, seconds > 0 else { return .unavailable }
        let projected = baseline.observedAt.addingTimeInterval(seconds)
        return projected >= baseline.resetAt ? .afterReset : .runout(projected)
    }

    private static func gainedSeconds(baseline: RunwayProviderBaseline,
                                      deadline: RunwayDeadline) -> TimeInterval {
        switch deadline {
        case .afterReset:
            return max(0, baseline.resetAt.timeIntervalSince(baseline.currentRunoutAt))
        case .runout(let date):
            return max(0, date.timeIntervalSince(baseline.currentRunoutAt))
        case .noChange, .unavailable:
            return 0
        }
    }

    private static func quotaMinutesPerHour(_ percentPerSecond: Double, windowMinutes: Int) -> Double {
        // Quota-minutes burned per hour = (percent/sec) × (minutes per 1% of the
        // window) × 3600, where minutesPerPercent = windowMinutes / 100. This keeps
        // the reading on the yardstick the user knows: 60 m/h == burning at exactly
        // the sustainable pace for the active window (100% of the window consumed
        // over its own length), whether that window is the 5h or the weekly one.
        // (Not a claim that the same token burn yields the same absolute m/h across
        // windows — the 5h and weekly quotas are set independently — only that the
        // sustainable-pace anchor is preserved when the 5h window is dropped.)
        percentPerSecond * (Double(windowMinutes) / 100.0) * 3600
    }

    private struct Impact {
        let normalizedRate: Double
        let row: RunwayPauseImpactRow
    }
}

/// A rate-limit line parsed `now`-independently: everything except the two
/// `now`-dependencies (the `?? now` capture fallback and the resets-in-seconds
/// offset, both anchored on `capturedAt`) is resolved here so it can be cached
/// across cycles. `finalize(now:)` reproduces those two exactly.
/// File scope (not nested in the parser): a static stored property whose
/// generic argument is a type nested in the same declaration trips a
/// circular-reference error in the type checker.
private enum CodexRateLimitResetSpec: Sendable {
    case absolute(Date)
    case relativeSeconds(Double)
}

private struct CodexRawRateLimitLine: Sendable {
    let logPath: String
    let capturedAtReal: Date?
    let remainingPercent: Double
    let resetSpec: CodexRateLimitResetSpec
}

enum CodexRunwayRateLimitParser {
    static let maximumSampleAge: TimeInterval = 75
    static let maximumPairInterval: TimeInterval = 10 * 60

    private static let sampleCache = RunwayFileParseCache<[CodexRawRateLimitLine]>()

    #if DEBUG
    static var sampleCacheMissCountForTesting: Int { sampleCache.missCount }
    static func resetSampleCacheForTesting() { sampleCache.removeAllForTesting() }
    #endif

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 512 * 1024,
                              now: Date = Date()) -> [CodexRunwayRateLimitSample] {
        let raw: [CodexRawRateLimitLine]
        if let signature = RunwayFileSignature.read(path: path) {
            raw = sampleCache.value(path: path, signature: signature) {
                parseRawLines(fromLogPath: path, maxBytes: maxBytes)
            }
        } else {
            raw = parseRawLines(fromLogPath: path, maxBytes: maxBytes)
        }
        return raw
            .compactMap { finalize($0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    static func retainCache(paths: Set<String>) {
        sampleCache.retain(paths: paths)
    }

    private static func parseRawLines(fromLogPath path: String,
                                      maxBytes: Int) -> [CodexRawRateLimitLine] {
        guard let data = tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseRawLine(String($0), logPath: path) }
    }

    /// Re-applies the two `now`-dependencies dropped from `parseRawLine`: the
    /// missing-capture fallback (`capturedAtReal ?? now`), the future-timestamp
    /// skip, and the resets-in-seconds offset relative to that capture.
    private static func finalize(_ raw: CodexRawRateLimitLine, now: Date) -> CodexRunwayRateLimitSample? {
        let capturedAt = raw.capturedAtReal ?? now
        guard capturedAt <= now.addingTimeInterval(5) else { return nil }
        let resetAt: Date
        switch raw.resetSpec {
        case .absolute(let date):
            resetAt = date
        case .relativeSeconds(let seconds):
            resetAt = capturedAt.addingTimeInterval(seconds)
        }
        return CodexRunwayRateLimitSample(
            logPath: raw.logPath,
            capturedAt: capturedAt,
            remainingPercent: raw.remainingPercent,
            resetAt: resetAt
        )
    }

    static func burn(identity: RunwaySessionIdentity,
                     now: Date = Date()) -> RunwaySessionBurn? {
        let samples = identity.logPaths.flatMap { recentSamples(fromLogPath: $0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
        guard samples.count >= 2 else { return nil }

        for pair in zip(samples.dropLast().reversed(), samples.dropFirst().reversed()) {
            let previous = pair.0
            let current = pair.1
            guard abs(previous.resetAt.timeIntervalSince(current.resetAt)) < 120 else { continue }
            guard now.timeIntervalSince(current.capturedAt) <= maximumSampleAge else { continue }
            let elapsed = current.capturedAt.timeIntervalSince(previous.capturedAt)
            guard elapsed >= 60 else { continue }
            guard elapsed <= maximumPairInterval else { continue }
            let delta = previous.remainingPercent - current.remainingPercent
            guard delta > 0 else { continue }
            return RunwaySessionBurn(
                identity: identity,
                percentPerSecond: delta / elapsed,
                confidence: identity.logPaths.count == 1 ? .direct : .mixed,
                sampleStart: previous.capturedAt,
                sampleEnd: current.capturedAt
            )
        }
        return nil
    }

    /// `now`-independent parse of one line. The two `now`-dependencies (missing
    /// capture fallback + resets-in-seconds offset) are deferred to `finalize`;
    /// the future-timestamp skip is applied there too. A line is retained here
    /// only when it would have yielded a sample for a non-future `capturedAt`,
    /// so caching + finalizing is byte-identical to the original single pass.
    private static func parseRawLine(_ line: String,
                                     logPath: String) -> CodexRawRateLimitLine? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let createdAtReal = flexibleDate(obj["created_at"])
            ?? flexibleDate(payload["created_at"])
            ?? flexibleDate(obj["timestamp"])
            ?? flexibleDate(payload["timestamp"])

        guard let rate = (payload["rate_limits"] as? [String: Any])
            ?? (obj["rate_limits"] as? [String: Any])
            ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]) else {
            return nil
        }
        let limitID = (rate["limit_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard limitID == nil || limitID == "codex" || limitID == "" else { return nil }
        let capturedAtReal = flexibleDate(rate["captured_at"]) ?? createdAtReal
        // Track the same window the status line shows: the short (5h) window when
        // present, else the long (weekly) window. When OpenAI drops the 5h window
        // the weekly window is what sessions burn, so the runway follows it instead
        // of vanishing. Classifying by window_minutes stays now-independent.
        guard let window = activeWindow(rate),
              let remaining = remainingPercent(window),
              let resetSpec = resetSpec(window) else {
            return nil
        }
        return CodexRawRateLimitLine(
            logPath: logPath,
            capturedAtReal: capturedAtReal,
            remainingPercent: remaining,
            resetSpec: resetSpec
        )
    }

    /// The window whose burn the runway should track: short (5h-class) when
    /// present, else long (weekly-class), matching the active status line. Reads
    /// window_minutes only (now-independent), falling back to `primary` for legacy
    /// lines that omit it.
    private static func activeWindow(_ rate: [String: Any]) -> [String: Any]? {
        let primary = rate["primary"] as? [String: Any]
        let secondary = rate["secondary"] as? [String: Any]
        if windowClass(primary) == .short { return primary }
        if windowClass(secondary) == .short { return secondary }
        if windowClass(primary) == .long { return primary }
        if windowClass(secondary) == .long { return secondary }
        return primary
    }

    private static func windowClass(_ dict: [String: Any]?) -> CodexRateLimitWindowClass? {
        guard let dict, let minutes = double(dict["window_minutes"]), minutes > 0 else { return nil }
        return CodexRateLimitWindowClassifier.classify(windowMinutes: Int(minutes))
    }

    private static func remainingPercent(_ dict: [String: Any]) -> Double? {
        if let v = double(dict["remaining_percent"]) { return max(0, min(100, v)) }
        if let v = double(dict["pct_left"]) { return max(0, min(100, v)) }
        if let v = double(dict["pct_remaining"]) { return max(0, min(100, v)) }
        if let used = double(dict["used_percent"]) { return max(0, min(100, 100 - used)) }
        return nil
    }

    /// The reset resolution, `now`-independent. `resets_in_seconds` is an offset
    /// from the (later-resolved) capture time; the absolute keys are fixed dates.
    /// Matches the original `resetDate` key priority exactly.
    private static func resetSpec(_ dict: [String: Any]) -> CodexRateLimitResetSpec? {
        if let seconds = double(dict["resets_in_seconds"]) {
            return .relativeSeconds(seconds)
        }
        for key in ["resets_at", "reset_at", "resetsAt", "resetAt", "resets_at_ms", "reset_at_ms"] {
            guard let value = dict[key] else { continue }
            if key.hasSuffix("_ms"), let numeric = double(value) {
                return .absolute(Date(timeIntervalSince1970: normalizeEpochSeconds(numeric)))
            }
            if let date = flexibleDate(value) {
                return .absolute(date)
            }
        }
        return nil
    }

    fileprivate static func tailData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    fileprivate static func headData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    fileprivate static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    fileprivate static func flexibleDate(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(double))
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(Double(int)))
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(number.doubleValue))
        }
        guard let string = value as? String else { return nil }
        if let numeric = Double(string), string.allSatisfy({ $0.isNumber || $0 == "." }) {
            return Date(timeIntervalSince1970: normalizeEpochSeconds(numeric))
        }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    fileprivate static func normalizeEpochSeconds(_ value: Double) -> Double {
        if value > 1e14 { return value / 1_000_000 }
        if value > 1e11 { return value / 1_000 }
        return value
    }
}

/// Bytes-derived, `now`-independent artifacts for one session file: header
/// metadata plus the parsed tail lines that feed active-window detection.
/// Cached by `(path, mtime, size)`; `hasActiveTail(from:now:)` recomputes the
/// time-dependent verdict each cycle.
/// File scope (not nested in the scanner): a static stored property whose
/// generic argument is a type nested in the same declaration trips a
/// circular-reference error in the type checker.
private struct CodexScannerFileParse {
    let metadata: CodexScannerSessionMetadata
    let activeTailLines: [CodexScannerActiveTailLine]
}

private struct CodexScannerActiveTailLine {
    let capturedAtReal: Date?
    let isTaskComplete: Bool
    let isWork: Bool
}

private struct CodexScannerSessionMetadata {
    var sessionID: String?
    var parentSessionID: String?
    var cwd: String?
    var nickname: String?
    var firstUserText: String?
    var isGoal = false
}

enum CodexRunwayRecentSessionScanner {
    static let maximumFileAge: TimeInterval = 30 * 60
    static let maximumActiveSampleAge: TimeInterval = 75
    static let maximumGoalCompletionGrace: TimeInterval = 75
    static let maximumFiles = 12
    static let maximumMetadataFiles = 80

    static func identities(root: URL? = nil,
                           now: Date = Date(),
                           activeSampleAge: TimeInterval = maximumActiveSampleAge,
                           completionGrace: TimeInterval = maximumGoalCompletionGrace,
                           fileManager: FileManager = .default) -> [RunwaySessionIdentity] {
        let rootURL = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let cutoff = now.addingTimeInterval(-maximumFileAge)
        var candidates: [(url: URL, modifiedAt: Date, signature: RunwayFileSignature)] = []

        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }
            let signature = RunwayFileSignature(mtime: modifiedAt, size: UInt64(values?.fileSize ?? 0))
            candidates.append((url, modifiedAt, signature))
        }

        let threadNames = SessionIndexer.loadCodexThreadNames(sessionsRoot: rootURL)

        let readEntries = candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumMetadataFiles)
        // Unchanged files reuse their head/tail parse; the now-dependent active
        // window is recomputed below. Prune to the files actually read this cycle.
        fileCache.retain(paths: Set(readEntries.map { $0.url.path }))
        let recentCandidates = readEntries
            .compactMap {
                candidate(
                    for: $0.url,
                    now: now,
                    activeSampleAge: activeSampleAge,
                    completionGrace: completionGrace,
                    threadNames: threadNames,
                    signature: $0.signature
                )
            }
        return Array(mergeParentCandidates(recentCandidates).prefix(maximumFiles))
    }

    // The parse struct lives at file scope (not nested): a static stored
    // property whose generic argument is a type nested in the same declaration
    // trips a circular-reference error in the type checker.
    private static let fileCache = RunwayFileParseCache<CodexScannerFileParse>()

    #if DEBUG
    static var fileCacheMissCountForTesting: Int { fileCache.missCount }
    static func resetFileCacheForTesting() { fileCache.removeAllForTesting() }
    #endif

    private static func candidate(for url: URL,
                                  now: Date,
                                  activeSampleAge: TimeInterval,
                                  completionGrace: TimeInterval,
                                  threadNames: [String: String],
                                  signature: RunwayFileSignature) -> RecentSessionCandidate? {
        let parse = fileCache.value(path: url.path, signature: signature) {
            // Self-qualified: the unqualified name would bind to the local
            // `metadata` below and cycle the type checker.
            CodexScannerFileParse(
                metadata: Self.metadata(from: url),
                activeTailLines: activeTailLines(url: url)
            )
        }
        let metadata = parse.metadata
        if let cwd = metadata.cwd,
           CodexProbeConfig.isProbeWorkingDirectory(cwd) {
            return nil
        }
        let isActive = hasActiveTail(
            from: parse.activeTailLines,
            now: now,
            activeSampleAge: activeSampleAge,
            completionGrace: completionGrace
        )
        let fallbackID = url.deletingPathExtension().lastPathComponent
        let id = metadata.sessionID ?? fallbackID
        let customTitle = [metadata.parentSessionID, metadata.sessionID]
            .compactMap { $0 }
            .compactMap { threadNames[$0] }
            .first
        return RecentSessionCandidate(
            sessionID: id,
            parentSessionID: metadata.parentSessionID,
            displayName: displayName(metadata: metadata, customTitle: customTitle, fallbackID: fallbackID),
            isGoal: metadata.isGoal,
            logPath: url.path,
            isActive: isActive
        )
    }

    private static func mergeParentCandidates(_ candidates: [RecentSessionCandidate]) -> [RunwaySessionIdentity] {
        let candidateBySessionID = Dictionary(
            candidates.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let parentBySessionID = Dictionary(
            candidates.compactMap { candidate -> (String, String)? in
                guard let parentSessionID = candidate.parentSessionID,
                      parentSessionID != candidate.sessionID else {
                    return nil
                }
                return (candidate.sessionID, parentSessionID)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var byID: [String: (displayName: String, isGoal: Bool, logPaths: Set<String>, hasRootRow: Bool)] = [:]
        var order: [String] = []

        for candidate in candidates {
            guard candidate.isActive else { continue }
            let rootID = rootSessionID(for: candidate, parentBySessionID: parentBySessionID)
            let isRootRow = candidate.sessionID == rootID
            let displayName = candidateBySessionID[rootID]?.displayName ?? candidate.displayName
            let hasRootRow = candidateBySessionID[rootID] != nil
            if var existing = byID[rootID] {
                existing.isGoal = existing.isGoal || candidate.isGoal
                existing.logPaths.insert(candidate.logPath)
                if isRootRow && !existing.hasRootRow {
                    existing.displayName = displayName
                    existing.hasRootRow = true
                }
                byID[rootID] = existing
            } else {
                order.append(rootID)
                byID[rootID] = (
                    displayName: displayName,
                    isGoal: candidate.isGoal,
                    logPaths: [candidate.logPath],
                    hasRootRow: hasRootRow
                )
            }
        }

        return order.compactMap { id in
            guard let group = byID[id] else { return nil }
            return RunwaySessionIdentity(
                id: id,
                displayName: group.displayName,
                isGoal: group.isGoal,
                logPaths: Array(group.logPaths).sorted()
            )
        }
    }

    private static func rootSessionID(for candidate: RecentSessionCandidate,
                                      parentBySessionID: [String: String]) -> String {
        var current = candidate.parentSessionID ?? candidate.sessionID
        var seen: Set<String> = [candidate.sessionID]
        while let parent = parentBySessionID[current],
              parent != current,
              !seen.contains(parent) {
            seen.insert(current)
            current = parent
        }
        return current
    }

    /// The expensive, `now`-independent half of active-tail detection: read the
    /// tail and classify the last lines. Lines that fail to parse are dropped
    /// exactly as the reverse scan would skip them, so replaying this list in
    /// reverse is byte-identical to the original inline scan. Cached per file.
    private static func activeTailLines(url: URL) -> [CodexScannerActiveTailLine] {
        guard let data = CodexRunwayRateLimitParser.tailData(path: url.path, maxBytes: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(160)
        var result: [CodexScannerActiveTailLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            let capturedAtReal = CodexRunwayRateLimitParser.flexibleDate(obj["created_at"])
                ?? CodexRunwayRateLimitParser.flexibleDate(payload["created_at"])
                ?? CodexRunwayRateLimitParser.flexibleDate(obj["timestamp"])
                ?? CodexRunwayRateLimitParser.flexibleDate(payload["timestamp"])
            result.append(CodexScannerActiveTailLine(
                capturedAtReal: capturedAtReal,
                isTaskComplete: string(payload["type"]) == "task_complete",
                isWork: isWorkSample(obj: obj, payload: payload)
            ))
        }
        return result
    }

    /// Recomputes the active/idle verdict every cycle from the cached tail lines.
    /// The `capturedAt ?? now` fallback and the age windows are the only
    /// `now`-dependencies, so a session advances active→idle→gone as time passes
    /// with the disk unchanged.
    private static func hasActiveTail(from lines: [CodexScannerActiveTailLine],
                                      now: Date,
                                      activeSampleAge: TimeInterval,
                                      completionGrace: TimeInterval) -> Bool {
        var latestWorkSampleAt: Date?
        var latestCompletionAt: Date?
        for line in lines.reversed() {
            if line.isTaskComplete {
                latestCompletionAt = line.capturedAtReal ?? now
                continue
            }
            if line.isWork {
                latestWorkSampleAt = line.capturedAtReal ?? now
                break
            }
        }
        guard let latestWorkSampleAt else { return false }
        let workAge = now.timeIntervalSince(latestWorkSampleAt)
        guard workAge <= activeSampleAge else { return false }
        if let latestCompletionAt,
           latestCompletionAt >= latestWorkSampleAt {
            return now.timeIntervalSince(latestCompletionAt) <= completionGrace
        }
        return true
    }

    private static func isWorkSample(obj: [String: Any], payload: [String: Any]) -> Bool {
        if string(payload["type"]) == "token_count"
            || payload["rate_limits"] != nil
            || obj["rate_limits"] != nil {
            return true
        }

        let envelopeType = string(obj["type"])
        let payloadType = string(payload["type"])
        if envelopeType == "response_item" || envelopeType == "event_msg" || envelopeType == "turn_context" {
            return payloadType != "task_complete"
        }
        return payloadType == "message"
    }

    private static func metadata(from url: URL) -> CodexScannerSessionMetadata {
        guard let data = CodexRunwayRateLimitParser.headData(path: url.path, maxBytes: 96 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return CodexScannerSessionMetadata()
        }

        var metadata = CodexScannerSessionMetadata()
        var capturedIdentityMetadata = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(80) {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else {
                continue
            }
            if obj["type"] as? String == "session_meta" {
                metadata.isGoal = metadata.isGoal || isGoalPayload(payload)
                if !capturedIdentityMetadata {
                    metadata.sessionID = string(payload["id"]) ?? metadata.sessionID
                    metadata.cwd = string(payload["cwd"]) ?? metadata.cwd
                    metadata.nickname = string(payload["agent_nickname"]) ?? metadata.nickname
                    metadata.parentSessionID = parentSessionID(from: payload) ?? metadata.parentSessionID
                    capturedIdentityMetadata = true
                }
            }
            if metadata.firstUserText == nil,
               string(payload["type"]) == "message",
               string(payload["role"]) == "user" {
                if let text = firstInputText(from: payload),
                   !isSetupContextText(text) {
                    metadata.firstUserText = text
                }
            }
        }
        return metadata
    }

    private static func displayName(metadata: CodexScannerSessionMetadata, customTitle: String?, fallbackID: String) -> String {
        var parts: [String] = []
        if let title = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return compact(title)
        }
        if let text = metadata.firstUserText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return compact(text)
        }
        if let nickname = metadata.nickname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty {
            parts.append(nickname)
            if let cwd = metadata.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                parts.append(URL(fileURLWithPath: cwd).lastPathComponent)
            }
            return compact(parts.joined(separator: " / "))
        }
        if let cwd = metadata.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            parts.append(URL(fileURLWithPath: cwd).lastPathComponent)
        }
        if parts.isEmpty { parts.append(fallbackID.replacingOccurrences(of: "rollout-", with: "")) }
        return compact(parts.joined(separator: " / "))
    }

    private static func compact(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > 28 else { return collapsed }
        return String(collapsed.prefix(27)) + "..."
    }

    private static func firstInputText(from payload: [String: Any]) -> String? {
        if let content = payload["content"] as? [[String: Any]] {
            for item in content {
                if string(item["type"]) == "input_text",
                   let text = string(item["text"]) {
                    return text
                }
            }
        }
        return string(payload["text"])
    }

    private static func isSetupContextText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.hasPrefix("# AGENTS.md instructions for ") { return true }
        if trimmed.hasPrefix("<environment_context>") { return true }
        return false
    }

    private static func isGoalPayload(_ payload: [String: Any]) -> Bool {
        if payload["goal"] != nil { return true }
        if let source = payload["source"] as? [String: Any],
           source["goal"] != nil {
            return true
        }
        return false
    }

    private static func parentSessionID(from payload: [String: Any]) -> String? {
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] else {
            return nil
        }
        if let subagentDict = subagent as? [String: Any],
           let threadSpawn = subagentDict["thread_spawn"] as? [String: Any],
           let parent = string(threadSpawn["parent_thread_id"]) {
            return parent
        }
        // Newer Codex builds (0.145+) also stamp the parent link at payload top
        // level; guardian rollouts ({"subagent":{"other":"guardian"}}) have ONLY
        // this form. Kept identical to SessionIndexer's two parse blocks so a
        // running subagent groups here exactly as the indexed session list nests it.
        return string(payload["parent_thread_id"])
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        return nil
    }

    private struct RecentSessionCandidate {
        let sessionID: String
        let parentSessionID: String?
        let displayName: String
        let isGoal: Bool
        let logPath: String
        let isActive: Bool
    }
}

/// A token line parsed `now`-independently. The capture time's `?? now`
/// fallback and the future-timestamp skip are the only `now`-dependencies;
/// both are re-applied in `finalize(now:)`, keeping a cached parse
/// byte-identical to a fresh one for any `now`.
/// File scope (not nested in the parser): a static stored property whose
/// generic argument is a type nested in the same declaration trips a
/// circular-reference error in the type checker.
private struct CodexRawTokenLine: Sendable {
    let logPath: String
    let createdAtReal: Date?
    let totalTokens: Double
    // Cumulative per-type counts for $ pricing (0 when the line's `info` is null /
    // pre-per-type format). `input` includes cached; `cachedInput` is the cached
    // subset. `modelSlug` is resolved cross-line (token_count lines don't carry it).
    let input: Double
    let cachedInput: Double
    let output: Double
    let modelSlug: String?

    func withModelSlug(_ model: String?) -> CodexRawTokenLine {
        CodexRawTokenLine(logPath: logPath, createdAtReal: createdAtReal, totalTokens: totalTokens,
                          input: input, cachedInput: cachedInput, output: output, modelSlug: model)
    }
}

/// Bytes-derived token/context parse. `trailingModel` deliberately survives a
/// context-only tail: the next appended token must inherit the new model even
/// when a multi-megabyte tool record pushes that context out of the small tail.
private struct CodexRawTokenParse: Sendable {
    var lines: [CodexRawTokenLine]
    var trailingModel: String?

    static let empty = CodexRawTokenParse(lines: [], trailingModel: nil)

    func appending(_ other: CodexRawTokenParse) -> CodexRawTokenParse {
        CodexRawTokenParse(
            lines: lines + other.lines,
            trailingModel: other.trailingModel ?? trailingModel
        )
    }

    func prepending(_ earlier: CodexRawTokenParse) -> CodexRawTokenParse {
        var resolvedLater = lines
        if let carriedModel = earlier.trailingModel {
            for index in resolvedLater.indices where resolvedLater[index].modelSlug == nil {
                resolvedLater[index] = resolvedLater[index].withModelSlug(carriedModel)
            }
        }
        return CodexRawTokenParse(
            lines: earlier.lines + resolvedLater,
            trailingModel: trailingModel ?? earlier.trailingModel
        )
    }
}

/// One coherent suffix of an append-only Codex JSONL file. Every field is a
/// fact about file bytes; a caller's `now` is used only to decide whether this
/// artifact needs to be extended farther backward.
private struct CodexWeeklyHistoryArtifact: Sendable {
    let signature: RunwayFileSignature
    let device: UInt64
    let inode: UInt64
    let scanStart: UInt64
    let leadingFragment: Data
    let completeParse: CodexRawTokenParse
    let trailingFragment: Data
    let trailingFragmentIsTruncated: Bool
    let suffixGuard: Data
}

/// Per-path serialization keeps an append racing a refresh from corrupting the
/// history while allowing unrelated session files to parse concurrently.
private final class CodexWeeklyHistoryBox: @unchecked Sendable {
    let lock = NSLock()
    var artifact: CodexWeeklyHistoryArtifact?
}

private final class CodexWeeklyHistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var boxes: [String: CodexWeeklyHistoryBox] = [:]

    func box(for path: String) -> CodexWeeklyHistoryBox {
        lock.lock(); defer { lock.unlock() }
        if let box = boxes[path] { return box }
        let box = CodexWeeklyHistoryBox()
        boxes[path] = box
        return box
    }

    func retain(paths: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        boxes = boxes.filter { paths.contains($0.key) }
    }

    #if DEBUG
    func removeAllForTesting() {
        lock.lock(); defer { lock.unlock() }
        boxes.removeAll()
    }
    #endif
}

enum CodexRunwayTokenActivityParser {
    /// Upper bound on the backward hunt for a `turn_context`. Past this we give up
    /// and the session goes unpriced (dropped from $, still shown in tk/h) rather
    /// than risk pricing it at a guessed model.
    static let modelScanCap = 64 * 1024 * 1024
    static let maximumSampleAge: TimeInterval = 75
    static let minimumPairInterval: TimeInterval = 10
    static let maximumPairInterval: TimeInterval = 30 * 60
    /// `Wk` describes sustained quota consumption, not the latest turn's peak.
    /// Average over five minutes and withhold a number until at least one minute
    /// of wall-clock coverage exists.
    static let weeklyWindow: TimeInterval = 5 * 60
    static let weeklyMinimumCoverage: TimeInterval = 60
    /// Cold recovery is fail-safe and bounded: an unusually huge young session
    /// may keep showing "measuring", but it cannot make the five-second HUD poll
    /// read an arbitrarily large transcript into memory.
    static let weeklyHistoryScanCap = 64 * 1024 * 1024
    /// Only the adaptive Wk reader applies the structural type discriminator, and
    /// only to records large enough for full JSON deserialization to be material.
    private static let oversizedRecordThreshold = 64 * 1024

    private static let sampleCache = RunwayFileParseCache<CodexRawTokenParse>()
    /// Wk rows need a deeper history than the ordinary 512 KiB activity/ledger
    /// tail. This dedicated store also reuses append-only growth, so an image-heavy
    /// transcript does not reread its multi-megabyte history every five seconds.
    private static let weeklyHistoryStore = CodexWeeklyHistoryStore()

    #if DEBUG
    private static let weeklyReadCounterLock = NSLock()
    private static var weeklyPayloadBytesRead = 0
    static var sampleCacheMissCountForTesting: Int { sampleCache.missCount }
    static var weeklyPayloadBytesReadForTesting: Int {
        weeklyReadCounterLock.lock(); defer { weeklyReadCounterLock.unlock() }
        return weeklyPayloadBytesRead
    }
    static func resetSampleCacheForTesting() {
        sampleCache.removeAllForTesting()
        weeklyHistoryStore.removeAllForTesting()
        weeklyReadCounterLock.lock()
        weeklyPayloadBytesRead = 0
        weeklyReadCounterLock.unlock()
    }
    #endif

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 512 * 1024,
                              now: Date = Date()) -> [CodexRunwayTokenActivitySample] {
        let parsed: CodexRawTokenParse
        if let signature = RunwayFileSignature.read(path: path) {
            parsed = sampleCache.value(path: path, signature: signature) {
                parseRawLines(fromLogPath: path, maxBytes: maxBytes)
            }
        } else {
            parsed = parseRawLines(fromLogPath: path, maxBytes: maxBytes)
        }
        return parsed.lines
            .compactMap { finalize($0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Samples for the five-minute Wk row. A fixed byte tail is insufficient for
    /// image/tool-heavy sessions: one JSONL record can be several megabytes and
    /// squeeze five minutes of small `token_count` records out of a 512 KiB read.
    /// The read widens until it crosses the five-minute cutoff (or reaches the
    /// bounded scan cap). Unchanged files reuse the parsed result; append-only
    /// growth reads and parses only the newly appended byte range.
    /// This cache is deliberately not used by `ledgerEvents` (see above).
    static func recentWeeklySamples(fromLogPath path: String,
                                    initialMaxBytes: Int = 512 * 1024,
                                    now: Date = Date()) -> [CodexRunwayTokenActivitySample] {
        let parsed = weeklyRawParse(
            fromLogPath: path,
            initialMaxBytes: initialMaxBytes,
            now: now
        )
        // Weekly parsing widens until the relevant leading token has its actual
        // preceding context (or reaches the hard cap). Do not fill a missing model
        // from the unrelated global EOF cache: unresolved is deliberately unpriced.
        return parsed.lines
            .compactMap { finalize($0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Model in force immediately before the first complete record in the ordinary
    /// tail. Leading token records must inherit only this earlier context; using the
    /// first later `turn_context` reverses `/model` chronology and misprices an
    /// already-completed request. The cached frontier advances between JSONL record
    /// boundaries, so append-only growth scans only the newly crossed prefix bytes.
    private static func modelBeforeTailBoundary(path: String, boundary: UInt64) -> String? {
        guard boundary > 0 else { return nil }
        let identity = fileIdentity(path: path)
        let signature = RunwayFileSignature.read(path: path)
        modelCacheLock.lock()
        let entry = modelCacheByPath[path]
        modelCacheLock.unlock()

        if let entry,
           let identity,
           let signature,
           entry.device == identity.device,
           entry.inode == identity.inode,
           (signature == entry.signature || signature.size > entry.signature.size),
           suffixGuard(path: path, eof: entry.scannedThrough) == entry.boundaryGuard,
           entry.scannedThrough <= boundary,
           boundary - entry.scannedThrough <= UInt64(modelScanCap) {
            guard entry.scannedThrough < boundary else { return entry.model }
            guard let delta = readRange(path: path, from: entry.scannedThrough, to: boundary) else {
                return nil
            }
            let model = lastTurnContextModel(in: delta) ?? entry.model
            rememberModel(
                model, path: path, scannedThrough: boundary,
                identity: identity, signature: signature
            )
            return model
        }

        // Cold cache, a rewind caused by a wider caller tail, or a jump beyond the
        // bounded incremental scan: recover the latest preceding context directly.
        let lookup = lastModel(fromLogPath: path, endingAt: boundary)
        guard lookup.didRead else { return nil }   // read failed; don't remember it
        if let identity, let signature {
            rememberModel(
                lookup.model, path: path, scannedThrough: boundary,
                identity: identity, signature: signature
            )
        }
        return lookup.model
    }

    static func retainCache(paths: Set<String>) {
        sampleCache.retain(paths: paths)
        weeklyHistoryStore.retain(paths: paths)
        modelCacheLock.lock()
        modelCacheByPath = modelCacheByPath.filter { paths.contains($0.key) }
        modelCacheLock.unlock()
    }

    /// Per-path model plus the byte offset it was established at. `model == nil`
    /// records a scanned-but-genuinely-model-less file, so we stop re-scanning it,
    /// while `scannedThrough` still lets a later-appended `turn_context` be found.
    private struct ModelCacheEntry {
        let model: String?
        let scannedThrough: UInt64
        let device: UInt64
        let inode: UInt64
        let boundaryGuard: Data
        let signature: RunwayFileSignature
    }
    private static let modelCacheLock = NSLock()
    private static var modelCacheByPath: [String: ModelCacheEntry] = [:]

    private static func rememberModel(_ model: String?,
                                      path: String,
                                      scannedThrough: UInt64,
                                      identity: (device: UInt64, inode: UInt64),
                                      signature: RunwayFileSignature) {
        guard let boundaryGuard = suffixGuard(path: path, eof: scannedThrough) else { return }
        modelCacheLock.lock()
        modelCacheByPath[path] = ModelCacheEntry(
            model: model,
            scannedThrough: scannedThrough,
            device: identity.device,
            inode: identity.inode,
            boundaryGuard: boundaryGuard,
            signature: signature
        )
        modelCacheLock.unlock()
    }

    private static func fileSize(path: String) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    private static func readRange(path: String, from: UInt64, to: UInt64) -> Data? {
        guard to > from,
              to - from <= UInt64(Int.max),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        let expected = Int(to - from)
        var result = Data()
        result.reserveCapacity(expected)
        while result.count < expected {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: expected - result.count),
                      !next.isEmpty else { return nil }
                chunk = next
            } catch {
                return nil
            }
            result.append(chunk)
        }
        return result
    }

    #if DEBUG
    static func resetModelCacheForTesting() {
        modelCacheLock.lock(); modelCacheByPath.removeAll(); modelCacheLock.unlock()
    }
    #endif

    private static func parseRawLines(fromLogPath path: String,
                                      maxBytes: Int,
                                      skipOversizedNonCandidates: Bool = false) -> CodexRawTokenParse {
        guard let size = fileSize(path: path) else {
            return .empty
        }
        let byteCount = min(size, UInt64(max(1, maxBytes)))
        let rawStart = size - byteCount
        guard var data = readRangeAllowingEmpty(path: path, from: rawStart, to: size) else {
            return .empty
        }

        // A byte tail normally starts in the middle of a JSONL record. Drop that
        // fragment and anchor the model at the first complete record boundary.
        // (The old parser tried to decode the fragment and discarded it anyway.)
        var boundary = rawStart
        if rawStart > 0,
           readRange(path: path, from: rawStart - 1, to: rawStart)?.first != 0x0A {
            guard let newline = data.firstIndex(of: 0x0A) else { return .empty }
            let consumed = data.distance(from: data.startIndex, to: newline) + 1
            data.removeFirst(consumed)
            boundary += UInt64(consumed)
        }
        let initialModel = modelBeforeTailBoundary(path: path, boundary: boundary)
        return parseRawLines(
            data: data,
            logPath: path,
            initialModel: initialModel,
            skipOversizedNonCandidates: skipOversizedNonCandidates
        )
    }

    private static func parseRawLines(data: Data,
                                      logPath path: String,
                                      initialModel: String? = nil,
                                      skipOversizedNonCandidates: Bool = false) -> CodexRawTokenParse {
        // A tail/range can begin in the middle of a UTF-8 scalar. Lossy decoding
        // only affects that already-incomplete first JSONL fragment; every complete
        // line after its newline remains byte-for-byte parseable.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }
        return parseRawLines(
            lines: lines,
            logPath: path,
            initialModel: initialModel,
            skipOversizedNonCandidates: skipOversizedNonCandidates
        )
    }

    private static func parseRawLines(lines: [Data],
                                      logPath path: String,
                                      initialModel: String? = nil,
                                      skipOversizedNonCandidates: Bool) -> CodexRawTokenParse {
        // Codex logs the model on `turn_context` lines, not on `token_count`
        // lines, so track the latest-seen model in file order and stamp it onto
        // subsequent token lines. Pure function of the bytes → still cacheable.
        var out: [CodexRawTokenLine] = []
        var lastModel = initialModel
        for data in lines where !data.isEmpty {
            if skipOversizedNonCandidates, data.count > oversizedRecordThreshold,
               !hasRelevantEnvelopeType(data) {
                continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if isTurnContext(obj: obj, payload: payload),
               let model = modelSlug(from: payload) ?? modelSlug(from: obj) {
                lastModel = model
            }
            // Codex writes both a per-request `token_usage_record` and a cumulative
            // `token_count` for the same response. This parser differences adjacent
            // samples as cumulative counters, so admitting the incremental record
            // re-adds nearly the whole session on every response. Positively select
            // only the cumulative family, including the legacy top-level envelope.
            guard isCumulativeTokenCount(obj: obj, payload: payload) else { continue }
            if let line = tokenLine(obj: obj, payload: payload, logPath: path, model: lastModel) {
                out.append(line)
            }
        }
        return CodexRawTokenParse(lines: out, trailingModel: lastModel)
    }

    private static func weeklyRawParse(fromLogPath path: String,
                                       initialMaxBytes: Int,
                                       now: Date) -> CodexRawTokenParse {
        let box = weeklyHistoryStore.box(for: path)
        box.lock.lock(); defer { box.lock.unlock() }

        // One bounded retry covers the ordinary append-during-read race. A second
        // moving target fails closed for this five-second refresh; returning a
        // candidate assembled from two file generations could fabricate a delta.
        for attempt in 0..<2 {
            guard let signature = RunwayFileSignature.read(path: path),
                  let startingIdentity = fileIdentity(path: path) else { return .empty }
            var artifact: CodexWeeklyHistoryArtifact?
            if let cached = box.artifact,
               cached.signature == signature,
               cached.device == startingIdentity.device,
               cached.inode == startingIdentity.inode {
                artifact = cached
            } else if let cached = box.artifact {
                artifact = appendWeeklyArtifact(
                    cached,
                    path: path,
                    signature: signature
                )
            }
            if artifact == nil {
                artifact = coldWeeklyArtifact(
                    path: path,
                    signature: signature,
                    maxBytes: min(max(1, initialMaxBytes), weeklyHistoryScanCap)
                )
            }
            guard var artifact else { return .empty }

            // The cached object remains time-independent. An older/out-of-order
            // `now` asks it for more byte history and replaces it with a larger
            // bytes-derived suffix; no cutoff-filtered value is ever cached.
            while weeklyArtifactNeedsMoreHistory(artifact, path: path, now: now) {
                let scanned = signature.size - artifact.scanStart
                guard artifact.scanStart > 0,
                      scanned < UInt64(weeklyHistoryScanCap) else { break }
                guard let wider = extendWeeklyArtifactBackward(
                    artifact,
                    path: path,
                    minimumChunkBytes: max(1, initialMaxBytes)
                ), wider.scanStart < artifact.scanStart else { break }
                artifact = wider
            }

            guard RunwayFileSignature.read(path: path) == signature,
                  let endingIdentity = fileIdentity(path: path),
                  endingIdentity.device == artifact.device,
                  endingIdentity.inode == artifact.inode else {
                if attempt == 0 { continue }
                return .empty
            }
            box.artifact = artifact
            return materializedWeeklyParse(artifact, path: path)
        }
        return .empty
    }

    private static func coldWeeklyArtifact(path: String,
                                           signature: RunwayFileSignature,
                                           maxBytes: Int) -> CodexWeeklyHistoryArtifact? {
        guard let identity = fileIdentity(path: path) else { return nil }
        let byteCount = min(signature.size, UInt64(max(1, maxBytes)))
        let start = signature.size - byteCount
        let startsAtBoundary: Bool
        if start == 0 {
            startsAtBoundary = true
        } else {
            startsAtBoundary = readRange(path: path, from: start - 1, to: start)?.first == 0x0A
        }
        guard let data = readRangeAllowingEmpty(path: path, from: start, to: signature.size) else {
            return nil
        }
        recordWeeklyPayloadRead(data.count)
        let framed = frameJSONL(data, discardLeadingFragment: !startsAtBoundary)
        let complete = parseRawLines(
            lines: framed.lines,
            logPath: path,
            skipOversizedNonCandidates: true
        )
        return CodexWeeklyHistoryArtifact(
            signature: signature,
            device: identity.device,
            inode: identity.inode,
            scanStart: start,
            leadingFragment: framed.leadingFragment,
            completeParse: complete,
            trailingFragment: framed.trailingFragment,
            trailingFragmentIsTruncated: framed.trailingFragmentIsTruncated,
            suffixGuard: suffixGuard(path: path, eof: signature.size) ?? Data()
        )
    }

    /// Extends a cold/out-of-order history hunt with a disjoint earlier range.
    /// The saved leading fragment reconstructs the one JSONL record split by the
    /// old frontier, so a 16 MiB result reads about 16 MiB total rather than
    /// reparsing 0.5 + 1 + 2 + 4 + 8 + 16 MiB overlapping tails.
    private static func extendWeeklyArtifactBackward(
        _ artifact: CodexWeeklyHistoryArtifact,
        path: String,
        minimumChunkBytes: Int
    ) -> CodexWeeklyHistoryArtifact? {
        let represented = artifact.signature.size - artifact.scanStart
        let remainingBudget = UInt64(weeklyHistoryScanCap) - represented
        guard artifact.scanStart > 0, remainingBudget > 0 else { return nil }
        let desired = max(represented, UInt64(max(1, minimumChunkBytes)))
        let chunkSize = min(artifact.scanStart, remainingBudget, desired)
        let newStart = artifact.scanStart - chunkSize
        guard let chunk = readRange(path: path, from: newStart, to: artifact.scanStart) else {
            return nil
        }
        recordWeeklyPayloadRead(chunk.count)
        var joined = chunk
        joined.append(artifact.leadingFragment)
        let startsAtBoundary = newStart == 0
            || readRange(path: path, from: newStart - 1, to: newStart)?.first == 0x0A
        let framed = frameJSONL(joined, discardLeadingFragment: !startsAtBoundary)
        let earlier = parseRawLines(
            lines: framed.lines,
            logPath: path,
            skipOversizedNonCandidates: true
        )
        let extendsSingleTruncatedRecord = artifact.trailingFragmentIsTruncated
        return CodexWeeklyHistoryArtifact(
            signature: artifact.signature,
            device: artifact.device,
            inode: artifact.inode,
            scanStart: newStart,
            leadingFragment: framed.leadingFragment,
            completeParse: artifact.completeParse.prepending(earlier),
            trailingFragment: extendsSingleTruncatedRecord
                ? framed.trailingFragment
                : artifact.trailingFragment,
            trailingFragmentIsTruncated: extendsSingleTruncatedRecord
                ? framed.trailingFragmentIsTruncated
                : artifact.trailingFragmentIsTruncated,
            suffixGuard: artifact.suffixGuard
        )
    }

    private static func appendWeeklyArtifact(_ artifact: CodexWeeklyHistoryArtifact,
                                             path: String,
                                             signature: RunwayFileSignature)
        -> CodexWeeklyHistoryArtifact? {
        guard signature.size > artifact.signature.size,
              signature.size - artifact.signature.size <= UInt64(weeklyHistoryScanCap),
              signature.size - artifact.scanStart <= UInt64(weeklyHistoryScanCap),
              let identity = fileIdentity(path: path),
              identity.device == artifact.device,
              identity.inode == artifact.inode,
              suffixGuard(path: path, eof: artifact.signature.size) == artifact.suffixGuard,
              let delta = readRangeAllowingEmpty(
                path: path,
                from: artifact.signature.size,
                to: signature.size
              ) else { return nil }
        recordWeeklyPayloadRead(delta.count)

        var combined = artifact.trailingFragment
        combined.append(delta)
        // A writer can spend several polls constructing one enormous JSON value.
        // Never let the saved partial line grow past the same fail-safe as a cold
        // history hunt; rebuild the bounded suffix and mark its front truncated.
        if combined.count > weeklyHistoryScanCap {
            return coldWeeklyArtifact(
                path: path,
                signature: signature,
                maxBytes: weeklyHistoryScanCap
            )
        }
        let framed = frameJSONL(
            combined,
            discardLeadingFragment: artifact.trailingFragmentIsTruncated
        )
        let appended = parseRawLines(
            lines: framed.lines,
            logPath: path,
            initialModel: artifact.completeParse.trailingModel,
            skipOversizedNonCandidates: true
        )
        return CodexWeeklyHistoryArtifact(
            signature: signature,
            device: identity.device,
            inode: identity.inode,
            scanStart: artifact.scanStart,
            leadingFragment: artifact.leadingFragment,
            completeParse: artifact.completeParse.appending(appended),
            trailingFragment: framed.trailingFragment,
            trailingFragmentIsTruncated: framed.trailingFragmentIsTruncated,
            suffixGuard: suffixGuard(path: path, eof: signature.size) ?? Data()
        )
    }

    private static func materializedWeeklyParse(_ artifact: CodexWeeklyHistoryArtifact,
                                                path: String) -> CodexRawTokenParse {
        guard !artifact.trailingFragment.isEmpty,
              !artifact.trailingFragmentIsTruncated else {
            return artifact.completeParse
        }
        // Preserve the historic behavior for a complete JSON value without a final
        // newline. It is provisional: an append reparses the saved bytes together
        // with the delta, so a genuinely incomplete record cannot poison the cache.
        let provisional = parseRawLines(
            lines: [artifact.trailingFragment],
            logPath: path,
            initialModel: artifact.completeParse.trailingModel,
            skipOversizedNonCandidates: true
        )
        return artifact.completeParse.appending(provisional)
    }

    private static func weeklyArtifactNeedsMoreHistory(_ artifact: CodexWeeklyHistoryArtifact,
                                                       path: String,
                                                       now: Date) -> Bool {
        let parsed = materializedWeeklyParse(artifact, path: path)
        guard rawCrossesWeeklyCutoff(parsed.lines, now: now) else { return true }
        let cutoff = now.addingTimeInterval(-weeklyWindow)
        return parsed.lines.contains { line in
            guard let capturedAt = line.createdAtReal,
                  capturedAt >= cutoff,
                  capturedAt <= now else { return false }
            return line.modelSlug == nil
        }
    }

    private static func rawCrossesWeeklyCutoff(_ raw: [CodexRawTokenLine],
                                               now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-weeklyWindow)
        return raw.contains { line in
            guard let capturedAt = line.createdAtReal else { return false }
            return capturedAt <= cutoff
        }
    }

    private struct JSONLFrame {
        let leadingFragment: Data
        let lines: [Data]
        let trailingFragment: Data
        let trailingFragmentIsTruncated: Bool
    }

    /// Splits only on literal LF bytes, preserving an unterminated EOF record for
    /// the next append. When a tail starts mid-record, that first fragment remains
    /// marked truncated until its LF arrives and is discarded as one unit.
    private static func frameJSONL(_ data: Data,
                                   discardLeadingFragment: Bool) -> JSONLFrame {
        var lines: [Data] = []
        var leadingFragment = Data()
        var lineStart = 0
        var dropCurrent = discardLeadingFragment
        for (offset, byte) in data.enumerated() where byte == 0x0A {
            if dropCurrent {
                leadingFragment = data.subdata(in: lineStart..<(offset + 1))
            } else if offset > lineStart {
                lines.append(data.subdata(in: lineStart..<offset))
            }
            dropCurrent = false
            lineStart = offset + 1
        }
        let trailing = lineStart < data.count
            ? data.subdata(in: lineStart..<data.count)
            : Data()
        if dropCurrent { leadingFragment = trailing }
        return JSONLFrame(
            leadingFragment: leadingFragment,
            lines: lines,
            trailingFragment: trailing,
            trailingFragmentIsTruncated: dropCurrent
        )
    }

    private static func readRangeAllowingEmpty(path: String,
                                               from: UInt64,
                                               to: UInt64) -> Data? {
        guard to >= from else { return nil }
        if to == from { return Data() }
        return readRange(path: path, from: from, to: to)
    }

    private static func recordWeeklyPayloadRead(_ count: Int) {
        #if DEBUG
        weeklyReadCounterLock.lock()
        weeklyPayloadBytesRead += count
        weeklyReadCounterLock.unlock()
        #endif
    }

    private static func fileIdentity(path: String) -> (device: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return (device, inode)
    }

    private static func suffixGuard(path: String, eof: UInt64) -> Data? {
        let guardSize: UInt64 = 4 * 1024
        return readRangeAllowingEmpty(
            path: path,
            from: eof > guardSize ? eof - guardSize : 0,
            to: eof
        )
    }

    /// Huge response/tool records dominate transcript bytes. Before paying for a
    /// full JSON object, scan JSON strings structurally for an outer or direct
    /// payload `type`. Escaped quotes inside a content string are skipped, while a
    /// valid discriminator remains discoverable regardless of key order or offset.
    private static func hasRelevantEnvelopeType(_ data: Data) -> Bool {
        let bytes = data
        var index = 0
        var objectDepth = 0
        var payloadDepth: Int?
        var pendingKeyByDepth: [Int: String] = [:]

        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: // {
                let parentDepth = objectDepth
                let containerKey = pendingKeyByDepth.removeValue(forKey: parentDepth)
                objectDepth += 1
                if parentDepth == 1, containerKey == "payload" {
                    payloadDepth = objectDepth
                }
                index += 1
            case 0x7D: // }
                pendingKeyByDepth.removeValue(forKey: objectDepth)
                if payloadDepth == objectDepth { payloadDepth = nil }
                objectDepth = max(0, objectDepth - 1)
                index += 1
            case 0x5B: // [
                pendingKeyByDepth.removeValue(forKey: objectDepth)
                index += 1
            case 0x2C: // ,
                pendingKeyByDepth.removeValue(forKey: objectDepth)
                index += 1
            case 0x22: // "
                let token = scanJSONString(bytes, openingQuote: index)
                var next = token.nextIndex
                while next < bytes.count,
                      bytes[next] == 0x20 || bytes[next] == 0x09
                        || bytes[next] == 0x0D || bytes[next] == 0x0A {
                    next += 1
                }
                if next < bytes.count, bytes[next] == 0x3A { // :
                    if let value = token.value {
                        pendingKeyByDepth[objectDepth] = value
                    } else {
                        pendingKeyByDepth.removeValue(forKey: objectDepth)
                    }
                    index = next + 1
                    continue
                }
                if pendingKeyByDepth[objectDepth] == "type",
                   objectDepth == 1 || objectDepth == payloadDepth,
                   token.value == "token_count" || token.value == "turn_context" {
                    return true
                }
                pendingKeyByDepth.removeValue(forKey: objectDepth)
                index = token.nextIndex
            default:
                index += 1
            }
        }
        return false
    }

    private static func scanJSONString(_ bytes: Data,
                                       openingQuote: Int)
        -> (value: String?, nextIndex: Int) {
        var index = openingQuote + 1
        var value: [UInt8] = []
        var canMaterialize = true
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C { // escaped byte; irrelevant for our ASCII keys/types
                canMaterialize = false
                index = min(bytes.count, index + 2)
                continue
            }
            if byte == 0x22 {
                let string = canMaterialize ? String(bytes: value, encoding: .utf8) : nil
                return (string, index + 1)
            }
            if value.count < 64 {
                value.append(byte)
            } else {
                canMaterialize = false
            }
            index += 1
        }
        return (nil, bytes.count)
    }

    private static func isCumulativeTokenCount(obj: [String: Any],
                                                payload: [String: Any]) -> Bool {
        (payload["type"] as? String) == "token_count"
            || (obj["type"] as? String) == "token_count"
    }

    private static func isTurnContext(obj: [String: Any],
                                      payload: [String: Any]) -> Bool {
        (payload["type"] as? String) == "turn_context"
            || (obj["type"] as? String) == "turn_context"
    }

    /// The model in force at a JSONL boundary: the model on the last preceding
    /// `turn_context`. Widen backward progressively because one tool/image record
    /// can put megabytes between the boundary and its context.
    ///
    /// `didRead` separates "scanned the bytes, no `turn_context` there" (cacheable)
    /// from "couldn't read the file" (transient), so only the former is remembered.
    private static func lastModel(fromLogPath path: String,
                                  endingAt boundary: UInt64) -> (model: String?, didRead: Bool) {
        var window = 2 * 1024 * 1024   // the 512KB token tail already came up empty
        while true {
            let start = boundary > UInt64(window) ? boundary - UInt64(window) : 0
            guard let data = readRangeAllowingEmpty(path: path, from: start, to: boundary) else {
                return (nil, false)
            }
            if let model = lastTurnContextModel(in: data) { return (model, true) }
            if start == 0 { return (nil, true) }
            guard window < modelScanCap else { return (nil, true) }
            window = min(window * 4, modelScanCap)
        }
    }

    /// Scans lines back-to-front for the newest `turn_context` carrying a model. The
    /// substring prefilter keeps this from JSON-parsing millions of unrelated lines.
    private static func lastTurnContextModel(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard raw.contains("turn_context") else { continue }
            guard let d = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if let m = modelSlug(from: payload) ?? modelSlug(from: obj) { return m }
        }
        return nil
    }

    private static func finalize(_ raw: CodexRawTokenLine, now: Date) -> CodexRunwayTokenActivitySample? {
        let capturedAt = raw.createdAtReal ?? now
        guard capturedAt <= now.addingTimeInterval(5) else { return nil }
        return CodexRunwayTokenActivitySample(
            logPath: raw.logPath,
            capturedAt: capturedAt,
            totalTokens: raw.totalTokens,
            input: raw.input,
            cachedInput: raw.cachedInput,
            output: raw.output,
            modelSlug: raw.modelSlug
        )
    }

    static func activity(identity: RunwaySessionIdentity,
                         now: Date = Date()) -> RunwaySessionActivity? {
        let pathActivities = identity.logPaths.compactMap { path -> RunwaySessionActivity? in
            let samples = recentSamples(fromLogPath: path, now: now)
            return activity(identity: identity, samples: samples, now: now)
        }
        guard !pathActivities.isEmpty else { return nil }
        let tokensPerSecond = pathActivities.reduce(0) { $0 + $1.tokensPerSecond }
        guard tokensPerSecond > 0, tokensPerSecond.isFinite else { return nil }
        return RunwaySessionActivity(
            identity: identity,
            tokensPerSecond: tokensPerSecond,
            sampleStart: pathActivities.map(\.sampleStart).min() ?? now,
            sampleEnd: pathActivities.map(\.sampleEnd).max() ?? now,
            // Each contributing path keeps its OWN model, so $ prices a parent and
            // its subagents at their real rates instead of blending them all into
            // whichever path happened to sort first. Totals derive from these.
            components: pathActivities.flatMap(\.components)
        )
    }

    static func burns(identities: [RunwaySessionIdentity],
                      baseline: RunwayProviderBaseline,
                      now: Date = Date()) -> [RunwaySessionBurn] {
        burns(activities: activities(identities: identities, now: now), baseline: baseline)
    }

    /// Per-identity token activity, computed once per cycle so callers that need
    /// both the per-session burns and the aggregate throughput don't parse each
    /// session log twice (see `CodexRunwaySnapshotLoader.snapshot`).
    static func activities(identities: [RunwaySessionIdentity],
                           now: Date = Date()) -> [RunwaySessionActivity] {
        identities.compactMap { activity(identity: $0, now: now) }
    }

    static func weeklyProfile(identities: [RunwaySessionIdentity],
                              now: Date = Date())
        -> (activities: [RunwaySessionActivity], measuringIDs: Set<String>) {
        var activities: [RunwaySessionActivity] = []
        var measuringIDs: Set<String> = []
        for identity in identities {
            let paths = identity.logPaths.map { recentWeeklySamples(fromLogPath: $0, now: now) }
            let pathActivities = paths.compactMap {
                weeklyActivity(identity: identity, samples: $0, now: now)
            }
            if !pathActivities.isEmpty {
                let tokensPerSecond = pathActivities.reduce(0) { $0 + $1.tokensPerSecond }
                activities.append(RunwaySessionActivity(
                    identity: identity,
                    tokensPerSecond: tokensPerSecond,
                    sampleStart: pathActivities.map(\.sampleStart).min() ?? now,
                    sampleEnd: pathActivities.map(\.sampleEnd).max() ?? now,
                    components: pathActivities.flatMap(\.components)
                ))
            } else if paths.contains(where: { weeklyEvidenceIsMeasuring($0, now: now) }) {
                measuringIDs.insert(identity.id)
            }
        }
        return (activities, measuringIDs)
    }

    /// Latest CUMULATIVE counters per log path, for the weekly calibration ledger.
    ///
    /// Cumulative rather than a rate on purpose: the ledger banks deltas between
    /// cycles, so a session that burns hard and then ends keeps its contribution in
    /// the calibration denominator instead of vanishing with its live identity.
    /// Integrating a point-in-time `tokensPerSecond` instead would reintroduce
    /// exactly the stale-rate attribution this design removes.
    static func ledgerObservations(identities: [RunwaySessionIdentity],
                                   now: Date = Date()) -> [WeeklyQuotaTokenObservation] {
        var seen: Set<String> = []
        var result: [WeeklyQuotaTokenObservation] = []
        for path in identities.flatMap(\.logPaths) where !seen.contains(path) {
            seen.insert(path)
            guard let latest = recentSamples(fromLogPath: path, now: now).last else { continue }
            result.append(WeeklyQuotaTokenObservation(
                logPath: path,
                capturedAt: latest.capturedAt,
                // Codex `input_tokens` INCLUDES cached reads, so fresh input is the
                // difference — same normalization `activity(_:)` applies, so the
                // ledger and `$` price identical token volumes.
                input: max(0, latest.input - latest.cachedInput),
                cachedInput: latest.cachedInput,
                output: latest.output,
                cacheCreation: 0,
                modelSlug: latest.modelSlug
            ))
        }
        return result
    }

    /// Incremental Codex turns for calibration. Keeping request boundaries lets
    /// pricing apply Sol's long-context tier to the whole request when its input
    /// exceeds 272K, rather than treating a polling bucket as one request.
    static func ledgerEvents(identities: [RunwaySessionIdentity],
                             now: Date = Date()) -> [WeeklyQuotaTokenEvent] {
        var seen: Set<String> = []
        var result: [WeeklyQuotaTokenEvent] = []
        for path in identities.flatMap(\.logPaths) where !seen.contains(path) {
            seen.insert(path)
            let samples = recentSamples(fromLogPath: path, now: now)
            for (previous, current) in zip(samples, samples.dropFirst()) {
                let totalInput = max(0, current.input - previous.input)
                let cached = max(0, current.cachedInput - previous.cachedInput)
                let fresh = max(0, totalInput - cached)
                let output = max(0, current.output - previous.output)
                guard fresh + cached + output > 0 else { continue }
                result.append(WeeklyQuotaTokenEvent(
                    logPath: path,
                    capturedAt: current.capturedAt,
                    input: fresh,
                    cachedInput: cached,
                    output: output,
                    cacheCreation: 0,
                    modelSlug: current.modelSlug,
                    contextInputTokens: totalInput
                ))
            }
        }
        return result
    }

    static func burns(activities: [RunwaySessionActivity],
                      baseline: RunwayProviderBaseline) -> [RunwaySessionBurn] {
        let currentSeconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        guard currentSeconds > 0, baseline.remainingPercent > 0 else { return [] }
        let providerRate = baseline.remainingPercent / currentSeconds
        guard providerRate > 0, providerRate.isFinite else { return [] }

        let totalTokenRate = activities.reduce(0) { $0 + $1.tokensPerSecond }
        guard totalTokenRate > 0, totalTokenRate.isFinite else { return [] }

        return activities.map { activity in
            RunwaySessionBurn(
                identity: activity.identity,
                percentPerSecond: providerRate * (activity.tokensPerSecond / totalTokenRate),
                confidence: .mixed,
                sampleStart: activity.sampleStart,
                sampleEnd: activity.sampleEnd
            )
        }
    }

    private static func activity(identity: RunwaySessionIdentity,
                                 samples: [CodexRunwayTokenActivitySample],
                                 now: Date) -> RunwaySessionActivity? {
        guard samples.count >= 2 else { return nil }
        for pair in zip(samples.dropLast().reversed(), samples.dropFirst().reversed()) {
            let previous = pair.0
            let current = pair.1
            guard now.timeIntervalSince(current.capturedAt) <= maximumSampleAge else { continue }
            let elapsed = current.capturedAt.timeIntervalSince(previous.capturedAt)
            guard elapsed >= minimumPairInterval, elapsed <= maximumPairInterval else { continue }
            let delta = current.totalTokens - previous.totalTokens
            guard delta > 0 else { continue }
            return RunwaySessionActivity(
                identity: identity,
                tokensPerSecond: delta / elapsed,
                sampleStart: previous.capturedAt,
                sampleEnd: current.capturedAt,
                // FRESH (non-cached) input, so both providers share one shape and
                // dollarSnapshot prices per-type with no subtraction. Codex
                // `input_tokens` includes cached, so subtract cached here.
                inputPerSecond: max(0, (current.input - current.cachedInput) - (previous.input - previous.cachedInput)) / elapsed,
                cachedInputPerSecond: max(0, current.cachedInput - previous.cachedInput) / elapsed,
                outputPerSecond: max(0, current.output - previous.output) / elapsed,
                cacheCreationPerSecond: 0,
                modelSlug: current.modelSlug,
                contextInputTokens: max(0, current.input - previous.input)
            )
        }
        return nil
    }

    private static func weeklyEvidenceIsMeasuring(_ samples: [CodexRunwayTokenActivitySample],
                                                   now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-weeklyWindow)
        guard let first = samples.first(where: { $0.capturedAt >= cutoff }) else { return false }
        return now.timeIntervalSince(first.capturedAt) < weeklyMinimumCoverage
    }

    static func weeklyActivity(identity: RunwaySessionIdentity,
                               samples: [CodexRunwayTokenActivitySample],
                               now: Date) -> RunwaySessionActivity? {
        let cutoff = now.addingTimeInterval(-weeklyWindow)
        let recent = samples.filter { $0.capturedAt >= cutoff && $0.capturedAt <= now }
        guard recent.count >= 2, let first = recent.first, let last = recent.last else { return nil }
        let coverage = now.timeIntervalSince(first.capturedAt)
        guard coverage >= weeklyMinimumCoverage, coverage <= weeklyWindow else { return nil }
        // A linearly decayed window makes the estimate fall on every refresh after
        // a burst, while the normalization keeps a steady request stream unbiased.
        let normalization = coverage - (coverage * coverage) / (2 * weeklyWindow)
        guard normalization > 0 else { return nil }

        var total = 0.0
        var components: [RunwayModelComponent] = []
        for (previous, current) in zip(recent, recent.dropFirst()) {
            let delta = current.totalTokens - previous.totalTokens
            guard delta > 0 else { continue }
            let weight = max(0, 1 - now.timeIntervalSince(current.capturedAt) / weeklyWindow)
            guard weight > 0 else { continue }
            total += delta * weight
            components.append(RunwayModelComponent(
                modelSlug: current.modelSlug,
                inputPerSecond: max(0, (current.input - current.cachedInput)
                    - (previous.input - previous.cachedInput)) * weight / normalization,
                cachedInputPerSecond: max(0, current.cachedInput - previous.cachedInput) * weight / normalization,
                outputPerSecond: max(0, current.output - previous.output) * weight / normalization,
                cacheCreationPerSecond: 0,
                contextInputTokens: max(0, current.input - previous.input)
            ))
        }
        guard total > 0 else { return nil }
        return RunwaySessionActivity(
            identity: identity,
            tokensPerSecond: total / normalization,
            sampleStart: first.capturedAt,
            sampleEnd: last.capturedAt,
            components: components
        )
    }

    private static func tokenLine(obj: [String: Any], payload: [String: Any],
                                  logPath: String, model: String?) -> CodexRawTokenLine? {
        let createdAtReal = CodexRunwayRateLimitParser.flexibleDate(obj["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(obj["timestamp"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["timestamp"])
        guard let totalTokens = totalTokens(from: payload) ?? totalTokens(from: obj) else {
            return nil
        }
        let perType = perTypeTokens(from: payload) ?? perTypeTokens(from: obj)
        return CodexRawTokenLine(
            logPath: logPath,
            createdAtReal: createdAtReal,
            totalTokens: totalTokens,
            input: perType?.input ?? 0,
            cachedInput: perType?.cachedInput ?? 0,
            output: perType?.output ?? 0,
            modelSlug: model
        )
    }

    /// Cumulative per-type counts (input incl. cached, cached subset, output),
    /// walking the same nesting as `totalTokens`. nil when the object has no
    /// per-type breakdown (e.g. `info: null`), so $ pricing degrades to token.
    private static func perTypeTokens(from dict: [String: Any]) -> (input: Double, cachedInput: Double, output: Double)? {
        if let t = perTypeDirect(from: dict) { return t }
        if let info = dict["info"] as? [String: Any], let t = perTypeTokens(from: info) { return t }
        if let total = dict["total_token_usage"] as? [String: Any], let t = perTypeDirect(from: total) { return t }
        if let usage = dict["usage"] as? [String: Any], let t = perTypeDirect(from: usage) { return t }
        return nil
    }

    private static func perTypeDirect(from dict: [String: Any]) -> (input: Double, cachedInput: Double, output: Double)? {
        guard let input = CodexRunwayRateLimitParser.double(dict["input_tokens"]),
              let output = CodexRunwayRateLimitParser.double(dict["output_tokens"]) else { return nil }
        let cached = CodexRunwayRateLimitParser.double(dict["cached_input_tokens"]) ?? 0
        return (input, cached, output)
    }

    private static func modelSlug(from dict: [String: Any]) -> String? {
        guard let m = dict["model"] as? String, !m.isEmpty else { return nil }
        return m
    }

    private static func totalTokens(from dict: [String: Any]) -> Double? {
        if let value = nettedTotal(from: dict) {
            return value
        }
        if let info = dict["info"] as? [String: Any],
           let value = totalTokens(from: info) {
            return value
        }
        if let total = dict["total_token_usage"] as? [String: Any],
           let value = nettedTotal(from: total) {
            return value
        }
        if let usage = dict["usage"] as? [String: Any],
           let value = nettedTotal(from: usage) {
            return value
        }
        return nil
    }

    /// `total_tokens` with cached input netted out. Codex's cumulative
    /// `total_tokens` re-counts the entire cached context every turn, so raw
    /// deltas between samples wildly overstate real generation (a ~200K context
    /// re-sent 4×/min reads as ~48M tk/h). Subtracting the also-cumulative
    /// `cached_input_tokens` makes the delta reflect fresh input + output — the
    /// honest throughput. Falls back to the raw total when no cached field exists.
    private static func nettedTotal(from dict: [String: Any]) -> Double? {
        guard let total = CodexRunwayRateLimitParser.double(dict["total_tokens"]) else { return nil }
        let cached = CodexRunwayRateLimitParser.double(dict["cached_input_tokens"]) ?? 0
        return max(0, total - cached)
    }
}
