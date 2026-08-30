import Foundation

/// Builds a runway snapshot for Claude. Mirrors `CodexRunwaySnapshotLoader` but
/// uses only the token-activity path (Claude logs carry no per-session rate
/// limits), then hands the burns to the shared, provider-agnostic
/// `CodexRunwayCalculator` and `RunwaySnapshotAssembly`.
enum ClaudeRunwaySnapshotLoader {
    static func effectiveIdentities(requestIdentities: [RunwaySessionIdentity],
                                    recentSessionsRoot: URL?,
                                    now: Date,
                                    desktopTitlesRoot: URL? = nil,
                                    desktopTitlesRoots: [URL]? = nil,
                                    scannerOptions: ClaudeRunwayRecentSessionScanner.ScanOptions = .runway) -> [RunwaySessionIdentity] {
        let scannerIdentities = ClaudeRunwayRecentSessionScanner.identities(
            root: recentSessionsRoot,
            now: now,
            options: scannerOptions
        )
        let merged = RunwaySnapshotAssembly.uniqueIdentities(requestIdentities + scannerIdentities)
        // The Claude Desktop sidecar carries both the user-facing title and the
        // archived flag (keyed by transcript session id). Prefer that title over
        // any transcript-derived name and drop sessions the user archived in
        // Desktop.
        let desktopRecords: [String: ClaudeDesktopSidecarRecord]
        if let desktopTitlesRoots {
            desktopRecords = ClaudeDesktopSessionTitles.records(roots: desktopTitlesRoots)
        } else if let desktopTitlesRoot {
            desktopRecords = ClaudeDesktopSessionTitles.records(root: desktopTitlesRoot)
        } else {
            desktopRecords = ClaudeDesktopSessionTitles.records(roots: ClaudeDesktopSessionTitles.defaultRoots())
        }
        return merged.compactMap { identity -> RunwaySessionIdentity? in
            let record = desktopRecords[identity.id]
            if record?.isArchived == true { return nil }
            guard let title = record?.title, !title.isEmpty else { return identity }
            return RunwaySessionIdentity(
                id: identity.id,
                displayName: ClaudeRunwayLog.compact(title),
                isGoal: identity.isGoal,
                logPaths: identity.logPaths,
                // Preserve the scanner's idle classification; without it a
                // finished, Desktop-titled session would render as working.
                isIdle: identity.isIdle
            )
        }
    }

