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

struct RunwayProviderBaseline: Equatable, Sendable {
    let source: UsageTrackingSource
    let remainingPercent: Double
    let resetAt: Date
    let currentRunoutAt: Date
    let observedAt: Date
    let hasProjectedRunout: Bool

    init(source: UsageTrackingSource,
         remainingPercent: Double,
         resetAt: Date,
         currentRunoutAt: Date,
         observedAt: Date,
         hasProjectedRunout: Bool = true) {
        self.source = source
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.currentRunoutAt = currentRunoutAt
        self.observedAt = observedAt
        self.hasProjectedRunout = hasProjectedRunout
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
        let elapsed = max(rawElapsed, minimumElapsed)
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
}

struct RunwaySessionActivity: Equatable, Sendable {
    let identity: RunwaySessionIdentity
    let tokensPerSecond: Double
    let sampleStart: Date
    let sampleEnd: Date
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
    let quotaMinutesPerHour: Double
    let confidence: RunwayAttributionConfidence
}

struct RunwayShortBurstSummary: Equatable, Sendable {
    let count: Int
    let deadline: RunwayDeadline
    let gainedSeconds: TimeInterval
    let quotaMinutesPerHour: Double
}

struct CodexRunwaySnapshot: Equatable, Sendable {
    let baseline: RunwayProviderBaseline
    let rows: [RunwayPauseImpactRow]
    let burstSummary: RunwayShortBurstSummary?
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

enum CodexRunwaySnapshotLoader {
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
                let directBurns = identities.compactMap {
                    CodexRunwayRateLimitParser.burn(identity: $0, now: request.now)
                }
                let tokenBurns = request.baseline.hasProjectedRunout
                    ? CodexRunwayTokenActivityParser.burns(
                        identities: identities,
                        baseline: request.baseline,
                        now: request.now
                    )
                    : []
                let burns = mergeBurns(directBurns: directBurns, tokenBurns: tokenBurns)
                let snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: request.baseline,
                    snapshot: CodexRunwayCalculator.snapshot(
                        baseline: request.baseline,
                        burns: burns,
                        maxRows: request.maxRows
                    ),
                    activeIdentities: identities,
                    maxRows: request.maxRows
                )
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
                    quotaMinutesPerHour: burnSummary.quotaMinutesPerHour
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
                quotaMinutesPerHour: 0,
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
                quotaMinutesPerHour: overflow.reduce(0) { $0 + $1.quotaMinutesPerHour }
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
                    quotaMinutesPerHour: $0.row.quotaMinutesPerHour,
                    confidence: $0.row.confidence
                )
            }
            let burstSummary = overflow.isEmpty
                ? nil
                : RunwayShortBurstSummary(
                    count: overflow.count,
                    deadline: .afterReset,
                    gainedSeconds: 0,
                    quotaMinutesPerHour: overflow.reduce(0) { $0 + $1.row.quotaMinutesPerHour }
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
            quotaMinutesPerHour: quotaMinutesPerHour(normalizedRate),
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
            quotaMinutesPerHour: impacts.reduce(0) { $0 + $1.row.quotaMinutesPerHour }
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

    private static func quotaMinutesPerHour(_ percentPerSecond: Double) -> Double {
        // One hundred percent of a 5h window is 300 quota minutes.
        percentPerSecond * 3 * 3600
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
        guard let primary = rate["primary"] as? [String: Any] else { return nil }
        let capturedAtReal = flexibleDate(rate["captured_at"]) ?? createdAtReal
        guard let remaining = remainingPercent(primary),
              let resetSpec = resetSpec(primary) else {
            return nil
        }
        return CodexRawRateLimitLine(
            logPath: logPath,
            capturedAtReal: capturedAtReal,
            remainingPercent: remaining,
            resetSpec: resetSpec
        )
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
        guard let data = headData(path: url.path, maxBytes: 96 * 1024),
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

    private static func headData(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
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
}

enum CodexRunwayTokenActivityParser {
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
        return raw
            .compactMap { finalize($0, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    static func retainCache(paths: Set<String>) {
        sampleCache.retain(paths: paths)
    }

    private static func parseRawLines(fromLogPath path: String,
                                      maxBytes: Int) -> [CodexRawTokenLine] {
        guard let data = CodexRunwayRateLimitParser.tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseRawLine(String($0), logPath: path) }
    }

    private static func finalize(_ raw: CodexRawTokenLine, now: Date) -> CodexRunwayTokenActivitySample? {
        let capturedAt = raw.createdAtReal ?? now
        guard capturedAt <= now.addingTimeInterval(5) else { return nil }
        return CodexRunwayTokenActivitySample(
            logPath: raw.logPath,
            capturedAt: capturedAt,
            totalTokens: raw.totalTokens
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
            sampleEnd: pathActivities.map(\.sampleEnd).max() ?? now
        )
    }

    static func burns(identities: [RunwaySessionIdentity],
                      baseline: RunwayProviderBaseline,
                      now: Date = Date()) -> [RunwaySessionBurn] {
        let currentSeconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        guard currentSeconds > 0, baseline.remainingPercent > 0 else { return [] }
        let providerRate = baseline.remainingPercent / currentSeconds
        guard providerRate > 0, providerRate.isFinite else { return [] }

        let activities = identities.compactMap { activity(identity: $0, now: now) }
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
                sampleEnd: current.capturedAt
            )
        }
        return nil
    }

    private static func parseRawLine(_ line: String,
                                     logPath: String) -> CodexRawTokenLine? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let createdAtReal = CodexRunwayRateLimitParser.flexibleDate(obj["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(obj["timestamp"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["timestamp"])
        guard let totalTokens = totalTokens(from: payload) ?? totalTokens(from: obj) else {
            return nil
        }
        return CodexRawTokenLine(
            logPath: logPath,
            createdAtReal: createdAtReal,
            totalTokens: totalTokens
        )
    }

    private static func totalTokens(from dict: [String: Any]) -> Double? {
        if let direct = CodexRunwayRateLimitParser.double(dict["total_tokens"]) {
            return direct
        }
        if let info = dict["info"] as? [String: Any],
           let value = totalTokens(from: info) {
            return value
        }
        if let total = dict["total_token_usage"] as? [String: Any],
           let value = CodexRunwayRateLimitParser.double(total["total_tokens"]) {
            return value
        }
        if let usage = dict["usage"] as? [String: Any],
           let value = CodexRunwayRateLimitParser.double(usage["total_tokens"]) {
            return value
        }
        return nil
    }
}
