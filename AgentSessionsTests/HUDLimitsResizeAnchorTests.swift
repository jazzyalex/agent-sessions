import XCTest
@testable import AgentSessions

/// The Quota Meter is a pinned widget parked somewhere deliberate. A reveal and
/// its collapse must leave it exactly where it started, which means the pair has
/// to pin the same edge.
final class HUDLimitsResizeAnchorTests: XCTestCase {
    /// The regression: growth near the bottom of the screen pins the *bottom*
    /// and rises, but the collapse used to pin the top unconditionally — so the
    /// window kept the raised top and walked up one toolbar height per
    /// right-click.
    func testShrinkMirrorsAGrowthThatWentUp() {
        let grewUpAnchoredTop = HUDLimitsResizeAnchor.anchorsTop(
            isGrowing: true, growsDown: false, lastGrowAnchoredTop: true
        )
        XCTAssertFalse(grewUpAnchoredTop, "Growing up must pin the bottom edge.")

        let shrinkAnchorsTop = HUDLimitsResizeAnchor.anchorsTop(
            isGrowing: false, growsDown: true, lastGrowAnchoredTop: grewUpAnchoredTop
        )
        XCTAssertFalse(shrinkAnchorsTop, "Collapse must release the same edge the growth pinned.")
    }

    func testShrinkMirrorsAGrowthThatWentDown() {
        let grewDownAnchoredTop = HUDLimitsResizeAnchor.anchorsTop(
            isGrowing: true, growsDown: true, lastGrowAnchoredTop: false
        )
        XCTAssertTrue(grewDownAnchoredTop, "Growing down must pin the top edge.")

        let shrinkAnchorsTop = HUDLimitsResizeAnchor.anchorsTop(
            isGrowing: false, growsDown: false, lastGrowAnchoredTop: grewDownAnchoredTop
        )
        XCTAssertTrue(shrinkAnchorsTop, "Collapse must release the same edge the growth pinned.")
    }

    /// A shrink must never consult the live growth direction — that is exactly
    /// the independent decision that caused the drift.
    func testShrinkIgnoresCurrentGrowthDirection() {
        for growsDown in [true, false] {
            XCTAssertTrue(
                HUDLimitsResizeAnchor.anchorsTop(isGrowing: false, growsDown: growsDown, lastGrowAnchoredTop: true)
            )
            XCTAssertFalse(
                HUDLimitsResizeAnchor.anchorsTop(isGrowing: false, growsDown: growsDown, lastGrowAnchoredTop: false)
            )
        }
    }

    /// A growth decides for itself and ignores whatever the previous one chose.
    func testGrowthUsesRoomOnScreenNotHistory() {
        XCTAssertTrue(
            HUDLimitsResizeAnchor.anchorsTop(isGrowing: true, growsDown: true, lastGrowAnchoredTop: false)
        )
        XCTAssertFalse(
            HUDLimitsResizeAnchor.anchorsTop(isGrowing: true, growsDown: false, lastGrowAnchoredTop: true)
        )
    }

    /// Round trip: whatever the growth chose, applying it then its mirror must
    /// return the window to its original frame.
    func testRevealCollapseRoundTripIsAFixedPoint() {
        for growsDown in [true, false] {
            let originY: CGFloat = 500
            let startHeight: CGFloat = 120
            let expandedHeight: CGFloat = 164

            var y = originY
            let growAnchorsTop = HUDLimitsResizeAnchor.anchorsTop(
                isGrowing: true, growsDown: growsDown, lastGrowAnchoredTop: true
            )
            if growAnchorsTop { y += startHeight - expandedHeight }

            let shrinkAnchorsTop = HUDLimitsResizeAnchor.anchorsTop(
                isGrowing: false, growsDown: growsDown, lastGrowAnchoredTop: growAnchorsTop
            )
            if shrinkAnchorsTop { y += expandedHeight - startHeight }

            XCTAssertEqual(y, originY, "growsDown=\(growsDown): the window must land where it started.")
        }
    }

    /// The floating window is fixed-size and clips its content, so the clamp is
    /// the most content it can show. 270 pt clipped the OpenCode group, which
    /// renders last; the owner raised it to 500 pt (no scrolling).
    func testContentHeightClampsTo500Points() {
        XCTAssertEqual(HUDLimitsContentHeight.maximum, 500)
        XCTAssertEqual(HUDLimitsContentHeight.clamped(420), 420, "content between 270 and 500 pt must no longer be cut")
        XCTAssertEqual(HUDLimitsContentHeight.clamped(800), 500)
        XCTAssertEqual(HUDLimitsContentHeight.clamped(10), 30, "the 30 pt minimum is unchanged")
    }
}

/// A runaway Quota Meter frame was autosaved, and restoring it crashed the app every time the
/// window opened. Only the saved corner may come back; the size is the content's.
final class HUDLimitsSavedFrameTests: XCTestCase {
    /// A MacBook display (1800 x 1169, notch) under a 3200 x 1800 monitor placed above and left.
    private let screens = [
        CGRect(x: 0, y: 0, width: 1800, height: 1132),
        CGRect(x: -1025, y: 1169, width: 3200, height: 1770)
    ]

    func testRunawayFrameRestoresOnlyItsCorner() throws {
        let saved = try XCTUnwrap(HUDLimitsSavedFrame.parse("-1025 -659 4503 2991 -1025 1169 3200 1770 "))
        XCTAssertEqual(saved, CGRect(x: -1025, y: -659, width: 4503, height: 2991))

        let restored = HUDLimitsSavedFrame.restoredFrame(
            saved: saved, size: CGSize(width: 417, height: 90), visibleFrames: screens
        )
        XCTAssertEqual(restored, CGRect(x: -1025, y: 2242, width: 417, height: 90),
                       "same top-left corner as before the runaway, at the content's size")
    }

    func testCornerOffEveryScreenFallsBackToTheDefault() {
        let saved = CGRect(x: 5000, y: 5000, width: 417, height: 90)
        XCTAssertNil(HUDLimitsSavedFrame.restoredFrame(
            saved: saved, size: CGSize(width: 417, height: 90), visibleFrames: screens
        ))
        XCTAssertNil(HUDLimitsSavedFrame.parse("not a frame"))
    }

    func testRestoredWindowStaysOnItsScreen() {
        // Parked at the right edge of the monitor; the window must not hang off it.
        let saved = CGRect(x: 2100, y: 1200, width: 417, height: 90)
        let restored = HUDLimitsSavedFrame.restoredFrame(
            saved: saved, size: CGSize(width: 417, height: 300), visibleFrames: screens
        )
        XCTAssertEqual(restored, CGRect(x: 2175 - 417, y: 1169, width: 417, height: 300))
    }
}