    static func snapshot(for request: CodexRunwaySnapshotRequest,
                         desktopTitlesRoot: URL? = nil) async -> CodexRunwaySnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let identities = effectiveIdentities(
                    requestIdentities: request.identities,
                    recentSessionsRoot: request.recentSessionsRoot,
                    now: request.now,
                    desktopTitlesRoot: desktopTitlesRoot
                )
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
                // Provisional-clamped for every unit, not just weekly. A brand-new
                // session's first turn is cache-heavy and can be measured over as
                // little as 2s, so the raw estimate runs an order of magnitude high
                // and then "corrects itself" — visible as an absurd headline number
                // in tk/h and $ alike. (5h is structurally immune: `burns` splits a
                // fixed account rate, so a spike can only redistribute shares.)
                let activities = ClaudeRunwayTokenActivityParser
                    .activitiesClampingProvisional(identities: identities, now: request.now)
                // Bank this cycle's activity for weekly calibration on EVERY cycle,
                // whatever unit is selected: the ledger's bucket timeline doubles as
                // the poll-continuity record, and a skipped cycle would later read
                // as a sleep gap and reject an otherwise valid interval.
                WeeklyQuotaCalibrationStore.shared.ledger(provider: "claude").recordIncremental(
                    events: ClaudeRunwayTokenActivityParser.ledgerEvents(
                        identities: identities, now: request.now),
                    priceTable: RunwayPriceTable.shared,
                    now: request.now
                )
                let core: CodexRunwaySnapshot?
                var effectiveBaseline = request.baseline
                // Identities eligible for a pending row; $ mode narrows it to the
                // ones it can price so a dropped session never shows "$0/h".
                var pendingIdentities = identities
                // Weekly-only: sessions that can never be estimated in this unit.
                var weeklyUnavailableIDs: Set<String> = []
                // See the Codex loader: calibrated + no current burn == "flat".
                let weeklyPendingConfidence: RunwayAttributionConfidence =
                    (request.baseline.rateUnit == .weeklyPercentPerHour
                     && request.weeklyPercentPointsPerDollar != nil) ? .direct : .waiting
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
                    // Estimated weekly %/h from the learned calibration; never a
                    // token fallback — `Wk` must not render tk/h. Uncalibrated rows
                    // wait on the clock, unestimable ones read "n/a".
                    RunwayPriceTable.shared.refreshInBackground(now: request.now)
                    if !request.weeklyWindowAvailable || request.weeklyCalibrationAbandoned {
                        // No weekly window, or calibration is evidently not coming.
                        core = nil
                        weeklyUnavailableIDs = Set(identities.map(\.id))
                    } else if let calibration = request.weeklyPercentPointsPerDollar,
                              let weekly = CodexRunwayCalculator.weeklyEstimatedSnapshot(
                                  baseline: request.baseline, activities: activities,
                                  priceTable: RunwayPriceTable.shared,
                                  percentPointsPerDollar: calibration, maxRows: request.maxRows) {
                        core = weekly.snapshot
                        weeklyUnavailableIDs = weekly.unpriceableIDs
                        pendingIdentities = identities.filter { !weekly.unpriceableIDs.contains($0.id) }
                    } else if request.weeklyPercentPointsPerDollar != nil {
                        core = nil
                        weeklyUnavailableIDs = Set(activities.map(\.identity.id))
                    } else {
                        core = nil
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
                let withUnavailable = RunwaySnapshotAssembly.withUnavailableRows(
                    baseline: effectiveBaseline,
                    snapshot: core,
                    identities: identities,
                    unavailableIDs: weeklyUnavailableIDs,
                    maxRows: request.maxRows
                )
                let snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: effectiveBaseline,
                    snapshot: withUnavailable,
                    activeIdentities: pendingIdentities,
                    maxRows: request.maxRows,
                    pendingConfidence: weeklyPendingConfidence
                )
                continuation.resume(returning: RunwaySnapshotAssembly.withWeeklyRateHold(
                    snapshot, hold: .shared, now: request.now))
            }
        }
    }
}

enum ClaudeRunwayPresenceSynthesizer {
    static func presences(root: URL?,
                          now: Date,
                          claimedLogPaths: Set<String>,
                          desktopTitlesRoots: [URL]? = nil) -> [CodexActivePresence] {
        let normalizedClaimed = Set(
            claimedLogPaths
                .map(CodexActiveSessionsModel.normalizePath)
                .filter { !$0.isEmpty }
        )
        let identities = ClaudeRunwaySnapshotLoader.effectiveIdentities(
            requestIdentities: [],
            recentSessionsRoot: root,
            now: now,
            desktopTitlesRoots: desktopTitlesRoots,
            scannerOptions: .presence
        )

        return identities.compactMap { identity in
            let logPaths = identity.logPaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !logPaths.isEmpty else { return nil }
            let normalizedLogPaths = Set(logPaths.map(CodexActiveSessionsModel.normalizePath).filter { !$0.isEmpty })
            guard normalizedLogPaths.isDisjoint(with: normalizedClaimed) else { return nil }

            var presence = CodexActivePresence()
            presence.schemaVersion = 1
            presence.publisher = "agent-sessions-runway"
            presence.kind = "desktop"
            presence.source = .claude
            presence.sessionId = identity.id
            presence.sessionLogPath = logPaths[0]
            presence.openSessionLogPaths = logPaths
            presence.lastSeenAt = now
            presence.liveStateHint = identity.isIdle ? .openIdle : .activeWorking
            return presence
        }
    }
}
