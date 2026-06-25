import Foundation

enum RunwayAttributionConfidence: Equatable, Sendable {
    case direct
    case mixed
    case waiting
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

struct RunwaySessionIdentity: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isGoal: Bool
    let logPaths: [String]
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
                    logPaths: Array(Set(existing.logPaths).union(identity.logPaths)).sorted()
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
                    logPaths: Array($0.logPaths).sorted()
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

        let openSlots = max(0, maxRows - existing.rows.count)
        let pendingRows = pendingIdentities.prefix(openSlots).map { identity in
            RunwayPauseImpactRow(
                id: identity.id,
                displayName: identity.displayName,
                isGoal: identity.isGoal,
                deadline: .unavailable,
                gainedSeconds: 0,
                quotaMinutesPerHour: 0,
                confidence: .waiting
            )
        }
        let hiddenPendingCount = max(0, pendingIdentities.count - pendingRows.count)
        let pendingSummary: RunwayShortBurstSummary? = hiddenPendingCount > 0
            ? RunwayShortBurstSummary(
                count: hiddenPendingCount,
                deadline: .unavailable,
                gainedSeconds: 0,
                quotaMinutesPerHour: 0
            )
            : nil

        return CodexRunwaySnapshot(
            baseline: existing.baseline,
            rows: existing.rows + pendingRows,
            burstSummary: existing.burstSummary ?? pendingSummary
        )
    }

    private struct IdentityMergeGroup {
        let id: String
        let displayName: String
        let isGoal: Bool
        let logPaths: Set<String>
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
                order: min(lhs.order, rhs.order)
            )
        }
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
            let rows = ranked.prefix(maxRows).map {
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
            let hiddenCount = ranked.dropFirst(maxRows).count
            let burstSummary = hiddenCount > 0
                ? RunwayShortBurstSummary(
                    count: hiddenCount,
                    deadline: .afterReset,
                    gainedSeconds: 0,
                    quotaMinutesPerHour: ranked.dropFirst(maxRows).reduce(0) { $0 + $1.row.quotaMinutesPerHour }
                )
                : nil
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

        let rows = pressureImpacts.prefix(maxRows).map(\.row)
        let remainingImpacts = pressureImpacts.dropFirst(maxRows)
        let burstSummary = summary(
            for: Array(remainingImpacts),
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

enum CodexRunwayRateLimitParser {
    static let maximumSampleAge: TimeInterval = 75
    static let maximumPairInterval: TimeInterval = 10 * 60

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 512 * 1024,
                              now: Date = Date()) -> [CodexRunwayRateLimitSample] {
        guard let data = tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0), logPath: path, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
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

    private static func parseLine(_ line: String,
                                  logPath: String,
                                  now: Date) -> CodexRunwayRateLimitSample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let createdAt = flexibleDate(obj["created_at"])
            ?? flexibleDate(payload["created_at"])
            ?? flexibleDate(obj["timestamp"])
            ?? flexibleDate(payload["timestamp"])
            ?? now

        guard let rate = (payload["rate_limits"] as? [String: Any])
            ?? (obj["rate_limits"] as? [String: Any])
            ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]) else {
            return nil
        }
        let limitID = (rate["limit_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard limitID == nil || limitID == "codex" || limitID == "" else { return nil }
        guard let primary = rate["primary"] as? [String: Any] else { return nil }
        let capturedAt = flexibleDate(rate["captured_at"]) ?? createdAt
        guard capturedAt <= now.addingTimeInterval(5) else { return nil }
        guard let remaining = remainingPercent(primary),
              let resetAt = resetDate(primary, createdAt: createdAt, capturedAt: capturedAt) else {
            return nil
        }
        return CodexRunwayRateLimitSample(
            logPath: logPath,
            capturedAt: capturedAt,
            remainingPercent: remaining,
            resetAt: resetAt
        )
    }

    private static func remainingPercent(_ dict: [String: Any]) -> Double? {
        if let v = double(dict["remaining_percent"]) { return max(0, min(100, v)) }
        if let v = double(dict["pct_left"]) { return max(0, min(100, v)) }
        if let v = double(dict["pct_remaining"]) { return max(0, min(100, v)) }
        if let used = double(dict["used_percent"]) { return max(0, min(100, 100 - used)) }
        return nil
    }

    private static func resetDate(_ dict: [String: Any],
                                  createdAt: Date,
                                  capturedAt: Date) -> Date? {
        if let seconds = double(dict["resets_in_seconds"]) {
            return capturedAt.addingTimeInterval(seconds)
        }
        for key in ["resets_at", "reset_at", "resetsAt", "resetAt", "resets_at_ms", "reset_at_ms"] {
            guard let value = dict[key] else { continue }
            if key.hasSuffix("_ms"), let numeric = double(value) {
                return Date(timeIntervalSince1970: normalizeEpochSeconds(numeric))
            }
            if let date = flexibleDate(value) {
                return date
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
        var candidates: [(url: URL, modifiedAt: Date)] = []

        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate,
                  modifiedAt >= cutoff else {
                continue
            }
            candidates.append((url, modifiedAt))
        }

        let threadNames = SessionIndexer.loadCodexThreadNames(sessionsRoot: rootURL)

        let recentCandidates = candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maximumMetadataFiles)
            .compactMap { candidate(for: $0.url, now: now, threadNames: threadNames) }
        return Array(mergeParentCandidates(recentCandidates).prefix(maximumFiles))
    }

    private static func candidate(for url: URL, now: Date, threadNames: [String: String]) -> RecentSessionCandidate? {
        let metadata = metadata(from: url)
        if let cwd = metadata.cwd,
           CodexProbeConfig.isProbeWorkingDirectory(cwd) {
            return nil
        }
        let isActive = hasActiveTail(url: url, now: now, isGoal: metadata.isGoal)
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

    private static func hasActiveTail(url: URL, now: Date, isGoal: Bool) -> Bool {
        guard let data = CodexRunwayRateLimitParser.tailData(path: url.path, maxBytes: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(160)
        var latestWorkSampleAt: Date?
        var latestCompletionAt: Date?
        for line in lines.reversed() {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let payload = (obj["payload"] as? [String: Any]) ?? obj
            let capturedAt = CodexRunwayRateLimitParser.flexibleDate(obj["created_at"])
                ?? CodexRunwayRateLimitParser.flexibleDate(payload["created_at"])
                ?? CodexRunwayRateLimitParser.flexibleDate(obj["timestamp"])
                ?? CodexRunwayRateLimitParser.flexibleDate(payload["timestamp"])
            if string(payload["type"]) == "task_complete" {
                latestCompletionAt = capturedAt ?? now
                continue
            }
            if isWorkSample(obj: obj, payload: payload) {
                latestWorkSampleAt = capturedAt ?? now
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

    private static func metadata(from url: URL) -> SessionMetadata {
        guard let data = headData(path: url.path, maxBytes: 96 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return SessionMetadata()
        }

        var metadata = SessionMetadata()
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

    private static func displayName(metadata: SessionMetadata, customTitle: String?, fallbackID: String) -> String {
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

    private struct SessionMetadata {
        var sessionID: String?
        var parentSessionID: String?
        var cwd: String?
        var nickname: String?
        var firstUserText: String?
        var isGoal = false
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

enum CodexRunwayTokenActivityParser {
    static let maximumSampleAge: TimeInterval = 75
    static let minimumPairInterval: TimeInterval = 10
    static let maximumPairInterval: TimeInterval = 30 * 60

    static func recentSamples(fromLogPath path: String,
                              maxBytes: Int = 512 * 1024,
                              now: Date = Date()) -> [CodexRunwayTokenActivitySample] {
        guard let data = CodexRunwayRateLimitParser.tailData(path: path, maxBytes: maxBytes),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0), logPath: path, now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
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

    private static func parseLine(_ line: String,
                                  logPath: String,
                                  now: Date) -> CodexRunwayTokenActivitySample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        let createdAt = CodexRunwayRateLimitParser.flexibleDate(obj["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["created_at"])
            ?? CodexRunwayRateLimitParser.flexibleDate(obj["timestamp"])
            ?? CodexRunwayRateLimitParser.flexibleDate(payload["timestamp"])
            ?? now
        guard createdAt <= now.addingTimeInterval(5),
              let totalTokens = totalTokens(from: payload) ?? totalTokens(from: obj) else {
            return nil
        }
        return CodexRunwayTokenActivitySample(
            logPath: logPath,
            capturedAt: createdAt,
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
