import Foundation

/// Builds a runway snapshot for Claude. Mirrors `CodexRunwaySnapshotLoader` but
/// uses only the token-activity path (Claude logs carry no per-session rate
/// limits), then hands the burns to the shared, provider-agnostic
/// `CodexRunwayCalculator`.
enum ClaudeRunwaySnapshotLoader {
    static func snapshot(for request: CodexRunwaySnapshotRequest) async -> CodexRunwaySnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let scannerIdentities = ClaudeRunwayRecentSessionScanner.identities(
                    root: request.recentSessionsRoot,
                    now: request.now
                )
                let identities = uniqueIdentities(request.identities + scannerIdentities)
                let burns = request.baseline.hasProjectedRunout
                    ? ClaudeRunwayTokenActivityParser.burns(
                        identities: identities,
                        baseline: request.baseline,
                        now: request.now
                    )
                    : []
                let snapshot = snapshotWithPendingRows(
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

    // MARK: - Identity dedupe (merge by id, then by overlapping log paths)

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

        var groups: [(id: String, displayName: String, isGoal: Bool, logPaths: Set<String>, order: Int)] =
            order.enumerated().compactMap { index, id in
                guard let identity = byID[id] else { return nil }
                return (identity.id, identity.displayName, identity.isGoal, Set(identity.logPaths), index)
            }

        var index = 0
        while index < groups.count {
            var scan = index + 1
            while scan < groups.count {
                if groups[index].logPaths.isDisjoint(with: groups[scan].logPaths) {
                    scan += 1
                    continue
                }
                let winner = groups[index].logPaths.count >= groups[scan].logPaths.count
                    ? groups[index] : groups[scan]
                groups[index] = (
                    winner.id,
                    winner.displayName,
                    groups[index].isGoal || groups[scan].isGoal,
                    groups[index].logPaths.union(groups[scan].logPaths),
                    min(groups[index].order, groups[scan].order)
                )
                groups.remove(at: scan)
                scan = index + 1
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

    private static func snapshotWithPendingRows(baseline: RunwayProviderBaseline,
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
}
