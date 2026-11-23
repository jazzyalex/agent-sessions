import XCTest
import SwiftUI
import Combine
@testable import AgentSessions

private final class ToolbarTestSearchStore: SearchSessionStoring {
    func transcriptCache(for source: SessionSource) -> TranscriptCache? { nil }
    func updateSession(_ session: Session) {}
    func parseFull(session: Session) async -> Session? { session }
}

/// The session list owns its controls and reserves a separate row for feedback.
final class SessionListToolbarLayoutTests: XCTestCase {
    @MainActor
    func testSearchDisplayRowsAreSortedWithoutReapplyingEligibilityFilters() {
        let unified = UnifiedSessionIndexer(catalog: SessionProviderCatalog())
        let oldHasCommandsOnly = unified.hasCommandsOnly
        defer { unified.hasCommandsOnly = oldHasCommandsOnly }
        unified.hasCommandsOnly = true
        let acceptedLightweightRow = Session(
            id: "accepted", source: .claude, startTime: nil, endTime: Date(), model: nil,
            filePath: "/tmp/accepted.jsonl", eventCount: 0, events: [],
            cwd: nil, repoName: nil,
            lightweightTitle: "Accepted search result", lightweightCommands: nil,
            parentSessionID: "parent"
        )

        XCTAssertEqual(unified.sortSearchResultsForDisplay([acceptedLightweightRow]).map(\.id), ["accepted"])
        XCTAssertTrue(unified.applyFiltersAndSort(to: [acceptedLightweightRow]).isEmpty,
                      "the old second filtering pass rejected the coordinator's accepted lightweight row")
    }

    @MainActor
    func testFocusedCommandsPublishAvailabilityOnlyWhenItChanges() {
        let unified = UnifiedSessionIndexer(catalog: SessionProviderCatalog())
        let commands = SessionWindowCommands(archiveIndexer: unified)
        var updates: [SessionWindowCommands.Availability] = []
        let observation = commands.$availability.sink { updates.append($0) }
        defer { observation.cancel() }

        let enabled = SessionWindowCommands.Availability(resume: true)
        var action = 0
        commands.update(enabled, resume: { action = 1 }, copyResumeCommand: nil,
                        openInCodexDesktop: nil, setFolding: nil)
        commands.update(enabled, resume: { action = 2 }, copyResumeCommand: nil,
                        openInCodexDesktop: nil, setFolding: nil)
        commands.resume?()

        XCTAssertEqual(action, 2)
        XCTAssertEqual(updates, [.init(), enabled])
        commands.clear()
        XCTAssertNil(commands.resume)
        XCTAssertEqual(updates, [.init(), enabled, .init()])
    }

    func testPreTahoeListSizingIsUnchanged() {
        if #unavailable(macOS 26.0) {
            XCTAssertEqual(SessionListToolbarLayout.sideBySideListMinWidth, 320)
        } else {
            XCTAssertEqual(SessionListToolbarLayout.sideBySideListMinWidth, SessionListToolbarLayout.tahoeListMinWidth)
        }
    }

    /// Every agent enabled, hidden projects, and a long disambiguated project.
    @MainActor
    private func header(query: String = "", showsScope: Bool = false) -> SessionListHeader {
        let unified = UnifiedSessionIndexer(catalog: SessionProviderCatalog())
        unified.queryDraft = query
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
            folding: .constant(.collapsed),
            hasGroups: true,
            pinnedAgents: [spec("Codex", "1"), spec("Claude", "2")],
            otherAgents: others,
            isMonochrome: false,
            hiddenProjectRoots: ["/tmp/automation-project"]
        )
        var scope = SessionScope()
        if showsScope {
            scope.add("Archived Codex sessions only", "Show current Codex sessions") {}
            scope.add("An unusually long agent filter name", "Show other agents") {}
            scope.hiddenRoots = ["/tmp/automation-project"]
        }
        return SessionListHeader(unified: unified,
                                 search: SearchCoordinator(store: ToolbarTestSearchStore()),
                                 focus: WindowFocusCoordinator(),
                                 searchState: UnifiedSearchState(),
                                 filters: model, scope: scope, runSearch: { _ in })
    }

    @MainActor
    private func controlRow(for header: SessionListHeader) -> SessionListToolbarRow {
        SessionListToolbarRow(unified: header.unified, search: header.search,
                              focus: header.focus, searchState: header.searchState,
                              filters: header.filters, runSearch: header.runSearch,
                              searchDebouncer: .constant(nil))
    }

    @MainActor
    private func measure(_ view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 200))
    }

    @MainActor
    func testControlsFitInNarrowListPane() {
        let available = SessionListToolbarLayout.sideBySideListMinWidth - 2 * LayoutTokens.sm
        let row = controlRow(for: header())
        XCTAssertGreaterThan(measure(row, width: .infinity).width, available)
        XCTAssertLessThanOrEqual(measure(row, width: available).width, available)
        XCTAssertLessThanOrEqual(measure(row, width: 0).width, available)
    }

    @MainActor
    func testControlsFitAtClassicMinimumWidth() {
        let available: CGFloat = 320 - 2 * LayoutTokens.sm
        let row = controlRow(for: header(query: "build failed"))
        XCTAssertLessThanOrEqual(measure(row, width: available).width, available)
    }

    @MainActor
    func testSearchAndScopeFeedbackReserveHeightBelowControlRow() {
        for width in [SessionListToolbarLayout.sideBySideListMinWidth, 960] {
            let idle = header()
            let scoped = header(showsScope: true)
            let searching = header(query: "build failed", showsScope: true)
            let idleControls = measure(controlRow(for: idle), width: width - 2 * LayoutTokens.sm)
            let searchingControls = measure(controlRow(for: searching), width: width - 2 * LayoutTokens.sm)
            XCTAssertEqual(idleControls.height, searchingControls.height, accuracy: 1)
            XCTAssertGreaterThan(measure(scoped, width: width).height, measure(idle, width: width).height)
            XCTAssertGreaterThan(measure(searching, width: width).height, measure(scoped, width: width).height)
            XCTAssertLessThanOrEqual(measure(searching, width: width).width, width)
        }
    }

    @MainActor
    func testNativeSearchFieldRendersInsideListHeader() throws {
        let width = SessionListToolbarLayout.sideBySideListMinWidth
        let content = header(query: "build failed", showsScope: true)
        let size = measure(content, width: width)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        hostingView.layoutSubtreeIfNeeded()

        func searchInput(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { searchInput(in: $0) }.first
        }

        let field = try XCTUnwrap(searchInput(in: hostingView))
        let frame = field.convert(field.bounds, to: hostingView)
        XCTAssertGreaterThan(frame.minX, 0)
        XCTAssertLessThan(frame.maxX, width)
        let top = hostingView.isFlipped ? frame.minY : hostingView.bounds.maxY - frame.maxY
        XCTAssertGreaterThanOrEqual(top, 0)
        XCTAssertLessThan(top, LayoutTokens.xl)
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
