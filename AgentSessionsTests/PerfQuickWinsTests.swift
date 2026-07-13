import XCTest
@testable import AgentSessions

final class PerfQuickWinsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
        ToolTextBlockNormalizer._testResetNormalizeCache()
    }

    // MARK: - Fixtures

    private func userEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func assistantDelta(_ id: String, _ text: String, messageID: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: messageID, parentID: nil, isDelta: true, rawJSON: "{}")
    }

    private func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: "t-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func session(_ events: [SessionEvent], id: String = "s-perf") -> Session {
        Session(id: id, source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    private func metaEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .meta, role: "system", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func toolCallEvent(_ id: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_call, role: "assistant", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: nil,
                     messageID: "t-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    // MARK: - Task 1: coalescer delta-merge must be linear, not CoW-quadratic

    func testCoalesceLongDeltaChainIsLinearAndLossless() {
        let chunk = String(repeating: "x", count: 200)
        var events: [SessionEvent] = []
        events.reserveCapacity(20_000)
        for i in 0..<20_000 {
            events.append(assistantDelta("a-\(i)", chunk, messageID: "m-single"))
        }
        let s = session(events)

        let start = Date()
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(blocks.count, 1, "one merge chain must coalesce to one block")
        XCTAssertEqual(blocks[0].text.utf8.count, 20_000 * 200, "no bytes lost in merge")
        XCTAssertEqual(blocks[0].globalBlockIndex, 0)
        XCTAssertEqual(blocks[0].firstEventIndex, 0)
        // Quadratic CoW copies ~40 GB here (minutes); linear is milliseconds.
        XCTAssertLessThan(elapsed, 2.0,
            "coalescing a long delta chain must be linear (CoW append was quadratic)")
    }

    // MARK: - Task 2: error/code detection behavior pins (guard the regex hoist)

    func testToolResultErrorClassificationByExitCodeAndPrefix() {
        let cases: [(output: String, isError: Bool)] = [
            ("exit code: 1\nboom", true),
            ("Exit Code: 0\nfine", false),
            ("exit status 2", true),
            ("[error] failed to fetch", true),
            ("error: no such file", true),
            ("all good\nexit code: 1 mentioned later is ignored", false),
            ("plain output", false)
        ]
        for (index, testCase) in cases.enumerated() {
            let (output, isError) = testCase
            // Distinct session id per case: same event COUNT (1) across iterations would
            // otherwise collide on the (session id, event count, includeMeta) memo cache key
            // and return a stale block from a prior iteration.
            let s = session([toolResultEvent("t1", output: output)], id: "s-perf-errclass-\(index)")
            let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0].isErrorOutput, isError, "output: \(output)")
        }
    }

    func testReadToolNumberedDumpClassifiedAsCode() {
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.semanticKind == .code },
                      "line-numbered read-tool output must render as a code segment")
    }

    // MARK: - Task 3: user-anchor sweep parity with the legacy quadratic scan

    /// Verbatim port of the legacy nearestUserBlockIndex closure, used as the oracle.
    private func legacyNearestUserBlockIndex(idx: Int,
                                             userBlockIndices: [Int],
                                             preamble: Set<Int>) -> Int? {
        let prior = userBlockIndices.filter { $0 <= idx }
        if let preferred = prior.last(where: { !preamble.contains($0) }) ?? prior.last {
            return preferred
        }
        let after = userBlockIndices.filter { $0 > idx }
        if let preferred = after.first(where: { !preamble.contains($0) }) ?? after.first {
            return preferred
        }
        return nil
    }

    func testUserAnchorsMatchLegacySemanticsAcrossRandomizedConfigurations() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let blockCount = Int.random(in: 1...80, using: &generator)
            let userBlockIndices = (0..<blockCount).filter { _ in Bool.random(using: &generator) }
            let preamble = Set(userBlockIndices.filter { _ in Bool.random(using: &generator) })

            let fast = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                     preambleUserBlockIndexes: preamble,
                                                     blockCount: blockCount)
            XCTAssertEqual(fast.count, blockCount)
            for idx in 0..<blockCount {
                XCTAssertEqual(fast[idx],
                               legacyNearestUserBlockIndex(idx: idx,
                                                           userBlockIndices: userBlockIndices,
                                                           preamble: preamble),
                               "idx \(idx), users \(userBlockIndices), preamble \(preamble)")
            }
        }
    }

    func testUserAnchorsEdgeCases() {
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 3),
                       [nil, nil, nil])
        // Block before the first user block anchors forward.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [2],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 4),
                       [2, 2, 2, 2])
        // Non-preamble prior beats a later preamble prior.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [0, 2],
                                                     preambleUserBlockIndexes: [2],
                                                     blockCount: 4),
                       [0, 0, 0, 0])
    }

    /// Pin: when EVERY user block is preamble, there is no non-preamble user
    /// block to prefer, so the "last/first user block" fallback (`lastUser` /
    /// `firstAfter`) takes over — the sole user block anchors every index.
    func testUserAnchorsAllPreambleFallsBackToPlainUserBlock() {
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [2],
                                                     preambleUserBlockIndexes: [2],
                                                     blockCount: 4),
                       [2, 2, 2, 2])
    }

    /// Pin: two user blocks, both preamble. No non-preamble candidate exists
    /// anywhere, so every index falls back to plain nearest-user-block
    /// semantics. Expected values are derived from the verbatim legacy oracle
    /// (`legacyNearestUserBlockIndex`), not hand-computed, so this test can't
    /// silently encode a wrong assumption about the fallback order.
    func testUserAnchorsTwoUserAllPreambleMatchesLegacyOracle() {
        let userBlockIndices = [1, 3]
        let preamble: Set<Int> = [1, 3]
        let blockCount = 5

        let fast = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                 preambleUserBlockIndexes: preamble,
                                                 blockCount: blockCount)
        let expected = (0..<blockCount).map {
            legacyNearestUserBlockIndex(idx: $0, userBlockIndices: userBlockIndices, preamble: preamble)
        }
        XCTAssertEqual(fast, expected)
    }

    // MARK: - Task 4c: toolbar nav index caching must be parity-identical with the old per-call scans

    /// Verbatim port of the old `indicesForRole` per-call scan, used as the oracle.
    private func legacyRoleIndices(allIndices: [Int], visibleLineIDs: Set<Int>) -> [Int] {
        allIndices.filter { visibleLineIDs.contains($0) }
    }

    /// Verbatim port of the old `semanticLineIndices` per-call scan, used as the oracle.
    private func legacySemanticLineIndices(_ kind: SemanticKind, in source: [TerminalLine]) -> [Int] {
        var seenGroups: Set<Int> = []
        var out: [Int] = []
        for line in source {
            guard line.semanticKind == kind else { continue }
            if seenGroups.insert(line.decorationGroupID).inserted {
                out.append(line.id)
            }
        }
        return out.sorted()
    }

    func testRoleNavIndicesFiltersToVisibleIDsAndSorts() {
        let allIndices = [40, 10, 30, 20, 50]
        let visibleIDs: Set<Int> = [10, 20, 40]

        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: allIndices, visibleLineIDs: visibleIDs)

        XCTAssertEqual(result, [10, 20, 40], "must filter to visible ids and return sorted order")
        XCTAssertEqual(result, legacyRoleIndices(allIndices: allIndices, visibleLineIDs: visibleIDs).sorted())
    }

    func testRoleNavIndicesEmptyVisibleSetReturnsEmpty() {
        let allIndices = [1, 2, 3]
        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: allIndices, visibleLineIDs: [])
        XCTAssertEqual(result, [])
    }

    func testRoleNavIndicesEmptyAllIndicesReturnsEmpty() {
        let result = TranscriptNavIndexBuilder.roleNavIndices(allIndices: [], visibleLineIDs: [1, 2, 3])
        XCTAssertEqual(result, [])
    }

    func testSemanticNavIndicesMatchesLegacyLoopOnCodeFencedToolOutput() {
        // A line-numbered Read-tool dump renders as `.code` semantic lines grouped
        // by decorationGroupID; verify the fast path returns exactly the legacy
        // first-line-per-group, sorted result.
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)

        XCTAssertTrue(lines.contains { $0.semanticKind == .code }, "fixture must actually produce code lines")

        for kind in [SemanticKind.code, .diff, .plan, .reviewSummary] {
            let fast = TranscriptNavIndexBuilder.semanticNavIndices(kind: kind, source: lines)
            let legacy = legacySemanticLineIndices(kind, in: lines)
            XCTAssertEqual(fast, legacy, "kind \(kind) must match legacy per-call scan exactly")
        }
    }

    func testSemanticNavIndicesEmptySourceReturnsEmpty() {
        XCTAssertEqual(TranscriptNavIndexBuilder.semanticNavIndices(kind: .code, source: []), [])
    }

    // MARK: - Task 4b: memo cache for coalesced blocks

    func testCoalescedBlocksCacheReturnsIdenticalResults() {
        let events: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1"),
            metaEvent("meta1", "some meta note")
        ]
        let s = session(events)

        let firstNoMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let secondNoMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        XCTAssertEqual(firstNoMeta, secondNoMeta, "repeated calls with identical args must return identical blocks")

        let withMeta = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: true)
        XCTAssertNotEqual(firstNoMeta, withMeta,
                           "includeMeta:true and includeMeta:false must not collide on the same cache key")

        // Calling back-to-back with alternating includeMeta must still be correct (no stale hit).
        let noMetaAgain = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let withMetaAgain = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: true)
        XCTAssertEqual(noMetaAgain, firstNoMeta)
        XCTAssertEqual(withMetaAgain, withMeta)
    }

    func testCoalescedBlocksCacheInvalidatesOnEventCountChange() {
        let baseEvents: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1")
        ]
        let sessionID = "s-perf-growing"
        let sessionA = session(baseEvents, id: sessionID)
        let firstResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionA, includeMeta: false)

        var grownEvents = baseEvents
        grownEvents.append(userEvent("u2", "a brand new message"))
        let sessionB = session(grownEvents, id: sessionID)
        let secondResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionB, includeMeta: false)

        XCTAssertNotEqual(firstResult, secondResult,
                           "same session id but different event count must NOT reuse the stale cache entry")
        XCTAssertEqual(secondResult.count, firstResult.count + 1,
                       "appended user event must produce an additional block")
        XCTAssertEqual(secondResult.last?.text, "a brand new message")
    }

    func testCoalescedBlocksCacheInvalidatesOnFileSizeChange() {
        let sessionID = "s-perf-samecounter-rewrite"
        let eventsA: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "world", messageID: "m1")
        ]
        let sessionA = Session(id: sessionID, source: .codex, startTime: nil, endTime: nil,
                                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: 100,
                                eventCount: eventsA.count, events: eventsA)
        let firstResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionA, includeMeta: false)

        // Same id, same event COUNT, but the file was rewritten in place (external edit /
        // crash-recovery re-parse) with different content and a different byte size.
        let eventsB: [SessionEvent] = [
            userEvent("u1", "hello"),
            assistantDelta("a1", "completely different text after rewrite", messageID: "m1")
        ]
        let sessionB = Session(id: sessionID, source: .codex, startTime: nil, endTime: nil,
                                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: 999,
                                eventCount: eventsB.count, events: eventsB)
        let secondResult = SessionTranscriptBuilder.coalescedBlocks(for: sessionB, includeMeta: false)

        XCTAssertNotEqual(firstResult, secondResult,
                           "same id and event count but different fileSizeBytes must NOT reuse the stale cache entry")
        XCTAssertEqual(secondResult.last?.text, "completely different text after rewrite",
                        "must reflect the rewritten session's content, not the cached original")
    }

    func testSemanticNavIndicesDedupesByDecorationGroupID() {
        let lines = [
            TerminalLine(id: 1, text: "a", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 7, semanticKind: .code),
            TerminalLine(id: 2, text: "b", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 7, semanticKind: .code),
            TerminalLine(id: 3, text: "c", role: .toolOutput, eventIndex: nil, blockIndex: nil, decorationGroupID: 8, semanticKind: .code),
            TerminalLine(id: 4, text: "d", role: .assistant, eventIndex: nil, blockIndex: nil, decorationGroupID: 9, semanticKind: nil)
        ]
        let result = TranscriptNavIndexBuilder.semanticNavIndices(kind: .code, source: lines)
        XCTAssertEqual(result, [1, 3], "only first line id per decorationGroupID should be kept, sorted")
    }

    // MARK: - Task 4b (Fix 2): ToolTextBlockNormalizer regex hoist must not change classification

    /// A realistic macOS accessibility-tree dump, as emitted by tools that
    /// snapshot the UI hierarchy (App=/Window:/numbered role lines). This must
    /// be detected and reformatted by `containsAccessibilityTreeLines` +
    /// `readableToolOutputLines`, both before and after hoisting the regexes
    /// to precompiled `NSRegularExpression` constants.
    private func accessibilityTreeDump() -> String {
        """
        App=com.apple.finder
        Window: "Finder"
        1 standard window "Finder" Description: Finder window
        2 button "Close" Description: Close button
        3 text field Value: Documents
        """
    }

    private func nonAccessibilityDump() -> String {
        "plain stdout\nline two\nline three\nno special markers here"
    }

    private func makeToolTextBlock(id: String, text: String, toolName: String = "shell") -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(kind: .toolOut,
                                              text: text,
                                              timestamp: nil,
                                              messageID: nil,
                                              toolName: toolName,
                                              isDelta: false,
                                              toolInput: nil,
                                              isErrorOutput: false,
                                              eventID: id,
                                              rawJSON: "{}")
    }

    func testAccessibilityTreeDumpIsReformattedByNormalize() {
        let block = makeToolTextBlock(id: "ax1", text: accessibilityTreeDump())
        let normalized = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        XCTAssertNotNil(normalized)
        let displayText = ToolTextBlockNormalizer.displayText(for: normalized!)

        // Pinned expected behavior derived from ACTUAL current (pre-hoist) output:
        // accessibility lines are cleaned (App:/Window: rewritten, numbered role
        // lines reformatted), not passed through verbatim.
        XCTAssertTrue(displayText.contains("App: finder"), "App= line must be rewritten to a readable app name (bundle id, \"com.apple.\" stripped, lowercase preserved); got: \(displayText)")
        XCTAssertTrue(displayText.contains("Window: Finder"), "Window: line must be rewritten with the extracted title; got: \(displayText)")
        XCTAssertFalse(displayText.contains("1 standard window \"Finder\" Description: Finder window"),
                       "raw numbered accessibility line must be cleaned, not passed through verbatim")
    }

    /// `containsAccessibilityTreeLines` only scans the first
    /// `accessibilityTreeDetectionScanCap` (200) lines as a perf guard against
    /// an O(n) regex pass over monster tool blocks. Pin: markers appearing
    /// ONLY after line 200 are NOT detected, so the block is classified as
    /// plain output (passed through unchanged), not reformatted as an
    /// accessibility-tree dump. This pins the cap's accepted behavior change,
    /// not an aspirational "scan everything" semantics.
    func testAccessibilityTreeMarkersAfterScanCapAreNotDetected() {
        let plainPrefix = (0..<210).map { "plain line \($0)" }
        let axSuffix = [
            "App=com.apple.finder",
            "Window: \"Finder\"",
            "1 standard window \"Finder\" Description: Finder window",
            "2 button \"Close\" Description: Close button",
            "3 text field Value: Documents"
        ]
        let text = (plainPrefix + axSuffix).joined(separator: "\n")

        let block = makeToolTextBlock(id: "ax-after-cap", text: text)
        let normalized = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        XCTAssertNotNil(normalized)
        let displayText = ToolTextBlockNormalizer.displayText(for: normalized!)

        XCTAssertTrue(displayText.contains("App=com.apple.finder"),
                      "markers past the 200-line scan cap must pass through verbatim, unreformatted; got: \(displayText)")
        XCTAssertFalse(displayText.contains("App: finder"),
                       "no App= rewrite should occur when detection never fires; got: \(displayText)")
    }

    /// Control for the cap test above: the same markers, but within the first
    /// 200 lines, ARE detected and reformatted.
    func testAccessibilityTreeMarkersBeforeScanCapAreDetected() {
        let axPrefix = [
            "App=com.apple.finder",
            "Window: \"Finder\"",
            "1 standard window \"Finder\" Description: Finder window"
        ]
        let plainSuffix = (0..<210).map { "plain line \($0)" }
        let text = (axPrefix + plainSuffix).joined(separator: "\n")

        let block = makeToolTextBlock(id: "ax-before-cap", text: text)
        let normalized = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        XCTAssertNotNil(normalized)
        let displayText = ToolTextBlockNormalizer.displayText(for: normalized!)

        XCTAssertTrue(displayText.contains("App: finder"),
                      "markers within the 200-line scan cap must be detected and reformatted; got: \(displayText)")
    }

    func testNonAccessibilityOutputPassesThroughUnchangedClassification() {
        let block = makeToolTextBlock(id: "plain1", text: nonAccessibilityDump())
        let normalized = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        XCTAssertNotNil(normalized)
        let displayText = ToolTextBlockNormalizer.displayText(for: normalized!)

        // Pinned: plain output must NOT trigger accessibility-tree reformatting.
        XCTAssertTrue(displayText.contains("plain stdout"))
        XCTAssertTrue(displayText.contains("line two"))
        XCTAssertTrue(displayText.contains("line three"))
        XCTAssertTrue(displayText.contains("no special markers here"))
    }

    // MARK: - Task 4b (Fix 3): normalize(block:source:) memoization

    func testNormalizeMemoizationReturnsEqualResultsForSameBlock() {
        let block = makeToolTextBlock(id: "memo1", text: nonAccessibilityDump())
        let first = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        let second = ToolTextBlockNormalizer.normalize(block: block, source: .codex)
        XCTAssertEqual(first, second, "normalizing the identical block twice must yield equal results")
    }

    func testNormalizeMemoizationDoesNotCollideOnSameEventIDDifferentTextLength() {
        // Simulates a live-tail delta-append: same eventID, growing text. The
        // memo key must include text length so the cache doesn't serve a stale
        // (shorter) cached result for the grown block.
        let shortBlock = makeToolTextBlock(id: "grow1", text: "short output")
        let longBlock = makeToolTextBlock(id: "grow1", text: "short output plus a lot more appended tail content")

        let shortResult = ToolTextBlockNormalizer.normalize(block: shortBlock, source: .codex)
        let longResult = ToolTextBlockNormalizer.normalize(block: longBlock, source: .codex)

        XCTAssertNotEqual(shortResult, longResult,
                          "same eventID but different text length must not collide in the memo cache")
        XCTAssertEqual(ToolTextBlockNormalizer.displayText(for: longResult!).contains("plus a lot more appended tail content"), true)
    }

    func testNormalizeMemoizationCachesNilResultsToo() {
        // A `.user` block kind makes `normalize(block:source:)` return nil
        // (early return in the kind switch). Calling twice must not crash or
        // recompute incorrectly, and both calls must return nil.
        let userBlock = SessionTranscriptBuilder.LogicalBlock(kind: .user,
                                                               text: "hello",
                                                               timestamp: nil,
                                                               messageID: nil,
                                                               toolName: nil,
                                                               isDelta: false,
                                                               toolInput: nil,
                                                               isErrorOutput: false,
                                                               eventID: "nilcase1",
                                                               rawJSON: "{}")
        let first = ToolTextBlockNormalizer.normalize(block: userBlock, source: .codex)
        let second = ToolTextBlockNormalizer.normalize(block: userBlock, source: .codex)
        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    /// ACCEPTED-AND-DOCUMENTED theoretical collision: the memo key is
    /// `(eventID, textByteCount, kind, source)` — it does not hash text
    /// content. Two distinct blocks that happen to share eventID, kind,
    /// source, AND byte length (but differ in actual bytes) collide, and the
    /// second lookup returns the FIRST block's cached result. This is a
    /// known, accepted theoretical edge (same-length same-eventID content
    /// substitution is not a real production pattern: eventIDs are unique per
    /// event and live-tail growth changes length), pinned here so a future
    /// change to the cache key can't silently alter this behavior without a
    /// test failing to call it out.
    func testNormalizeMemoizationCollidesOnSameEventIDSameByteLengthDifferentContent() {
        ToolTextBlockNormalizer._testResetNormalizeCache()

        // Same length (12 bytes each), same eventID/kind/source, different content.
        let blockA = makeToolTextBlock(id: "collide1", text: "AAAAAAAAAAAA")
        let blockB = makeToolTextBlock(id: "collide1", text: "BBBBBBBBBBBB")
        XCTAssertEqual(blockA.text.utf8.count, blockB.text.utf8.count,
                       "fixture must have identical byte length to exercise the collision")

        let resultA = ToolTextBlockNormalizer.normalize(block: blockA, source: .codex)
        let resultB = ToolTextBlockNormalizer.normalize(block: blockB, source: .codex)

        // Pinned current behavior: resultB is served from the cache keyed by
        // blockA's (eventID, byteCount, kind, source) tuple, so it equals
        // resultA (content "AAAA...") rather than reflecting blockB's own
        // "BBBB..." text. If this ever starts returning distinct per-block
        // results (e.g. the cache key gains a content hash), this assertion
        // should be updated to XCTAssertNotEqual with a comment explaining
        // the fix.
        XCTAssertEqual(resultA, resultB,
                       "known collision: same (eventID, byteCount, kind, source) key serves the first block's cached result for the second")
        XCTAssertEqual(ToolTextBlockNormalizer.displayText(for: resultB!).contains("AAAAAAAAAAAA"), true,
                       "collided result reflects blockA's content, not blockB's, confirming the stale-cache-hit hypothesis")
    }

    // MARK: - Task 6: URL-free file base name derivation

    func testFileBaseNameMatchesURLBehavior() {
        let paths = [
            "/Users/x/.claude/projects/p/0a1b2c3d-1111-2222-3333-444455556666.jsonl",
            "/tmp/archive.tar.gz",          // only the LAST extension is dropped
            "/tmp/noext",
            "relative/dir/file.jsonl",
            "justafile.jsonl",
            "/tmp/.hiddenfile",             // leading dot is not an extension separator
            "/tmp/dir.with.dots/name.jsonl"
        ]
        for path in paths {
            let expected = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            XCTAssertEqual(SubagentHierarchyBuilder.fileBaseName(ofPath: path), expected, "path: \(path)")
        }
    }

    // MARK: - 2026-07-12 perf audit Fix 3: Session.hasToolCallEvent precomputed bit
    //
    // UnifiedSessionIndexer's hasCommandsOnly filter used to run
    // `s.events.contains { $0.kind == .tool_call }` per session on every filter recompute.
    // hasToolCallEvent precomputes that scan once, inside Session's initializers, from the
    // `events` array passed at construction -- these tests pin that both initializers compute
    // it correctly and that it's re-derived fresh (not stale) whenever a session is
    // reconstructed with a different events array, which is how live-tail growth and
    // DB-hydration merges already rebuild Session values elsewhere in the codebase.

    func testHasToolCallEventTrueWhenEventsContainToolCall() {
        let s = session([userEvent("u1", "hi"), toolCallEvent("tc1"), toolResultEvent("tr1", output: "ok")])
        XCTAssertTrue(s.hasToolCallEvent)
    }

    func testHasToolCallEventFalseWhenNoToolCallEvents() {
        let s = session([userEvent("u1", "hi"), assistantDelta("a1", "hello", messageID: "m1"), metaEvent("meta1", "note")])
        XCTAssertFalse(s.hasToolCallEvent)
    }

    func testHasToolCallEventFalseWhenEventsEmpty() {
        // Lightweight/DB-hydrated-without-events sessions: callers must fall back to
        // lightweightCommands instead of trusting this bit (see UnifiedSessionIndexer).
        let s = session([])
        XCTAssertFalse(s.hasToolCallEvent)
    }

    func testHasToolCallEventComputedByLightweightInitializerToo() {
        // The "lightweight session initializer" overload (cwd/repoName/lightweightTitle) is a
        // second, separate init from the default one `session(_:id:)` exercises above -- both
        // must independently compute hasToolCallEvent from the passed events.
        let events = [userEvent("u1", "hi"), toolCallEvent("tc1")]
        let s = Session(id: "s-lightweight", source: .codex, startTime: nil, endTime: nil,
                         model: "test", filePath: "/tmp/perf.jsonl", eventCount: events.count,
                         events: events, cwd: "/tmp", repoName: "repo", lightweightTitle: "title")
        XCTAssertTrue(s.hasToolCallEvent)

        let noToolEvents = [userEvent("u1", "hi")]
        let s2 = Session(id: "s-lightweight-2", source: .codex, startTime: nil, endTime: nil,
                          model: "test", filePath: "/tmp/perf.jsonl", eventCount: noToolEvents.count,
                          events: noToolEvents, cwd: "/tmp", repoName: "repo", lightweightTitle: "title")
        XCTAssertFalse(s2.hasToolCallEvent)
    }

    func testHasToolCallEventRecomputesOnReconstructionWithDifferentEvents() {
        // Same session id, rebuilt with a different events array (e.g. live-tail growth or a
        // DB-hydration merge) -- hasToolCallEvent must reflect the NEW events, not a stale
        // value carried over from an earlier construction.
        let withTool = session([toolCallEvent("tc1")], id: "s-grow")
        XCTAssertTrue(withTool.hasToolCallEvent)

        let withoutTool = session([userEvent("u1", "hi")], id: "s-grow")
        XCTAssertFalse(withoutTool.hasToolCallEvent)
    }
}
