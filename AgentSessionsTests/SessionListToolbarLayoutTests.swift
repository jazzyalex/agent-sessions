import XCTest
import SwiftUI
@testable import AgentSessions

private final class ToolbarTestSearchStore: SearchSessionStoring {
    func transcriptCache(for source: SessionSource) -> TranscriptCache? { nil }
    func updateSession(_ session: Session) {}
    func parseFull(session: Session) async -> Session? { session }
}

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

    func testNarrowListNeverPushesTheGroupPastTheDivider() throws {
        let minX: CGFloat = 150
        let dividerX: CGFloat = 400
        let width = try XCTUnwrap(SessionListToolbarLayout.groupWidth(dividerX: dividerX, groupMinX: minX))
        XCTAssertLessThanOrEqual(minX + width, dividerX - SessionListToolbarLayout.dividerGap)
    }

    func testGroupStartingPastTheDividerGetsNoWidth() {
        XCTAssertEqual(SessionListToolbarLayout.groupWidth(dividerX: 100, groupMinX: 150), 0)
    }

    func testPreTahoeListSizingIsUnchanged() {
        if #unavailable(macOS 26.0) {
            XCTAssertEqual(SessionListToolbarLayout.sideBySideListMinWidth, 320)
        } else {
            XCTAssertEqual(SessionListToolbarLayout.sideBySideListMinWidth, SessionListToolbarLayout.tahoeListMinWidth)
        }
    }

    // MARK: - Real control budget (review of 20a1bbbb)

    /// Space for the group above the narrowest macOS 26 list pane. The list
    /// starts at window x = 0 and the divider sits one gutter past its minimum
    /// width. The group's leading edge is assumed at x = 86 (traffic lights end
    /// near 78, plus the toolbar's leading inset); that is an estimate, not a
    /// Tahoe measurement.
    private var narrowestAvailableWidth: CGFloat {
        SessionListToolbarLayout.groupWidth(
            dividerX: SessionListToolbarLayout.tahoeListMinWidth + LayoutTokens.sm,
            groupMinX: 86
        ) ?? 0
    }

    /// Hierarchy browsing (both collapse/expand buttons), every agent enabled,
    /// an empty query (⌥⌘F hint shown) and a long disambiguated project filter.
    @MainActor
    private func worstCaseRow(fillsWidth: Bool) -> SessionListToolbarRow {
        let unified = UnifiedSessionIndexer(catalog: SessionProviderCatalog())
        unified.queryDraft = ""
        unified.projectSelection = ProjectSelection(
            identity: ProjectIdentity(canonicalRootPath: "/Users/t/Repository/an-unusually-long-project-name"),
            displayName: "an-unusually-long-project-name",
            disambiguationPath: "Repository/Clients"
        )
        func spec(_ title: String, _ key: KeyEquivalent?) -> AgentToolbarSpec {
            AgentToolbarSpec(id: title, title: title, color: .gray, isOn: .constant(true), shortcut: key)
        }
        let others = (3...17).map { spec("Agent\($0)", $0 <= 9 ? KeyEquivalent(Character("\($0)")) : nil) }
        let model = SessionListFilterModel(
            liveOnly: .constant(false),
            liveFeatureEnabled: true,
            hierarchy: .constant(true),
            isHierarchyBrowsing: true,
            canCollapseAll: true,
            canExpandAll: true,
            collapseAll: {},
            expandAll: {},
            pinnedAgents: [spec("Codex", "1"), spec("Claude", "2")],
            otherAgents: others,
            isMonochrome: false,
            clearProject: {}
        )
        return SessionListToolbarRow(unified: unified,
                                     search: SearchCoordinator(store: ToolbarTestSearchStore()),
                                     focus: WindowFocusCoordinator(),
                                     searchState: UnifiedSearchState(),
                                     filters: model,
                                     fillsWidth: fillsWidth)
    }

    @MainActor
    func testWorstCaseRowFitsAboveTheNarrowestListWithoutClipping() {
        // The Archived chip reads these preferences directly, not the fixture's
        // agent specs. Pin them on so the chip is always measured.
        let defaults = UserDefaults.standard
        let keys = [PreferencesKey.Agents.codexEnabled, PreferencesKey.Agents.claudeEnabled]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.set(true, forKey: $0) }

        let available = narrowestAvailableWidth
        let host = NSHostingController(rootView: worstCaseRow(fillsWidth: true))

        // Positive control: the regular controls genuinely do not fit, so the
        // assertion below depends on the fallbacks, not on generous geometry.
        let ideal = NSHostingController(rootView: worstCaseRow(fillsWidth: false))
            .sizeThatFits(in: CGSize(width: CGFloat.infinity, height: 60)).width
        XCTAssertGreaterThan(ideal, available, "worst case must overflow at full size")

        // Proposed exactly the available width, the row must not need more:
        // anything wider would be clipped, hiding the project clear button.
        let fitted = host.sizeThatFits(in: CGSize(width: available, height: 60)).width
        // Proposed nothing, the row reports the least it can take (minimal tier,
        // icon chips, compact project button). Measured 359 pt on Sequoia 15.8.
        let minimum = host.sizeThatFits(in: CGSize(width: 0, height: 60)).width
        XCTAssertLessThanOrEqual(fitted, available, "ideal \(ideal), minimum \(minimum), available \(available)")
        XCTAssertLessThanOrEqual(minimum, available, "ideal \(ideal), minimum \(minimum), available \(available)")
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
