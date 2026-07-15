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
}
