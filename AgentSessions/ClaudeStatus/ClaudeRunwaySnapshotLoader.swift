import Foundation

/// Builds a runway snapshot for Claude. Mirrors `CodexRunwaySnapshotLoader` but
/// uses only the token-activity path (Claude logs carry no per-session rate
/// limits), then hands the burns to the shared, provider-agnostic
/// `CodexRunwayCalculator` and `RunwaySnapshotAssembly`.
enum ClaudeRunwaySnapshotLoader {
    static func snapshot(for request: CodexRunwaySnapshotRequest,
                         desktopTitlesRoot: URL? = nil) async -> CodexRunwaySnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let scannerIdentities = ClaudeRunwayRecentSessionScanner.identities(
                    root: request.recentSessionsRoot,
                    now: request.now
                )
                let merged = RunwaySnapshotAssembly.uniqueIdentities(request.identities + scannerIdentities)
                // The Claude Desktop sidecar carries both the user-facing title
                // and the archived flag (keyed by transcript session id). Prefer
                // that title over any transcript-derived name — regardless of
                // whether the name came from a HUD row or the recent-session
                // scanner — and drop sessions the user has archived in Desktop:
                // an archived conversation should not burn a runway row.
                let desktopRecords = ClaudeDesktopSessionTitles.records(root: desktopTitlesRoot)
                let identities = merged.compactMap { identity -> RunwaySessionIdentity? in
                    let record = desktopRecords[identity.id]
                    if record?.isArchived == true { return nil }
                    guard let title = record?.title, !title.isEmpty else { return identity }
                    return RunwaySessionIdentity(
                        id: identity.id,
                        displayName: ClaudeRunwayLog.compact(title),
                        isGoal: identity.isGoal,
                        logPaths: identity.logPaths,
                        // Preserve the scanner's idle classification — without it a
                        // finished, Desktop-titled session would render as working
                        // ("0m/h") instead of the calm idle "—".
                        isIdle: identity.isIdle
                    )
                }
                // Token attribution is Claude's only burn signal, so — unlike
                // Codex, which has an always-on direct rate-limit path — we do
                // NOT gate it on a fresh projection. Otherwise burn/EQ only
                // appear while the (cached, ~180s-edge) account projection is
                // live, so they show up late and flicker. Without a fresh
                // projection the baseline's runout falls back to the reset time,
                // giving a conservative "even-burn-to-reset" rate that the
                // calculator still renders; it sharpens to measured velocity
                // once a projection lands.
                // Honor the selected runway presentation (rateUnit), mirroring the
                // Codex loader. tk/h and weekly %/h reuse the provider-agnostic
                // calculator; the default m/h path is unchanged.
                // Once-per-cycle prune for every presentation, not just the quota
                // path, so the sample cache tracks active sessions, not history.
                ClaudeRunwayTokenActivityParser.retainCache(
                    paths: Set(identities.flatMap { $0.logPaths })
                )
                let activities = identities.compactMap {
                    ClaudeRunwayTokenActivityParser.activity(identity: $0, now: request.now)
                }
                let core: CodexRunwaySnapshot?
                var effectiveBaseline = request.baseline
                // Identities eligible for a pending row; $ mode narrows it to the
                // ones it can price so a dropped session never shows "$0/h".
                var pendingIdentities = identities
                switch request.baseline.rateUnit {
                case .tokensPerHour:
                    core = CodexRunwayCalculator.tokenSnapshot(
                        baseline: request.baseline, activities: activities, maxRows: request.maxRows)
                case .dollarsPerHour:
                    // Lazy, self-throttling (<=1/day): only fetch the price manifest
                    // once someone actually uses the $ presentation.
                    RunwayPriceTable.shared.refreshInBackground(now: request.now)
                    if let dollars = CodexRunwayCalculator.dollarSnapshot(
                        baseline: request.baseline, activities: activities,
                        priceTable: RunwayPriceTable.shared, maxRows: request.maxRows) {
                        core = dollars.snapshot
                        pendingIdentities = identities.filter { !dollars.unpriceableIDs.contains($0.id) }
                    } else {
                        // Nothing priceable at all → token snapshot-wide (P1).
                        effectiveBaseline = request.baseline.with(rateUnit: .tokensPerHour)
                        core = CodexRunwayCalculator.tokenSnapshot(
                            baseline: effectiveBaseline, activities: activities, maxRows: request.maxRows)
                    }
                case .weeklyPercentPerHour:
                    if let weekly = CodexRunwayCalculator.weeklySnapshot(
                        baseline: request.baseline, activities: activities, maxRows: request.maxRows) {
                        core = weekly
                    } else {
                        effectiveBaseline = request.baseline.with(rateUnit: .tokensPerHour)
                        core = CodexRunwayCalculator.tokenSnapshot(
                            baseline: effectiveBaseline, activities: activities, maxRows: request.maxRows)
                    }
                case .quotaMinutesPerHour:
                    let burns = ClaudeRunwayTokenActivityParser.burns(
                        identities: identities,
                        baseline: request.baseline,
                        now: request.now
                    )
                    core = CodexRunwayCalculator.snapshot(
                        baseline: request.baseline, burns: burns, maxRows: request.maxRows)
                }
                let snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: effectiveBaseline,
                    snapshot: core,
                    activeIdentities: pendingIdentities,
                    maxRows: request.maxRows
                )
                continuation.resume(returning: snapshot)
            }
        }
    }
}
