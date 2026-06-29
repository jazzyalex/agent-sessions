import XCTest
@testable import AgentSessions

final class SearchTextMatcherMemoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SearchTextMatcher.resetTokenizationCacheForTesting()
    }

    func testTranscriptTokenizationMemoizedPerVersion() {
        let key = SearchTextMatcher.TokenCacheKey(id: "s1", sizeBytes: 100, eventCount: 3)
        let text = "the quick brown fox jumps over the lazy dog"

        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "fox", cacheKey: key))
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "lazy", cacheKey: key))
        XCTAssertFalse(SearchTextMatcher.hasMatch(in: text, query: "zebra", cacheKey: key))
        // Tokenized exactly once despite three match calls on the same content version.
        XCTAssertEqual(SearchTextMatcher.memoizedTokenizationMisses, 1)

        // A reparse (new size / event count) is a new version → re-tokenized once.
        let key2 = SearchTextMatcher.TokenCacheKey(id: "s1", sizeBytes: 120, eventCount: 4)
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text + " zebra", query: "zebra", cacheKey: key2))
        XCTAssertEqual(SearchTextMatcher.memoizedTokenizationMisses, 2)
    }

    func testCachedAndUncachedResultsAgree() {
        let key = SearchTextMatcher.TokenCacheKey(id: "s2", sizeBytes: 10, eventCount: 1)
        let text = "alpha beta gamma delta epsilon"
        let queries = ["beta", "gamma delta", "alpha AND epsilon", "missing", "del*", "alpha OR zzz"]
        for qq in queries {
            let uncached = SearchTextMatcher.hasMatch(in: text, query: qq)
            let cached = SearchTextMatcher.hasMatch(in: text, query: qq, cacheKey: key)
            XCTAssertEqual(uncached, cached, "Query \"\(qq)\" disagreed between cached and uncached paths")
        }
    }

    func testNoCacheKeyLeavesMemoUntouched() {
        let text = "one two three"
        _ = SearchTextMatcher.hasMatch(in: text, query: "two")
        _ = SearchTextMatcher.hasMatch(in: text, query: "three")
        // Calls without a cacheKey tokenize directly and never populate the memo.
        XCTAssertEqual(SearchTextMatcher.memoizedTokenizationMisses, 0)
    }
}
