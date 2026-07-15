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
    /// Per-session share of the weekly average burn, expressed as % of the weekly
    /// window per hour. Used by the "weekly" runway presentation.
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
    /// weekly → token when the weekly average is unmeasurable) so the whole
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
struct RunwayModelComponent: Equatable, Sendable {
    let modelSlug: String?
    let inputPerSecond: Double        // FRESH (non-cached) input
    let cachedInputPerSecond: Double
    let outputPerSecond: Double
    let cacheCreationPerSecond: Double

    var totalPerSecond: Double {
        inputPerSecond + cachedInputPerSecond + outputPerSecond + cacheCreationPerSecond
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
    /// is Claude cache writes (0 for Codex). Derived — never set directly.
    let inputPerSecond: Double
    let cachedInputPerSecond: Double
    let outputPerSecond: Double
    let cacheCreationPerSecond: Double

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
         modelSlug: String? = nil) {
        self.init(identity: identity,
                  tokensPerSecond: tokensPerSecond,
                  sampleStart: sampleStart,
                  sampleEnd: sampleEnd,
                  components: [RunwayModelComponent(modelSlug: modelSlug,
                                                    inputPerSecond: inputPerSecond,
                                                    cachedInputPerSecond: cachedInputPerSecond,
                                                    outputPerSecond: outputPerSecond,
                                                    cacheCreationPerSecond: cacheCreationPerSecond)])
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

    init(baseline: RunwayProviderBaseline,
         identities: [RunwaySessionIdentity],
         now: Date,
         maxRows: Int,
         recentSessionsRoot: URL? = nil) {
        self.baseline = baseline
        self.identities = identities
        self.now = now
        self.maxRows = maxRows
        self.recentSessionsRoot = recentSessionsRoot
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
                let scannerIdentities = CodexRunwayRecentSessionScanner.identities(
                    root: request.recentSessionsRoot,
                    now: request.now
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
                let core: CodexRunwaySnapshot?
                // The rendered unit comes from the snapshot's baseline; on a
                // snapshot-wide fallback we swap it so rows never mislabel.
                var effectiveBaseline = request.baseline
                // Identities eligible for a pending row. $ mode narrows this to the
                // ones it can actually price (see .dollarsPerHour below).
                var pendingIdentities = identities
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
                    // Per-session share of the weekly average burn. When the weekly
                    // average is unmeasurable (fresh window / 0% used) fall back to
                    // token throughput snapshot-wide (P6) with a token baseline.
                    if let weekly = CodexRunwayCalculator.weeklySnapshot(
                        baseline: request.baseline,
                        activities: activities,
                        maxRows: request.maxRows
                    ) {
                        core = weekly
                    } else {
                        effectiveBaseline = request.baseline.with(rateUnit: .tokensPerHour)
                        core = CodexRunwayCalculator.tokenSnapshot(
                            baseline: effectiveBaseline,
                            activities: activities,
                            maxRows: request.maxRows
                        )
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
                var snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: effectiveBaseline,
                    snapshot: core,
                    activeIdentities: pendingIdentities,
                    maxRows: request.maxRows
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

    static func withPendingRows(baseline: RunwayProviderBaseline,
                                snapshot: CodexRunwaySnapshot?,
                                activeIdentities: [RunwaySessionIdentity],
                                maxRows: Int) -> CodexRunwaySnapshot? {
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
                // Idle sessions show a calm "—"; still-working ones show a spinner.
                confidence: identity.isIdle ? .idle : .waiting
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

    /// Weekly-mode snapshot: each session's **share of the weekly average burn**,
    /// as % of the weekly window per hour. The provider weekly rate comes from the
    /// baseline (remaining% ÷ time-to-weekly-runout — the smoothed average-burn set
    /// by the builder), attributed per session by token share. Returns `nil` when
    /// the weekly average is unmeasurable (0% used / no run-out) so the loader can
    /// fall back to token mode snapshot-wide. Historical share, not instantaneous
    /// pace (labeled as such in the UI).
    static func weeklySnapshot(baseline: RunwayProviderBaseline,
                               activities: [RunwaySessionActivity],
                               maxRows: Int) -> CodexRunwaySnapshot? {
        guard maxRows > 0 else { return nil }
        let seconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        guard seconds > 0, baseline.remainingPercent > 0 else { return nil }
        let providerPercentPerHour = (baseline.remainingPercent / seconds) * 3600
        guard providerPercentPerHour > 0, providerPercentPerHour.isFinite else { return nil }

        let positive = activities.filter { $0.tokensPerSecond > 0 && $0.tokensPerSecond.isFinite }
        guard !positive.isEmpty else { return nil }
        let totalTPS = positive.reduce(0) { $0 + $1.tokensPerSecond }
        guard totalTPS > 0, totalTPS.isFinite else { return nil }

        let ranked = positive.sorted { lhs, rhs in
            if lhs.tokensPerSecond != rhs.tokensPerSecond {
                return lhs.tokensPerSecond > rhs.tokensPerSecond
            }
            if lhs.identity.isGoal != rhs.identity.isGoal {
                return lhs.identity.isGoal && !rhs.identity.isGoal
            }
            return lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName) == .orderedAscending
        }
        func rate(_ a: RunwaySessionActivity) -> Double { providerPercentPerHour * (a.tokensPerSecond / totalTPS) }
        let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
        let rows = visible.map { a in
            RunwayPauseImpactRow(
                id: a.identity.id,
                displayName: a.identity.displayName,
                isGoal: a.identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: rate(a),
                confidence: .direct
            )
        }
        let burstSummary = overflow.isEmpty
            ? nil
            : RunwayShortBurstSummary(
                count: overflow.count,
                deadline: .unavailable,
                gainedSeconds: 0,
                displayRate: overflow.reduce(0) { $0 + rate($1) }
            )
        return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: burstSummary)
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
            // the session rather than drop it honestly.
            guard let p = priceTable.price(forModel: component.modelSlug) else { return nil }
            perSecond += component.inputPerSecond * p.inputPerMTok / 1_000_000
                + component.cachedInputPerSecond * p.cachedInputPerMTok / 1_000_000
                + component.outputPerSecond * p.outputPerMTok / 1_000_000
                + component.cacheCreationPerSecond * (p.cacheWritePerMTok ?? p.inputPerMTok) / 1_000_000
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
            .compactMap { candidate(for: $0.url, now: now, threadNames: threadNames, signature: $0.signature) }
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

    private static func candidate(for url: URL, now: Date, threadNames: [String: String], signature: RunwayFileSignature) -> RecentSessionCandidate? {
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
        let isActive = hasActiveTail(from: parse.activeTailLines, now: now)
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
    private static func hasActiveTail(from lines: [CodexScannerActiveTailLine], now: Date) -> Bool {
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
        guard workAge <= maximumActiveSampleAge else { return false }
        if let latestCompletionAt,
           latestCompletionAt >= latestWorkSampleAt {
            return now.timeIntervalSince(latestCompletionAt) <= maximumGoalCompletionGrace
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
              let subagent = source["subagent"] as? [String: Any],
              let threadSpawn = subagent["thread_spawn"] as? [String: Any] else {
            return nil
        }
        return string(threadSpawn["parent_thread_id"])
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

enum CodexRunwayTokenActivityParser {
    /// Upper bound on the backward hunt for a `turn_context`. Past this we give up
    /// and the session goes unpriced (dropped from $, still shown in tk/h) rather
    /// than risk pricing it at a guessed model.
    static let modelScanCap = 64 * 1024 * 1024
    /// Overlap re-read when scanning newly-appended bytes, so a `turn_context` that
    /// straddles the previous scan frontier isn't split into two unparseable halves.
    static let modelScanOverlap = 64 * 1024
    static let maximumSampleAge: TimeInterval = 75
    static let minimumPairInterval: TimeInterval = 10
    static let maximumPairInterval: TimeInterval = 30 * 60

    private static let sampleCache = RunwayFileParseCache<[CodexRawTokenLine]>()

    #if DEBUG
    static var sampleCacheMissCountForTesting: Int { sampleCache.missCount }
    static func resetSampleCacheForTesting() { sampleCache.removeAllForTesting() }
    #endif

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 512 * 1024,
                              now: Date = Date()) -> [CodexRunwayTokenActivitySample] {
        let raw: [CodexRawTokenLine]
        if let signature = RunwayFileSignature.read(path: path) {
            raw = sampleCache.value(path: path, signature: signature) {
                parseRawLines(fromLogPath: path, maxBytes: maxBytes)
            }
        } else {
            raw = parseRawLines(fromLogPath: path, maxBytes: maxBytes)
        }
        return resolveModel(raw, path: path)
            .compactMap { finalize($0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Guarantee every sample carries the session model so `$` pricing never nils
    /// out intermittently. `turn_context` is the sole model carrier and recurs per
    /// turn, but the token tail (`maxBytes`) can miss it when one turn dumps more
    /// than the window — then `raw` comes back all-nil and, under the "any unpriced
    /// active model → whole provider falls back to tk/h" rule, the Codex runway
    /// *flaps* between $ and tk/h as that session goes active/idle. Resolution order:
    /// the tail's own model (cheapest, also refreshes the cache) → a per-path cache
    /// (a session is single-model, so once known it stays known) → a head read
    /// (first `turn_context`, past the large `session_meta`). The cache means the
    /// expensive head read happens at most once per session.
    private static func resolveModel(_ raw: [CodexRawTokenLine], path: String) -> [CodexRawTokenLine] {
        // No samples → nothing to stamp, and no reason to pay for a scan.
        guard !raw.isEmpty else { return raw }
        if let tailModel = raw.last(where: { $0.modelSlug != nil })?.modelSlug {
            // Everything after this `turn_context` is inside the tail and carries no
            // other one, so it is the newest in the whole file — current as of EOF.
            rememberModel(tailModel, path: path, scannedThrough: fileSize(path: path))
            return raw
        }
        guard let model = sessionModel(path: path) else { return raw }
        return raw.map { $0.modelSlug == nil ? $0.withModelSlug(model) : $0 }
    }

    /// The session's current model when the token tail carried none.
    ///
    /// The cache records how far the file had been scanned when the model was
    /// established, and every later cycle scans ONLY the bytes appended since. That
    /// frontier is what keeps a `/model` switch from being missed: consulting a
    /// cached model without re-checking new bytes would keep pricing at the old
    /// model for the rest of a long turn (the switch's `turn_context` is outside the
    /// tail, so nothing else would ever notice it). Never holds the lock across I/O.
    private static func sessionModel(path: String) -> String? {
        guard let size = fileSize(path: path) else { return nil }   // transient; retry next cycle
        modelCacheLock.lock()
        let entry = modelCacheByPath[path]
        modelCacheLock.unlock()

        if let entry, entry.scannedThrough <= size {
            guard entry.scannedThrough < size else { return entry.model }  // nothing appended
            // Re-read a small overlap: the previous frontier may have landed
            // mid-line, and a `turn_context` straddling it would otherwise be lost.
            let from = entry.scannedThrough > UInt64(modelScanOverlap)
                ? entry.scannedThrough - UInt64(modelScanOverlap)
                : 0
            guard let delta = readRange(path: path, from: from, to: size) else { return entry.model }
            let model = lastTurnContextModel(in: delta) ?? entry.model
            rememberModel(model, path: path, scannedThrough: size)
            return model
        }

        // Cold cache, or the file shrank (rotated/truncated) — hunt from scratch.
        let lookup = currentModel(fromLogPath: path)
        guard lookup.didRead else { return nil }   // read failed; don't remember it
        rememberModel(lookup.model, path: path, scannedThrough: size)
        return lookup.model
    }

    static func retainCache(paths: Set<String>) {
        sampleCache.retain(paths: paths)
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
    }
    private static let modelCacheLock = NSLock()
    private static var modelCacheByPath: [String: ModelCacheEntry] = [:]

    private static func rememberModel(_ model: String?, path: String, scannedThrough: UInt64?) {
        guard let scannedThrough else { return }
        modelCacheLock.lock()
        modelCacheByPath[path] = ModelCacheEntry(model: model, scannedThrough: scannedThrough)
        modelCacheLock.unlock()
    }

    private static func fileSize(path: String) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    private static func readRange(path: String, from: UInt64, to: UInt64) -> Data? {
        guard to > from, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        return try? handle.read(upToCount: Int(to - from))
    }

    #if DEBUG
    static func resetModelCacheForTesting() {
        modelCacheLock.lock(); modelCacheByPath.removeAll(); modelCacheLock.unlock()
    }
    #endif

    private static func parseRawLines(fromLogPath path: String,
                                      maxBytes: Int) -> [CodexRawTokenLine] {
        guard let data = CodexRunwayRateLimitParser.tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        // Codex logs the model on `turn_context` lines, not on `token_count`
        // lines, so track the latest-seen model in file order and stamp it onto
        // subsequent token lines. Pure function of the bytes → still cacheable.
        var out: [CodexRawTokenLine] = []
        var lastModel: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(raw).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            if let m = modelSlug(from: payload) ?? modelSlug(from: obj) { lastModel = m }
            if let line = tokenLine(obj: obj, payload: payload, logPath: path, model: lastModel) {
                out.append(line)
            }
        }
        // Backfill token lines that precede the tail's first `turn_context` with the
        // first in-tail model (a session is effectively single-model). When the tail
        // has no model at all — one turn dumped more than `maxBytes` — `out` stays
        // all-nil and `resolveModel` fills it from the cache or file head. Pure
        // function of the bytes → still cacheable.
        if let sessionModel = out.first(where: { $0.modelSlug != nil })?.modelSlug {
            for i in out.indices where out[i].modelSlug == nil {
                out[i] = out[i].withModelSlug(sessionModel)
            }
        }
        return out
    }

    /// The session's CURRENT model: the model on the **last** `turn_context` in the
    /// file. Used only when the 512 KB token tail carried none, so widen the window
    /// progressively until one appears — a single turn can dump megabytes between
    /// `turn_context` lines.
    ///
    /// Taking the LAST one, not the file's first, is the whole point: after a
    /// mid-session `/model` switch the first `turn_context` holds the model the
    /// session STARTED with, so pricing from it misprices every token for the rest
    /// of a long turn (e.g. a switch to gpt-5.6-luna still billed at gpt-5.6-sol —
    /// 5x). The result is cached, so this runs at most once per unresolved stretch.
    ///
    /// `didRead` separates "scanned the bytes, no `turn_context` there" (cacheable)
    /// from "couldn't read the file" (transient), so only the former is remembered.
    private static func currentModel(fromLogPath path: String) -> (model: String?, didRead: Bool) {
        var window = 2 * 1024 * 1024   // the 512KB token tail already came up empty
        while true {
            guard let data = CodexRunwayRateLimitParser.tailData(path: path, maxBytes: window) else {
                return (nil, false)
            }
            if let model = lastTurnContextModel(in: data) { return (model, true) }
            // Short read ⇒ that was the whole file, so no `turn_context` exists at all.
            if data.count < window { return (nil, true) }
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
                modelSlug: current.modelSlug
            )
        }
        return nil
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
