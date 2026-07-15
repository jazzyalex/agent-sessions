import Foundation

/// Per-session token-activity signal for Claude sessions.
///
/// Claude transcripts do not log account rate limits (those come from the OAuth/
/// web usage API), so — unlike Codex — there is no per-session "direct" burn
/// signal. What Claude logs *does* carry is per-turn `message.usage` token
/// counts with ISO timestamps. We turn that into a tokens/sec rate per session
/// and let `CodexRunwayTokenActivityParser`'s sibling math distribute the
/// account-wide burn proportionally (always `.mixed` confidence).
///
/// Two Claude-specific wrinkles vs. the Codex token parser:
/// - usage is **per-call incremental**, not a cumulative counter, so we *sum*
///   token increments across a contiguous burst instead of taking a delta.
/// - streaming emits duplicate rows that share a `message.id`; we dedupe on it.
struct ClaudeRunwayTokenActivitySample: Equatable, Sendable {
    let logPath: String
    let capturedAt: Date
    let tokens: Double
    /// Timestamp of the transcript line immediately preceding this usage line —
    /// i.e. when this turn started. Used for a provisional single-sample rate
    /// before a two-sample diff is available. nil when unknown.
    var turnStartedAt: Date?
    /// Per-turn (incremental) per-type counts for $ pricing (Phase 2). Claude's
    /// `message.usage` is per-call, so these are summed across a burst (not delta'd).
    var input: Double = 0
    var output: Double = 0
    var cacheCreation: Double = 0
    var cacheRead: Double = 0
    var modelSlug: String? = nil
}

enum ClaudeRunwayTokenActivityParser {
    /// How recent the latest token sample must be to show a live burn rate + EQ
    /// fill (vs. a spinner). Independent of row presence (the scanner keeps the
    /// row visible longer): when this lapses the row stays put but its rate
    /// falls back to "waiting", so a stopped session's number/EQ clears quickly
    /// without the whole row flickering away.
    static let maximumSampleAge: TimeInterval = 30
    static let minimumPairInterval: TimeInterval = 10
    static let maximumPairInterval: TimeInterval = 30 * 60
    /// Cache reads are billed at a steep discount; down-weight them so a session
    /// re-reading a huge context doesn't dominate attribution.
    static let cacheReadWeight: Double = 0.10
    /// Bounds for the provisional single-turn rate (used until a real two-sample
    /// diff exists). The max doubles as a resume-gap guard: if the latest turn's
    /// duration exceeds it, the preceding line is across an idle boundary, so we
    /// skip the provisional rather than emit a fake near-zero rate.
    static let provisionalMinTurnDuration: TimeInterval = 2
    static let provisionalMaxTurnDuration: TimeInterval = 120

    private static let sampleCache = RunwayFileParseCache<[ClaudeRunwayTokenActivitySample]>()

    /// Once-per-cycle prune: keep only the small in-window path set so the sample
    /// cache tracks active sessions rather than all history. The loader calls this
    /// for every presentation — `burns()` (the quota path) is no longer the only
    /// caller, or $/token/weekly users would accumulate an entry per session ever
    /// parsed. Mirrors `CodexRunwayTokenActivityParser.retainCache`.
    static func retainCache(paths: Set<String>) {
        sampleCache.retain(paths: paths)
    }

