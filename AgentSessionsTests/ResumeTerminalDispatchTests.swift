// AgentSessionsLogicTests/ResumeTerminalDispatchTests.swift
import XCTest
@testable import AgentSessions

final class ResumeTerminalDispatchTests: XCTestCase {

    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ResumeTerminalDispatchTests")
        XCTAssertNotNil(defaults, "Failed to create isolated UserDefaults suite")
        defaults.removePersistentDomain(forName: "ResumeTerminalDispatchTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ResumeTerminalDispatchTests")
        super.tearDown()
    }

    // MARK: - resolveTerminalKind

    func testDefaultsToTerminalAppWhenNothingSet() {
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .terminalApp)
    }

    func testReadsStoredTerminalKind() {
        defaults.set(TerminalKind.warp.rawValue, forKey: ResumePreferenceHelpers.terminalKindKey)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .warp)
    }

    func testReadsStoredWarpPreview() {
        defaults.set(TerminalKind.warpPreview.rawValue, forKey: ResumePreferenceHelpers.terminalKindKey)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .warpPreview)
    }

    func testMigratesFromClaudePreferITermTrue() {
        defaults.set(true, forKey: ClaudeResumeSettings.Keys.preferITerm)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .iterm2)
    }

    func testMigratesFromClaudePreferITermFalse() {
        defaults.set(false, forKey: ClaudeResumeSettings.Keys.preferITerm)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .terminalApp)
    }

    func testMigratesFromCodexITermLaunchMode() {
        defaults.set(CodexLaunchMode.iterm.rawValue, forKey: CodexResumeSettings.Keys.defaultLaunchMode)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .iterm2)
    }

    func testStoredKindTakesPriorityOverMigration() {
        defaults.set(true, forKey: ClaudeResumeSettings.Keys.preferITerm)
        defaults.set(TerminalKind.warp.rawValue, forKey: ResumePreferenceHelpers.terminalKindKey)
        let kind = ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults)
        XCTAssertEqual(kind, .warp)
    }

    // MARK: - setTerminalKind

    func testSetTerminalKindPersists() {
        ResumePreferenceHelpers.setTerminalKind(.warpPreview, defaults: defaults)
        let raw = defaults.string(forKey: ResumePreferenceHelpers.terminalKindKey)
        XCTAssertEqual(raw, TerminalKind.warpPreview.rawValue)
    }

    func testSetThenResolveRoundTrip() {
        ResumePreferenceHelpers.setTerminalKind(.iterm2, defaults: defaults)
        XCTAssertEqual(ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults), .iterm2)

        ResumePreferenceHelpers.setTerminalKind(.warp, defaults: defaults)
        XCTAssertEqual(ResumePreferenceHelpers.resolveTerminalKind(defaults: defaults), .warp)
    }
}
