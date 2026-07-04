import XCTest
@testable import AgentSessions

/// Pure-math tests for cross-block selection (Task 9, acceptance gate #1).
/// blockOrdinal = index into the CURRENT rows array (loaded/visible order),
/// NOT globalBlockIndex — the table layer owns that mapping.
final class TranscriptSelectionCoordinatorTests: XCTestCase {
    // 3 blocks with UTF-16 lengths 10, 5, 8
    private let lengths = [10, 5, 8]
    private func coord(_ a: (Int, Int), _ f: (Int, Int)) -> TranscriptSelectionCoordinator {
        var c = TranscriptSelectionCoordinator()
        c.begin(at: .init(blockOrdinal: a.0, utf16Offset: a.1))
        c.extend(to: .init(blockOrdinal: f.0, utf16Offset: f.1))
        return c
    }

    func testForwardSpanThreeBlocks() {
        let c = coord((0, 4), (2, 3))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]), NSRange(location: 4, length: 6))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 0, length: 5))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]), NSRange(location: 0, length: 3))
        XCTAssertNil(c.selectionRange(blockOrdinal: 3, textLength: 4))
    }

    func testBackwardDragNormalizes() {
        let c = coord((2, 3), (0, 4))   // dragged upward
        XCTAssertEqual(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]), NSRange(location: 4, length: 6))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 0, length: 5))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]), NSRange(location: 0, length: 3))
    }

    func testSingleBlockSelection() {
        let c = coord((1, 1), (1, 4))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 1, length: 3))
        XCTAssertNil(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]))
        XCTAssertNil(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]))
    }

    func testCopyAssemblyJoinsWithDoubleNewline() {
        let c = coord((0, 4), (2, 3))
        let texts = ["0123456789", "abcde", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "456789\n\nabcde\n\nABC")
    }

    func testCollapsedBlockContributesNothing() {
        var c = coord((0, 0), (2, 3))
        c.excludedBlockOrdinals = [1]   // collapsed tool card
        let texts = ["0123456789", "abcde", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "0123456789\n\nABC")
    }

    // MARK: - Additional edge cases

    /// A fully-selected middle block whose selection covers its entire length
    /// must be INCLUDED (plan hint: full middle-block selections count). This is
    /// already covered by the forward-span test above, but this pins the exact
    /// full-length boundary independently.
    func testFullMiddleBlockIncluded() {
        let c = coord((0, 10), (2, 0))   // anchor at end of block 0, focus at start of block 2
        // Block 0 contributes nothing (start==length), block 2 nothing (length 0),
        // block 1 fully included.
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 0, length: 5))
        let texts = ["0123456789", "abcde", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "abcde")
    }

    /// A single caret (anchor == focus) is not an active selection and yields no text.
    func testCaretOnlyIsInactive() {
        var c = TranscriptSelectionCoordinator()
        c.begin(at: .init(blockOrdinal: 1, utf16Offset: 2))
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 2, length: 0))
        XCTAssertEqual(c.selectedText(blockTexts: ["0123456789", "abcde", "ABCDEFGH"]), "")
    }

    /// clear() drops both endpoints; ranges become nil, isActive false.
    func testClearResets() {
        var c = coord((0, 4), (2, 3))
        c.clear()
        XCTAssertFalse(c.isActive)
        XCTAssertNil(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]))
        XCTAssertEqual(c.selectedText(blockTexts: ["0123456789", "abcde", "ABCDEFGH"]), "")
    }

    /// Offsets past a block's length clamp to the length (recycled-row lengths
    /// can be shorter than the stored focus offset after a collapse/truncation).
    func testOffsetClampsToTextLength() {
        let c = coord((0, 4), (2, 999))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]),
                       NSRange(location: 0, length: lengths[2]))
    }

    /// An empty middle block (textLength 0) contributes no text and is dropped
    /// from the joined output (no spurious blank segment / double separator).
    func testEmptyMiddleBlockDropped() {
        let c = coord((0, 2), (2, 2))
        let texts = ["0123456789", "", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "23456789\n\nAB")
    }
}
