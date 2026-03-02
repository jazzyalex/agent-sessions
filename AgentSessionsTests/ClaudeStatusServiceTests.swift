import XCTest
@testable import AgentSessions

final class ClaudeStatusServiceTests: XCTestCase {
    func testTerminalPathCacheCachesWithinTTL() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 10_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return "/opt/homebrew/bin:/usr/bin:/bin"
        }
        let second = cache.resolve(at: now.addingTimeInterval(12)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertEqual(first, "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(second, "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 1)
    }

    func testTerminalPathCacheRefreshesAfterTTLExpiry() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 11_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/opt/homebrew/bin:/usr/bin:/bin"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(45)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertEqual(refreshed, "/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTerminalPathCacheDoesNotCacheFailedResolutions() {
        var cache = ClaudeTerminalPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 12_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return nil
        }
        let second = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/usr/bin:/bin"
        }

        XCTAssertNil(first)
        XCTAssertEqual(second, "/usr/bin:/bin")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheCachesWithinTTL() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 1_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let second = cache.resolve(at: now.addingTimeInterval(10)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(first, "/usr/bin/tmux")
        XCTAssertEqual(second, "/usr/bin/tmux")
        XCTAssertEqual(resolveCalls, 1)
    }

    func testTmuxPathCacheRefreshesAfterTTLExpiry() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 2_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(31)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheForceRefreshBypassesTTL() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 3_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        let refreshed = cache.resolve(at: now.addingTimeInterval(1), forceRefresh: true) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheInvalidateClearsCachedState() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 4_000)

        _ = cache.resolve(at: now) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }
        cache.invalidate()
        let refreshed = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/opt/homebrew/bin/tmux"
        }

        XCTAssertEqual(refreshed, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testTmuxPathCacheDoesNotCacheFailedResolutions() {
        var cache = ClaudeTmuxPathCache(ttlSeconds: 30)
        var resolveCalls = 0
        let now = Date(timeIntervalSince1970: 5_000)

        let first = cache.resolve(at: now) {
            resolveCalls += 1
            return nil
        }
        let second = cache.resolve(at: now.addingTimeInterval(1)) {
            resolveCalls += 1
            return "/usr/bin/tmux"
        }

        XCTAssertNil(first)
        XCTAssertEqual(second, "/usr/bin/tmux")
        XCTAssertEqual(resolveCalls, 2)
    }

    func testCleanupPlannerValidatesExpectedLabelShape() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        XCTAssertTrue(planner.isManagedProbeLabel("as-cc-AbCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-xy-AbCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-ABC123"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-1bCdEf1234g5"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-AbCdEf1234gX"))
        XCTAssertFalse(planner.isManagedProbeLabel("as-cc-AbCdEf12_4g5"))
    }

    func testCleanupPlannerQueueExcludesProtectedAndActiveLabels() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)
        let allLabels: Set<String> = [
            "as-cc-AbCdEf1234g5",
            "as-cc-ZyXwVu9876t4",
            "as-cc-LmNoPq4567r8",
            "as-cc-1badLabel234",
            "other-prefix-AbCdEf1234g5"
        ]
        let protected: Set<String> = ["as-cc-ZyXwVu9876t4"]
        let queue = planner.plannedQueue(
            allLabels: allLabels,
            protectedLabels: protected,
            activeLabel: "as-cc-LmNoPq4567r8"
        )

        XCTAssertEqual(queue, ["as-cc-AbCdEf1234g5"])
    }

    func testCleanupPlannerSocketPathsForManagedLabel() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        let paths = planner.socketPaths(uid: 501, label: "as-cc-AbCdEf1234g5")

        XCTAssertEqual(
            paths,
            [
                "/private/tmp/tmux-501/as-cc-AbCdEf1234g5",
                "/tmp/tmux-501/as-cc-AbCdEf1234g5"
            ]
        )
    }

    func testCleanupPlannerSocketPathsRejectUnmanagedLabel() {
        let planner = ClaudeTmuxCleanupPlanner(prefix: "as-cc-", tokenLength: 12)

        XCTAssertTrue(planner.socketPaths(uid: 501, label: "as-cc-1bCdEf1234g5").isEmpty)
        XCTAssertTrue(planner.socketPaths(uid: 501, label: "other-label").isEmpty)
    }
}
