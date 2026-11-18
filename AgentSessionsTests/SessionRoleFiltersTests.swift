import XCTest
@testable import AgentSessions

final class SessionRoleFiltersTests: XCTestCase {

    private let all = Set(TranscriptRoleFilter.allCases)

    func testToolsClickOnlyFlipsTools() {
        let off = SessionRoleFilters.toggled([.user, .assistant, .errors], role: .tools)
        XCTAssertEqual(off, all)
        let back = SessionRoleFilters.toggled(all, role: .tools)
        XCTAssertEqual(back, [.user, .assistant, .errors])
        let solo = SessionRoleFilters.toggled([.assistant], role: .tools)
        XCTAssertEqual(solo, [.assistant, .tools])
    }

    func testFocusRuleIgnoresTools() {
        let focused = SessionRoleFilters.toggled(all, role: .assistant)
        XCTAssertEqual(focused, [.assistant, .tools])
        let restored = SessionRoleFilters.toggled(focused, role: .assistant)
        XCTAssertEqual(restored, all)
    }

    func testNeverEmptiesTheThreeRoles() {
        let result = SessionRoleFilters.toggled([.assistant, .tools], role: .assistant)
        XCTAssertEqual(result, all, "the sole role widens back to all three, and Tools stays on")
        let toolsOff = SessionRoleFilters.toggled([.assistant], role: .assistant)
        XCTAssertEqual(toolsOff, [.user, .assistant, .errors])
    }

    func testErrorStopsSkipFailedCallsWhileToolsIsOff() {
        // 4 is a plain .error block; 2 and 9 are failed invocations.
        let stops = [2, 4, 9]
        let failed: Set<Int> = [2, 9]
        XCTAssertEqual(SessionRoleFilters.shownErrorStops(stops, failedInvocationIDs: failed,
                                                          activeRoles: [.user, .assistant, .errors]), [4])
        XCTAssertEqual(SessionRoleFilters.shownErrorStops(stops, failedInvocationIDs: failed, activeRoles: all), stops)
        XCTAssertEqual(SessionRoleFilters.shownErrorStops(stops, failedInvocationIDs: failed, activeRoles: []), stops,
                       "an empty set shows every role")
    }

    // MARK: - Tools that Find turned on

    private typealias State = SessionRoleFilters.State
    private let toolsOff: Set<TranscriptRoleFilter> = [.user, .assistant, .errors]

    func testFindToolsIsNotSaved() {
        let result = SessionRoleFilters.reduce(State(active: toolsOff), .findRequestedTools)
        XCTAssertEqual(result.state, State(active: all, toolsShownByFind: true))
        XCTAssertFalse(result.persist, "Tools that Find turned on is never saved")
    }

    func testFindToolsNoOpWhenToolsAlreadyOn() {
        let result = SessionRoleFilters.reduce(State(active: all), .findRequestedTools)
        XCTAssertEqual(result.state, State(active: all))
        XCTAssertFalse(result.persist)
    }

    func testFindToolsEndsOnSessionChange() {
        let result = SessionRoleFilters.reduce(State(active: all, toolsShownByFind: true), .sessionChanged)
        XCTAssertEqual(result.state, State(active: toolsOff))
        XCTAssertFalse(result.persist)
        // Tools the user turned on stays across sessions.
        let user = SessionRoleFilters.reduce(State(active: all), .sessionChanged)
        XCTAssertEqual(user.state, State(active: all))
    }

    func testChipClickEndsFindToolsAndSavesOnlyTheUsersChoice() {
        let found = State(active: all, toolsShownByFind: true)
        let agent = SessionRoleFilters.reduce(found, .chipClicked(.assistant))
        XCTAssertEqual(agent.state, State(active: [.assistant]), "Find's Tools ends; the click focuses Agent")
        XCTAssertTrue(agent.persist)
        let tools = SessionRoleFilters.reduce(found, .chipClicked(.tools))
        XCTAssertEqual(tools.state, State(active: toolsOff), "a Tools click turns off the Tools the reader sees")
        XCTAssertTrue(tools.persist)
        let plain = SessionRoleFilters.reduce(State(active: toolsOff), .chipClicked(.tools))
        XCTAssertEqual(plain.state, State(active: all))
        XCTAssertTrue(plain.persist)
    }

    func testDefaultFiltersHideTools() {
        XCTAssertEqual(SessionRoleFilters.parsed(SessionRoleFilters.defaultRaw), toolsOff)
    }

    func testMigratedRaw() {
        XCTAssertEqual(SessionRoleFilters.migratedRaw("user,assistant,tools,errors"), "user,assistant,errors")
        XCTAssertEqual(SessionRoleFilters.migratedRaw("user,tools"), "user")
        XCTAssertEqual(SessionRoleFilters.migratedRaw("tools"), SessionRoleFilters.defaultRaw)
        XCTAssertEqual(SessionRoleFilters.migratedRaw("user"), "user")
    }

    func testMigrateIfNeededRunsOnce() {
        let suite = "SessionRoleFiltersTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("user,assistant,tools,errors", forKey: "SessionRoleFilters")
        SessionRoleFilters.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "SessionRoleFilters"), "user,assistant,errors")
        XCTAssertTrue(defaults.bool(forKey: SessionRoleFilters.migrationKey))
        // The user turns Tools on afterwards; a second run must not strip it.
        defaults.set("user,assistant,tools,errors", forKey: "SessionRoleFilters")
        SessionRoleFilters.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "SessionRoleFilters"), "user,assistant,tools,errors")
    }

    func testMigrateWithNoStoredValueWritesNothing() {
        let suite = "SessionRoleFiltersTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SessionRoleFilters.migrateIfNeeded(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "SessionRoleFilters"))
        XCTAssertTrue(defaults.bool(forKey: SessionRoleFilters.migrationKey))
    }
}