    #if DEBUG
    static var sampleCacheMissCountForTesting: Int { sampleCache.missCount }
    static func resetSampleCacheForTesting() { sampleCache.removeAllForTesting() }
    #endif

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 1024 * 1024,
                              now: Date = Date()) -> [ClaudeRunwayTokenActivitySample] {
        // The expensive tail read + JSON parse is a pure function of the bytes,
        // so cache it per (path, mtime, size). The only `now`-dependency in a
        // sample list — the future-timestamp skip — is deferred to the filter
        // below so a cached parse stays byte-identical to a fresh one for any
        // `now`. Dedupe consumes a message id even for a future line (see
        // `parseLine`), so re-admitting that line at a later `now` matches the
        // un-cached path exactly.
        let unfiltered: [ClaudeRunwayTokenActivitySample]
        if let signature = RunwayFileSignature.read(path: path) {
            unfiltered = sampleCache.value(path: path, signature: signature) {
                parseSamples(fromLogPath: path, maxBytes: maxBytes)
            }
        } else {
            unfiltered = parseSamples(fromLogPath: path, maxBytes: maxBytes)
        }
        return unfiltered
            .filter { $0.capturedAt <= now.addingTimeInterval(5) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// File-order, `now`-independent parse of every usage sample in the tail.
    /// Dedupe-by-message-id and turn-start tracking are pure functions of the
    /// bytes; the future-timestamp skip and the final sort are applied by
    /// `recentSamples`, matching the original order of operations exactly.
    private static func parseSamples(fromLogPath path: String,
                                     maxBytes: Int) -> [ClaudeRunwayTokenActivitySample] {
        guard let data = ClaudeRunwayLog.tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var seenMessageIDs = Set<String>()
        var samples: [ClaudeRunwayTokenActivitySample] = []
        // Transcript lines are appended chronologically, so the previously seen
        // timestamp is the start of the current turn.
        var previousTimestamp: Date?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let (lineTimestamp, sample) = parseLine(String(line),
                                                    logPath: path,
                                                    turnStartedAt: previousTimestamp,
                                                    seenMessageIDs: &seenMessageIDs)
            if let sample { samples.append(sample) }
            if let lineTimestamp { previousTimestamp = lineTimestamp }
        }
        return samples
    }

    static func activity(identity: RunwaySessionIdentity,
                         now: Date = Date()) -> RunwaySessionActivity? {
        scoredActivity(identity: identity, now: now)?.activity
    }

    /// Session token-rate plus whether it rests *only* on a provisional
    /// single-turn estimate (no contributing path has formed a real two-sample
    /// burst yet). `burns` uses the flag to keep an unverified provisional rate
    /// from dominating the cross-session split.
    static func scoredActivity(identity: RunwaySessionIdentity,
                               now: Date = Date()) -> (activity: RunwaySessionActivity, provisional: Bool)? {
        let pathActivities = identity.logPaths.compactMap { path -> (activity: RunwaySessionActivity, provisional: Bool)? in
            let samples = recentSamples(fromLogPath: path, now: now)
            return pathActivity(identity: identity, samples: samples, now: now)
        }
        guard !pathActivities.isEmpty else { return nil }
        let tokensPerSecond = pathActivities.reduce(0) { $0 + $1.activity.tokensPerSecond }
        guard tokensPerSecond > 0, tokensPerSecond.isFinite else { return nil }
        // Provisional only if NO contributing path produced a measured burst — a
        // real two-sample burst on any path makes the session's rate verified.
        let provisional = !pathActivities.contains { !$0.provisional }
        let activity = RunwaySessionActivity(
            identity: identity,
            tokensPerSecond: tokensPerSecond,
            sampleStart: pathActivities.map(\.activity.sampleStart).min() ?? now,
            sampleEnd: pathActivities.map(\.activity.sampleEnd).max() ?? now,
            inputPerSecond: pathActivities.reduce(0) { $0 + $1.activity.inputPerSecond },
            cachedInputPerSecond: pathActivities.reduce(0) { $0 + $1.activity.cachedInputPerSecond },
            outputPerSecond: pathActivities.reduce(0) { $0 + $1.activity.outputPerSecond },
            cacheCreationPerSecond: pathActivities.reduce(0) { $0 + $1.activity.cacheCreationPerSecond },
            modelSlug: pathActivities.compactMap(\.activity.modelSlug).first
        )
        return (activity, provisional)
    }

    /// Distribute the provider's account-wide burn across active sessions in
    /// proportion to their recent token rate. Mirrors
    /// `CodexRunwayTokenActivityParser.burns` so both feed the same calculator.
    static func burns(identities: [RunwaySessionIdentity],
                      baseline: RunwayProviderBaseline,
                      now: Date = Date()) -> [RunwaySessionBurn] {
        // The prune is the loader's job now (it runs once per cycle for every
        // presentation), so this path no longer repeats it with the same paths.
        let currentSeconds = baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        guard currentSeconds > 0, baseline.remainingPercent > 0 else { return [] }
        let providerRate = baseline.remainingPercent / currentSeconds
        guard providerRate > 0, providerRate.isFinite else { return [] }

        let scored = identities.compactMap { scoredActivity(identity: $0, now: now) }
        // A provisional single-turn rate is an unverified guess: a steep
        // cache-heavy first turn can read tens of thousands of tok/s and, via the
        // proportional split below, transiently starve every other session. Cap
        // any provisional session at the largest *measured* burst among peers so
        // it can never claim more than the busiest verified session. With no
        // measured burst yet (every session just started) leave them as-is.
        let maxBurst = scored.filter { !$0.provisional }
            .map { $0.activity.tokensPerSecond }
            .max()
        let activities = scored.map { entry -> RunwaySessionActivity in
            guard entry.provisional,
                  let maxBurst,
                  entry.activity.tokensPerSecond > maxBurst else {
                return entry.activity
            }
            return RunwaySessionActivity(
                identity: entry.activity.identity,
                tokensPerSecond: maxBurst,
                sampleStart: entry.activity.sampleStart,
                sampleEnd: entry.activity.sampleEnd
            )
        }
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

    private static func pathActivity(identity: RunwaySessionIdentity,
                                     samples: [ClaudeRunwayTokenActivitySample],
                                     now: Date) -> (activity: RunwaySessionActivity, provisional: Bool)? {
        guard let last = samples.last else { return nil }
        guard now.timeIntervalSince(last.capturedAt) <= maximumSampleAge else { return nil }

        // Walk backward over a contiguous burst, summing each later turn's tokens
        // until a long idle gap. The earliest turn is the window boundary; its
        // tokens predate the span and are excluded.
        var windowStart = last.capturedAt
        var consumed = 0.0
        var inSum = 0.0, outSum = 0.0, ccSum = 0.0, crSum = 0.0
        var previous = last
        for sample in samples.dropLast().reversed() {
            let gap = previous.capturedAt.timeIntervalSince(sample.capturedAt)
            if gap > maximumPairInterval { break }
            consumed += previous.tokens
            inSum += previous.input; outSum += previous.output
            ccSum += previous.cacheCreation; crSum += previous.cacheRead
            windowStart = sample.capturedAt
            previous = sample
        }

        let span = last.capturedAt.timeIntervalSince(windowStart)
        if span >= minimumPairInterval, consumed > 0 {
            return (RunwaySessionActivity(
                identity: identity,
                tokensPerSecond: consumed / span,
                sampleStart: windowStart,
                sampleEnd: last.capturedAt,
                inputPerSecond: inSum / span,
                cachedInputPerSecond: crSum / span,
                outputPerSecond: outSum / span,
                cacheCreationPerSecond: ccSum / span,
                modelSlug: last.modelSlug
            ), false)
        }

        // Not enough spread for a true diff yet (just started / first turn).
        // Show a provisional rate from the latest turn's own duration so a number
        // appears at the first completed turn, then converges to the burst rate
        // above once a second sample lands. The duration clamp rejects turns that
        // follow an idle/resume gap (which would otherwise read as a fake ~0).
        if let started = last.turnStartedAt {
            let turnDuration = last.capturedAt.timeIntervalSince(started)
            if turnDuration >= provisionalMinTurnDuration,
               turnDuration <= provisionalMaxTurnDuration,
               last.tokens > 0 {
                return (RunwaySessionActivity(
                    identity: identity,
                    tokensPerSecond: last.tokens / turnDuration,
                    sampleStart: started,
                    sampleEnd: last.capturedAt,
                    inputPerSecond: last.input / turnDuration,
                    cachedInputPerSecond: last.cacheRead / turnDuration,
                    outputPerSecond: last.output / turnDuration,
                    cacheCreationPerSecond: last.cacheCreation / turnDuration,
                    modelSlug: last.modelSlug
                ), true)
            }
        }
        return nil
    }

    /// Returns this line's timestamp (for turn-start tracking, regardless of
    /// type) and, when the line is a fresh non-duplicate usage record, the
    /// parsed sample. The dedupe insert precedes the tokens check exactly as
    /// before; the future-timestamp skip now lives in `recentSamples`, so a
    /// future line still consumes its message id here (matching the un-cached
    /// path) and its sample is dropped downstream by `now`.
    private static func parseLine(_ line: String,
                                  logPath: String,
                                  turnStartedAt: Date?,
                                  seenMessageIDs: inout Set<String>) -> (timestamp: Date?, sample: ClaudeRunwayTokenActivitySample?) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let timestamp = ClaudeRunwayLog.date(obj["timestamp"])
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return (timestamp, nil)
        }
        if let messageID = message["id"] as? String {
            if seenMessageIDs.contains(messageID) { return (timestamp, nil) }
            seenMessageIDs.insert(messageID)
        }
        guard let capturedAt = timestamp else {
            return (timestamp, nil)
        }
        let tokens = weightedTokens(usage)
        guard tokens > 0 else { return (timestamp, nil) }
        func v(_ key: String) -> Double { ClaudeRunwayLog.double(usage[key]) ?? 0 }
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (timestamp, ClaudeRunwayTokenActivitySample(
            logPath: logPath,
            capturedAt: capturedAt,
            tokens: tokens,
            turnStartedAt: turnStartedAt,
            input: v("input_tokens"),
            output: v("output_tokens"),
            cacheCreation: v("cache_creation_input_tokens"),
            cacheRead: v("cache_read_input_tokens"),
            modelSlug: model
        ))
    }

    private static func weightedTokens(_ usage: [String: Any]) -> Double {
        func value(_ key: String) -> Double { ClaudeRunwayLog.double(usage[key]) ?? 0 }
        return value("input_tokens")
            + value("output_tokens")
            + value("cache_creation_input_tokens")
            + cacheReadWeight * value("cache_read_input_tokens")
    }
}
