import XCTest
@testable import AgentSessions

/// Issue #92: on macOS 26 the session-list toolbar group ends at the
/// list/transcript divider instead of floating over both panes.
final class SessionListToolbarLayoutTests: XCTestCase {
    func testGroupEndsOneGutterShortOfTheDivider() {
        let width = SessionListToolbarLayout.groupWidth(dividerX: 900, groupMinX: 150)
        XCTAssertEqual(width, 900 - 150 - SessionListToolbarLayout.dividerGap)
    }

    func testGroupTracksTheDividerWhenItMoves() {
        let narrow = SessionListToolbarLayout.groupWidth(dividerX: 800, groupMinX: 150)
        let wide = SessionListToolbarLayout.groupWidth(dividerX: 1100, groupMinX: 150)
        XCTAssertEqual((wide ?? 0) - (narrow ?? 0), 300)
    }

    func testNarrowListKeepsAWidthTheControlsFitIn() {
        let width = SessionListToolbarLayout.groupWidth(dividerX: 400, groupMinX: 150)
        XCTAssertEqual(width, SessionListToolbarLayout.minimumWidth)
    }

    func testNoDividerMeansNaturalWidth() {
        XCTAssertNil(SessionListToolbarLayout.groupWidth(dividerX: nil, groupMinX: 150),
                     "stacked layout or hidden transcript has nothing to align to")
        XCTAssertNil(SessionListToolbarLayout.groupWidth(dividerX: 900, groupMinX: nil),
                     "not measured yet")
    }

    func testSubPointJitterDoesNotCountAsMovement() {
        XCTAssertTrue(SessionListToolbarLayout.hasMoved(nil, to: 10))
        XCTAssertFalse(SessionListToolbarLayout.hasMoved(10, to: 10.3))
        XCTAssertTrue(SessionListToolbarLayout.hasMoved(10, to: 11))
    }

    func testSearchPlaceholderIsTranslated() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSessions/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["Search sessions"] as? [String: Any])
        let zh = (entry["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any]
        let value = (zh?["stringUnit"] as? [String: Any])?["value"] as? String
        XCTAssertFalse(value?.isEmpty ?? true)
    }
}
