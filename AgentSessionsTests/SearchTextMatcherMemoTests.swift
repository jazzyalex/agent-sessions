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

        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "brown fox", cacheKey: key))
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "lazy dog", cacheKey: key))
        XCTAssertFalse(SearchTextMatcher.hasMatch(in: text, query: "zebra yak", cacheKey: key))
        // Tokenized exactly once despite three match calls on the same content version.
        XCTAssertEqual(SearchTextMatcher.memoizedTokenizationMisses, 1)

        // A reparse (new size / event count) is a new version → re-tokenized once.
        let key2 = SearchTextMatcher.TokenCacheKey(id: "s1", sizeBytes: 120, eventCount: 4)
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text + " zebra yak", query: "zebra yak", cacheKey: key2))
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

    func testSimplePrefixFastPathPreservesTokenBoundariesAndWholeTokenRanges() {
        let text = "profile profiler PROFILE42 preprofile _profile résuméprofile profile-name"

        let ranges = SearchTextMatcher.matchRanges(in: text, query: "profile")
        let matched = ranges.map { (text as NSString).substring(with: $0) }

        XCTAssertEqual(matched, ["profile", "profiler", "PROFILE42", "profile"])
        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "PROFILE"))
        XCTAssertFalse(SearchTextMatcher.hasMatch(in: "preprofile _profile résuméprofile",
                                                   query: "profile"))
        XCTAssertEqual(SearchTextMatcher.matchRanges(in: text, query: "profile*"), ranges,
                       "an explicit prefix must retain the same token semantics")

        XCTAssertFalse(SearchTextMatcher.hasMatch(in: "ſearch", query: "sea"),
                       "Unicode case folding must not broaden lowercase-prefix semantics")
        XCTAssertEqual(SearchTextMatcher.matchRanges(in: "Kelvin", query: "kel")
            .map { ("Kelvin" as NSString).substring(with: $0) }, ["Kelvin"],
                       "Unicode characters that lowercase to ASCII must retain their old match")
    }

    func testSimplePrefixFastPathDoesNotTokenizeLargeTranscript() {
        let filler = String(repeating: "alpha beta gamma delta ", count: 220_000)
        let text = filler + "profiled"
        let key = SearchTextMatcher.TokenCacheKey(id: "large", sizeBytes: text.utf8.count, eventCount: 1)

        XCTAssertTrue(SearchTextMatcher.hasMatch(in: text, query: "profile", cacheKey: key))
        XCTAssertEqual(SearchTextMatcher.matchRanges(in: text, query: "profile").count, 1)
        XCTAssertEqual(SearchTextMatcher.memoizedTokenizationMisses, 0,
                       "simple prefix search must not allocate a token entry for every unrelated word")
    }
}
