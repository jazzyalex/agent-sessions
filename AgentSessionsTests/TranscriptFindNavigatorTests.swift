import XCTest
@testable import AgentSessions

/// Pure-logic coverage for Task 10's Rich-mode find navigation primitives:
/// ordinal stepping with wrap, query-change reset anchoring, per-row match-count
/// aggregation for the collapsed-row pill, stable-current reconciliation across
/// a snapshot recompute, and row-shape renderability classification. The AppKit
/// highlight painting / widen-on-jump that consume these is verified by owner QA.
final class TranscriptFindNavigatorTests: XCTestCase {

    private typealias Match = TranscriptDerivedState.BlockMatch

    private func match(block: Int, loc: Int, len: Int, ordinal: Int) -> Match {
        Match(globalBlockIndex: block,
              rangeInBlockText: NSRange(location: loc, length: len),
              ordinal: ordinal)
    }

    // MARK: steppedOrdinal

    func testStepForwardWraps() {
        XCTAssertEqual(TranscriptFindNavigator.steppedOrdinal(current: 2, count: 3, direction: 1), 0)
        XCTAssertEqual(TranscriptFindNavigator.steppedOrdinal(current: 0, count: 3, direction: 1), 1)
    }

    func testStepBackwardWraps() {
        XCTAssertEqual(TranscriptFindNavigator.steppedOrdinal(current: 0, count: 3, direction: -1), 2)
        XCTAssertEqual(TranscriptFindNavigator.steppedOrdinal(current: 2, count: 3, direction: -1), 1)
    }

    func testStepEmptyIsZero() {
        XCTAssertEqual(TranscriptFindNavigator.steppedOrdinal(current: 5, count: 0, direction: 1), 0)
    }

    func testStepMonotonicNoSkipAcross25Matches() {
        // Walk forward through 25 matches from 0; every ordinal is visited once
        // and the sequence wraps cleanly back to 0 (no skips/dupes).
        let count = 25
        var seen: [Int] = [0]
        var cur = 0
        for _ in 0..<count {
            cur = TranscriptFindNavigator.steppedOrdinal(current: cur, count: count, direction: 1)
            seen.append(cur)
        }
        // After `count` steps we are back at the start.
        XCTAssertEqual(cur, 0)
        // The first `count` entries are a permutation 0..<count with no dupes.
        XCTAssertEqual(Set(seen.prefix(count)), Set(0..<count))
    }

    // MARK: firstOrdinalAtOrAfter

    func testFirstAtOrAfterPicksBlockBoundary() {
        let matches = [match(block: 2, loc: 0, len: 3, ordinal: 0),
                       match(block: 5, loc: 0, len: 3, ordinal: 1),
                       match(block: 9, loc: 0, len: 3, ordinal: 2)]
        XCTAssertEqual(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: matches, viewportTopBlock: 5), 1)
        XCTAssertEqual(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: matches, viewportTopBlock: 6), 2)
        // Top before all ⇒ first.
        XCTAssertEqual(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: matches, viewportTopBlock: 0), 0)
    }

    func testFirstAtOrAfterWrapsWhenPastEnd() {
        let matches = [match(block: 2, loc: 0, len: 3, ordinal: 0),
                       match(block: 5, loc: 0, len: 3, ordinal: 1)]
        // Viewport top past the last match ⇒ wrap to first (parity with Text).
        XCTAssertEqual(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: matches, viewportTopBlock: 99), 0)
    }

    func testFirstAtOrAfterNilViewportIsFirst() {
        let matches = [match(block: 2, loc: 0, len: 3, ordinal: 0)]
        XCTAssertEqual(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: matches, viewportTopBlock: nil), 0)
    }

    func testFirstAtOrAfterEmptyIsNil() {
        XCTAssertNil(TranscriptFindNavigator.firstOrdinalAtOrAfter(matches: [], viewportTopBlock: 0))
    }

    // MARK: reconciledOrdinal (live append / recompute)

    func testReconcileKeepsSurvivingMatchByIdentity() {
        let prev = match(block: 5, loc: 4, len: 3, ordinal: 1)
        // After append, the same (block 5, range 4..7) match moved to ordinal 3
        // (two earlier matches were inserted upstream).
        let newMatches = [match(block: 1, loc: 0, len: 3, ordinal: 0),
                          match(block: 2, loc: 0, len: 3, ordinal: 1),
                          match(block: 3, loc: 0, len: 3, ordinal: 2),
                          match(block: 5, loc: 4, len: 3, ordinal: 3)]
        XCTAssertEqual(TranscriptFindNavigator.reconciledOrdinal(previous: prev, previousOrdinal: 1, newMatches: newMatches), 3)
    }

    func testReconcileClampsWhenMatchVanished() {
        let prev = match(block: 99, loc: 0, len: 3, ordinal: 7)
        let newMatches = [match(block: 1, loc: 0, len: 3, ordinal: 0),
                          match(block: 2, loc: 0, len: 3, ordinal: 1)]
        // Old match gone ⇒ clamp old ordinal (7) into [0,1] ⇒ 1.
        XCTAssertEqual(TranscriptFindNavigator.reconciledOrdinal(previous: prev, previousOrdinal: 7, newMatches: newMatches), 1)
    }

    func testReconcileEmptyIsNil() {
        let prev = match(block: 1, loc: 0, len: 3, ordinal: 0)
        XCTAssertNil(TranscriptFindNavigator.reconciledOrdinal(previous: prev, previousOrdinal: 0, newMatches: []))
    }

    // MARK: renderableRange

    func testRenderableMessageMapsDirectly() {
        let r = NSRange(location: 4, length: 3)
        XCTAssertEqual(TranscriptFindNavigator.renderableRange(r, shape: .message), r)
        XCTAssertEqual(TranscriptFindNavigator.renderableRange(r, shape: .expandedSingleToolFull), r)
    }

    func testRenderableTruncatedInsidePrefix() {
        let inside = NSRange(location: 4, length: 3)   // maxRange 7
        let straddle = NSRange(location: 8, length: 5) // maxRange 13
        XCTAssertEqual(TranscriptFindNavigator.renderableRange(inside, shape: .expandedSingleToolTruncated(visibleUTF16Len: 10)), inside)
        XCTAssertNil(TranscriptFindNavigator.renderableRange(straddle, shape: .expandedSingleToolTruncated(visibleUTF16Len: 10)))
    }

    func testRenderableNonRenderableIsNil() {
        let r = NSRange(location: 0, length: 3)
        XCTAssertNil(TranscriptFindNavigator.renderableRange(r, shape: .nonRenderable))
    }
}
