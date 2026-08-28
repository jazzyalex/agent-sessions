import XCTest
@testable import AgentSessions

/// Claude's model-scoped weekly window ("Current week (Fable)") only earns a line in the
/// Quota Meter once it is being spent. The threshold is a product decision, and its
/// direction reads both ways — "70% remaining" and "70% used" are opposites, and the wrong
/// reading compiles cleanly and passes every other test in the suite. It was in fact
/// implemented the wrong way round once before the owner disambiguated it, which is why
/// these assertions exist rather than a comment alone.
final class ScopedWeeklyWindowVisibilityTests: XCTestCase {

    func testTheThresholdIsSeventyPercentRemaining() {
        XCTAssertEqual(ScopedWeeklyWindowVisibility.thresholdRemainingPercent, 70)
    }

    func testWindowIsShownAtAndBelowTheThreshold() {
        XCTAssertTrue(ScopedWeeklyWindowVisibility.shows(remainingPercent: 70),
                      "the boundary is inclusive")
        XCTAssertTrue(ScopedWeeklyWindowVisibility.shows(remainingPercent: 31))
        XCTAssertTrue(ScopedWeeklyWindowVisibility.shows(remainingPercent: 0),
                      "an exhausted scoped window is the most important one to surface")
    }

    /// The direction guard. Under the inverted reading ("70% used", i.e. show when
    /// `remaining >= 70`) these two would be visible and the ones above would not.
    func testWindowIsHiddenWhileBarelyTouched() {
        XCTAssertFalse(ScopedWeeklyWindowVisibility.shows(remainingPercent: 71))
        XCTAssertFalse(ScopedWeeklyWindowVisibility.shows(remainingPercent: 100),
                       "an untouched window is noise beside the all-models figure")
    }

    func testNoWindowReportedMeansNothingToShow() {
        XCTAssertFalse(ScopedWeeklyWindowVisibility.shows(remainingPercent: nil))
    }
}
