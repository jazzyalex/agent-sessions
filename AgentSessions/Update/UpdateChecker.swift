import Foundation

// MARK: - Clock Protocol (for testability)

protocol Clock {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

// MARK: - Update Checker

actor UpdateChecker {
    private let client: GitHubAPIClient
    private let clock: Clock
    private let defaults: UserDefaults
    private let currentVersion: String
    private let updateHandler: @Sendable (UpdateState) -> Void

    private static let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private static let firstErrorBackoff: TimeInterval = 8 * 60 * 60 // 8 hours
    private static let repeatedErrorBackoff: TimeInterval = 24 * 60 * 60 // 24 hours

    init(client: GitHubAPIClient,
         clock: Clock = SystemClock(),
         defaults: UserDefaults = .standard,
         currentVersion: String,
         updateHandler: @escaping @Sendable (UpdateState) -> Void) {
        self.client = client
        self.clock = clock
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.updateHandler = updateHandler
    }

    /// Check for updates respecting 24h cadence and error backoff
    func checkForUpdates(force: Bool = false) async {
        let now = clock.now()

        // Skip if already checked recently (unless forced)
        if !force {
            if let lastCheck = defaults.updateLastCheckAt {
                let elapsed = now.timeIntervalSince(lastCheck)
                if elapsed < Self.checkInterval {
                    return
                }
            }

            // Check error backoff
            if let lastError = defaults.updateLastErrorAt {
                let errorCount = defaults.updateErrorCount
                let backoff = errorCount <= 1 ? Self.firstErrorBackoff : Self.repeatedErrorBackoff
                let elapsed = now.timeIntervalSince(lastError)
                if elapsed < backoff {
                    return
                }
            }
        }

        // Notify checking state
        updateHandler(.checking)

        // Fetch from GitHub
        let etag = defaults.updateETag
        let result = await client.fetchLatestRelease(etag: etag)

        switch result {
        case .success(let (release, newETag)):
            // Update stored ETag
            defaults.updateETag = newETag
            defaults.updateLastCheckAt = now
            defaults.updateLastErrorAt = nil
            defaults.updateErrorCount = 0

            // Compare versions
            guard let remoteVersion = SemanticVersion(string: release.tag_name),
                  let localVersion = SemanticVersion(string: currentVersion) else {
                updateHandler(.error("Invalid version format"))
                return
            }

            // Check if this version was skipped
            if let skipped = defaults.updateSkippedVersion, skipped == release.tag_name {
                updateHandler(.upToDate)
                return
            }

            // Compare
            if remoteVersion > localVersion {
                // Extract first asset URL
                guard let assetURL = release.assets.first?.browser_download_url else {
                    updateHandler(.error("No download available"))
                    return
                }
                updateHandler(.available(version: release.tag_name,
                                        releaseURL: release.html_url,
                                        assetURL: assetURL))
            } else {
                updateHandler(.upToDate)
            }

        case .failure(let error):
            if case GitHubClientError.notModified = error {
                // 304 means no change - treat as up to date
                defaults.updateLastCheckAt = now
                defaults.updateLastErrorAt = nil
                defaults.updateErrorCount = 0
                updateHandler(.upToDate)
            } else {
                // Real error - record for backoff
                defaults.updateLastErrorAt = now
                defaults.updateErrorCount += 1
                updateHandler(.error(error.localizedDescription))
            }
        }
    }

    /// Skip a specific version
    func skipVersion(_ version: String) {
        defaults.updateSkippedVersion = version
    }

    /// Reset skip version (for testing or manual re-check)
    func resetSkippedVersion() {
        defaults.updateSkippedVersion = nil
    }
}
