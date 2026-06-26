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

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 1024 * 1024,
                              now: Date = Date()) -> [ClaudeRunwayTokenActivitySample] {
        guard let data = ClaudeRunwayLog.tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var seenMessageIDs = Set<String>()
        var samples: [ClaudeRunwayTokenActivitySample] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let sample = parseLine(String(line),
                                         logPath: path,
                                         now: now,
                                         seenMessageIDs: &seenMessageIDs) else {
                continue
            }
            samples.append(sample)
        }
        return samples.sorted { $0.capturedAt < $1.capturedAt }
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

    /// Distribute the provider's account-wide burn across active sessions in
    /// proportion to their recent token rate. Mirrors
    /// `CodexRunwayTokenActivityParser.burns` so both feed the same calculator.
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
                                 samples: [ClaudeRunwayTokenActivitySample],
                                 now: Date) -> RunwaySessionActivity? {
        guard let last = samples.last else { return nil }
        guard now.timeIntervalSince(last.capturedAt) <= maximumSampleAge else { return nil }

        // Walk backward over a contiguous burst, summing each later turn's tokens
        // until a long idle gap. The earliest turn is the window boundary; its
        // tokens predate the span and are excluded.
        var windowStart = last.capturedAt
        var consumed = 0.0
        var previous = last
        for sample in samples.dropLast().reversed() {
            let gap = previous.capturedAt.timeIntervalSince(sample.capturedAt)
            if gap > maximumPairInterval { break }
            consumed += previous.tokens
            windowStart = sample.capturedAt
            previous = sample
        }

        let span = last.capturedAt.timeIntervalSince(windowStart)
        guard span >= minimumPairInterval, consumed > 0 else { return nil }
        return RunwaySessionActivity(
            identity: identity,
            tokensPerSecond: consumed / span,
            sampleStart: windowStart,
            sampleEnd: last.capturedAt
        )
    }

    private static func parseLine(_ line: String,
                                  logPath: String,
                                  now: Date,
                                  seenMessageIDs: inout Set<String>) -> ClaudeRunwayTokenActivitySample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }
        if let messageID = message["id"] as? String {
            if seenMessageIDs.contains(messageID) { return nil }
            seenMessageIDs.insert(messageID)
        }
        guard let capturedAt = ClaudeRunwayLog.date(obj["timestamp"]),
              capturedAt <= now.addingTimeInterval(5) else {
            return nil
        }
        let tokens = weightedTokens(usage)
        guard tokens > 0 else { return nil }
        return ClaudeRunwayTokenActivitySample(
            logPath: logPath,
            capturedAt: capturedAt,
            tokens: tokens
        )
    }

    private static func weightedTokens(_ usage: [String: Any]) -> Double {
        func value(_ key: String) -> Double { ClaudeRunwayLog.double(usage[key]) ?? 0 }
        return value("input_tokens")
            + value("output_tokens")
            + value("cache_creation_input_tokens")
            + cacheReadWeight * value("cache_read_input_tokens")
    }
}
