import Foundation

/// Lightweight analytics indexer that derives session_days and rollups_daily
/// from the existing session_meta table. No file I/O or JSON parsing required.
actor AnalyticsIndexer {
    private let db: IndexDB
    private let enabledSources: Set<String>

    init(db: IndexDB, enabledSources: Set<String>) {
        self.db = db
        self.enabledSources = enabledSources
    }

    // MARK: - Public API

    /// Full build: clears session_days/rollups for each source and re-derives from session_meta.
    /// Returns the set of sources that failed (empty on full success).
    @discardableResult
    func fullBuild(onSourceComplete: @escaping @Sendable (String) async -> Void,
                   onSourceProgress: (@Sendable (String, Int, Int) async -> Void)? = nil) async -> Set<String> {
        LaunchProfiler.log("Analytics.fullBuild start (meta-derived)")
        var failedSources = Set<String>()
        for source in enabledSources.sorted() {
            if Task.isCancelled { return failedSources }
            do {
                try await db.begin()
                // Reconcile: purge session_meta rows for files no longer on disk
                try await db.purgeOrphanedSessionMeta(for: source)
                try await db.exec("DELETE FROM session_days WHERE source='\(source)';")
                try await db.exec("DELETE FROM rollups_daily WHERE source='\(source)';")
                let count = try await db.populateSessionDaysFromMeta(for: source)
                try await db.recomputeAllRollups(for: source)
                try await db.commit()
                await onSourceProgress?(source, count, count)
                await onSourceComplete(source)
            } catch {
                await db.rollbackSilently()
                failedSources.insert(source)
            }
        }
        LaunchProfiler.log("Analytics.fullBuild complete (meta-derived, failures=\(failedSources.count))")
        return failedSources
    }

    /// Incremental refresh: only process new/changed/removed sessions since last build.
    /// Returns the set of sources that failed (empty on full success).
    @discardableResult
    func refresh(onSourceProgress: (@Sendable (String, Int, Int) async -> Void)? = nil) async -> Set<String> {
        LaunchProfiler.log("Analytics.refresh start (meta-derived)")
        var failedSources = Set<String>()
        for source in enabledSources.sorted() {
            if Task.isCancelled { return failedSources }
            do {
                let newIDs = try await db.findSessionsNeedingDayUpdate(source: source)
                let staleIDs = try await db.findStaleDayRows(source: source)
                if newIDs.isEmpty && staleIDs.isEmpty {
                    await onSourceProgress?(source, 0, 0)
                    continue
                }

                try await db.begin()
                var affectedDays = Set<String>()

                if !staleIDs.isEmpty {
                    let staleDays = try await db.deleteSessionDaysForIDs(staleIDs, source: source)
                    affectedDays.formUnion(staleDays)
                }

                if !newIDs.isEmpty {
                    let newDays = try await db.populateSessionDaysFromMetaIncremental(sessionIDs: newIDs, source: source)
                    affectedDays.formUnion(newDays)
                }

                try await db.recomputeRollupsForDays(affectedDays, source: source)
                try await db.commit()
                await onSourceProgress?(source, newIDs.count + staleIDs.count, newIDs.count + staleIDs.count)
            } catch {
                await db.rollbackSilently()
                failedSources.insert(source)
            }
        }
        LaunchProfiler.log("Analytics.refresh complete (meta-derived, failures=\(failedSources.count))")
        return failedSources
    }
}
