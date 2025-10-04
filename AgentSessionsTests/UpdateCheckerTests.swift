import XCTest
@testable import AgentSessions

final class UpdateCheckerTests: XCTestCase {

    // MARK: - Version Comparison Tests

    func testSemanticVersionParsing() {
        XCTAssertEqual(SemanticVersion(string: "1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion(string: "v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertNil(SemanticVersion(string: "1.2"))
        XCTAssertNil(SemanticVersion(string: "invalid"))
    }

    func testSemanticVersionComparison() {
        let v1_2_2 = SemanticVersion(major: 1, minor: 2, patch: 2)
        let v1_2_3 = SemanticVersion(major: 1, minor: 2, patch: 3)
        let v1_3_0 = SemanticVersion(major: 1, minor: 3, patch: 0)
        let v2_0_0 = SemanticVersion(major: 2, minor: 0, patch: 0)

        XCTAssertTrue(v1_2_2 < v1_2_3)
        XCTAssertTrue(v1_2_3 < v1_3_0)
        XCTAssertTrue(v1_3_0 < v2_0_0)
        XCTAssertFalse(v1_2_3 < v1_2_2)
        XCTAssertTrue(v1_2_3 > v1_2_2)
    }

    // MARK: - Update Checker Tests

    func testFreshCheckWithNewerVersion() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.fresh")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.fresh")

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            "etag123"
        )))

        let clock = MockClock(now: Date(timeIntervalSince1970: 1000000))

        var capturedState: UpdateState?
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { state in
            capturedState = state
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(capturedState, .available(version: "v1.3.0",
                                                 releaseURL: "https://github.com/test/repo/releases/tag/v1.3.0",
                                                 assetURL: "https://github.com/test/repo/releases/download/v1.3.0/app.zip"))
        XCTAssertEqual(defaults.updateETag, "etag123")
        XCTAssertNotNil(defaults.updateLastCheckAt)
    }

    func testNotModifiedResponse() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.304")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.304")
        defaults.updateETag = "etag123"

        let mockClient = MockGitHubClient(response: .failure(GitHubClientError.notModified))
        let clock = MockClock(now: Date(timeIntervalSince1970: 1000000))

        var capturedState: UpdateState?
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { state in
            capturedState = state
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(capturedState, .upToDate)
        XCTAssertNil(defaults.updateLastErrorAt)
    }

    func testVersionComparisonLocalNewer() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.localNewer")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.localNewer")

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.0.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.0.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.0.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: Date(timeIntervalSince1970: 1000000))

        var capturedState: UpdateState?
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { state in
            capturedState = state
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(capturedState, .upToDate)
    }

    func testSkippedVersionNotShown() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.skipped")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.skipped")
        defaults.updateSkippedVersion = "v1.3.0"

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: Date(timeIntervalSince1970: 1000000))

        var capturedState: UpdateState?
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { state in
            capturedState = state
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(capturedState, .upToDate)
    }

    func test24HourCadenceRespected() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.cadence")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.cadence")

        let firstCheck = Date(timeIntervalSince1970: 1000000)
        let tooSoon = firstCheck.addingTimeInterval(12 * 60 * 60) // 12 hours later

        defaults.updateLastCheckAt = firstCheck

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: tooSoon)

        var callCount = 0
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { _ in
            callCount += 1
        }

        await checker.checkForUpdates(force: false)

        // Should not call update handler because check was skipped
        XCTAssertEqual(callCount, 0)
    }

    func testForceCheckIgnoresCadence() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.force")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.force")

        let firstCheck = Date(timeIntervalSince1970: 1000000)
        let tooSoon = firstCheck.addingTimeInterval(1 * 60 * 60) // 1 hour later

        defaults.updateLastCheckAt = firstCheck

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: tooSoon)

        var capturedState: UpdateState?
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { state in
            capturedState = state
        }

        await checker.checkForUpdates(force: true)

        XCTAssertEqual(capturedState, .available(version: "v1.3.0",
                                                 releaseURL: "https://github.com/test/repo/releases/tag/v1.3.0",
                                                 assetURL: "https://github.com/test/repo/releases/download/v1.3.0/app.zip"))
    }

    func testErrorBackoff8Hours() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.error8h")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.error8h")

        let errorTime = Date(timeIntervalSince1970: 1000000)
        let tooSoon = errorTime.addingTimeInterval(4 * 60 * 60) // 4 hours later

        defaults.updateLastErrorAt = errorTime
        defaults.updateErrorCount = 1

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: tooSoon)

        var callCount = 0
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { _ in
            callCount += 1
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(callCount, 0)
    }

    func testErrorBackoff24Hours() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.error24h")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.error24h")

        let errorTime = Date(timeIntervalSince1970: 1000000)
        let tooSoon = errorTime.addingTimeInterval(12 * 60 * 60) // 12 hours later

        defaults.updateLastErrorAt = errorTime
        defaults.updateErrorCount = 2 // Second error triggers 24h backoff

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            nil
        )))

        let clock = MockClock(now: tooSoon)

        var callCount = 0
        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { _ in
            callCount += 1
        }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(callCount, 0)
    }

    func testETagPersistence() async {
        let defaults = UserDefaults(suiteName: "UpdateCheckerTests.etag")!
        defaults.removePersistentDomain(forName: "UpdateCheckerTests.etag")

        let mockClient = MockGitHubClient(response: .success((
            GitHubRelease(tag_name: "v1.3.0",
                         published_at: "2025-01-01T00:00:00Z",
                         html_url: "https://github.com/test/repo/releases/tag/v1.3.0",
                         assets: [.init(browser_download_url: "https://github.com/test/repo/releases/download/v1.3.0/app.zip")]),
            "new-etag-value"
        )))

        let clock = MockClock(now: Date(timeIntervalSince1970: 1000000))

        let checker = UpdateChecker(client: mockClient,
                                    clock: clock,
                                    defaults: defaults,
                                    currentVersion: "1.2.2") { _ in }

        await checker.checkForUpdates(force: false)

        XCTAssertEqual(defaults.updateETag, "new-etag-value")
        XCTAssertEqual(mockClient.lastETag, nil) // First call has no etag

        // Second check should send the stored etag
        await checker.checkForUpdates(force: true)
        XCTAssertEqual(mockClient.lastETag, "new-etag-value")
    }
}

// MARK: - Mock Implementations

private final class MockGitHubClient: GitHubAPIClient {
    let response: Result<(GitHubRelease, etag: String?), Error>
    var lastETag: String?

    init(response: Result<(GitHubRelease, etag: String?), Error>) {
        self.response = response
    }

    func fetchLatestRelease(etag: String?) async -> Result<(GitHubRelease, etag: String?), Error> {
        lastETag = etag
        return response
    }
}

private struct MockClock: Clock {
    let now: Date

    func now() -> Date {
        now
    }
}
