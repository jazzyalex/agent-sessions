import XCTest
@testable import AgentSessions

final class TranscriptCacheTests: XCTestCase {
    // Mirrors TranscriptCache.maxEntries; eviction tests fill exactly to the cap.
    private let capacity = 512

    func testSetGetRoundTrip() {
        let cache = TranscriptCache()
        cache.set("a", transcript: "alpha")
        XCTAssertEqual(cache.getCached("a"), "alpha")
        XCTAssertNil(cache.getCached("missing"))
        XCTAssertEqual(cache.count(), 1)
    }

    func testUpdatingExistingKeyDoesNotGrow() {
        let cache = TranscriptCache()
        cache.set("a", transcript: "one")
        cache.set("a", transcript: "two")
        XCTAssertEqual(cache.count(), 1)
        XCTAssertEqual(cache.getCached("a"), "two")
    }

    func testRemoveAndClear() {
        let cache = TranscriptCache()
        cache.set("a", transcript: "alpha")
        cache.set("b", transcript: "beta")

        cache.remove("a")
        XCTAssertNil(cache.getCached("a"))
        XCTAssertEqual(cache.getCached("b"), "beta")
        XCTAssertEqual(cache.count(), 1)

        cache.clear()
        XCTAssertEqual(cache.count(), 0)
        XCTAssertNil(cache.getCached("b"))
    }

    func testEvictsLeastRecentlyUsedByCount() {
        let cache = TranscriptCache()
        // Fill exactly to capacity: keys k0..k(capacity-1); k0 is the oldest.
        for i in 0..<capacity {
            cache.set("k\(i)", transcript: "v\(i)")
        }
        XCTAssertEqual(cache.count(), capacity)

        // One more insert overflows; the least-recently-used (k0) is evicted.
        cache.set("overflow", transcript: "v")
        XCTAssertEqual(cache.count(), capacity)
        XCTAssertNil(cache.getCached("k0"))
        XCTAssertEqual(cache.getCached("overflow"), "v")
        XCTAssertEqual(cache.getCached("k1"), "v1")
    }

    func testAccessProtectsEntryFromEviction() {
        let cache = TranscriptCache()
        for i in 0..<capacity {
            cache.set("k\(i)", transcript: "v\(i)")
        }
        // Touch the oldest entry so it becomes most-recently-used; k1 is now the LRU.
        XCTAssertEqual(cache.getCached("k0"), "v0")

        cache.set("overflow", transcript: "v")
        // k1 is evicted instead of the freshly-touched k0.
        XCTAssertNil(cache.getCached("k1"))
        XCTAssertEqual(cache.getCached("k0"), "v0")
        XCTAssertEqual(cache.count(), capacity)
    }

    func testConcurrentSetsStayWithinCapacity() {
        let cache = TranscriptCache()
        // Many concurrent writers/readers must never exceed the cap or crash the
        // intrusive list — this is the contention case QW-5 targets.
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            cache.set("k\(i)", transcript: "v\(i)")
            _ = cache.getCached("k\(i % 64)")
        }
        XCTAssertEqual(cache.count(), capacity)
    }
}
