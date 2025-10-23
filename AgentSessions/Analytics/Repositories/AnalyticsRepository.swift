import Foundation

/// Placeholder repository for future analytics queries against rollups_daily.
/// Kept minimal to avoid churn until indexing performance work is complete.
actor AnalyticsRepository {
    private let db: IndexDB

    init(db: IndexDB) {
        self.db = db
    }
}

