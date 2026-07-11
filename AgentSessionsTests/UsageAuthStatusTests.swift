import XCTest
@testable import AgentSessions

final class UsageAuthStatusTests: XCTestCase {
    func testSignedOutClaudeCopyAndRemediation() {
        let s = UsageAuthStatus.make(provider: .claude, state: .signedOut)
        XCTAssertEqual(s.state, .signedOut)
        XCTAssertEqual(s.remediation, .showCommand("claude auth login"))
        XCTAssertTrue(s.headline.localizedCaseInsensitiveContains("sign in"))
    }
    func testSignedOutCodexCommand() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .codex, state: .signedOut).remediation,
                       .showCommand("codex login"))
    }
    func testOkIsSilent() {
        let s = UsageAuthStatus.make(provider: .codex, state: .ok)
        XCTAssertEqual(s.remediation, .none)
    }
    func testUnknownIsSilent() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .unknown).remediation, .none)
    }
    /// Claude with no CLI now offers the no-CLI ladder (rung 1 Web API mode,
    /// rung 2 guided install) rather than a bare install link (P3, spec §5).
    func testCliNotInstalledClaudeUsesNoCLILadder() {
        if case .noCLILadder = UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled).remediation { }
        else { XCTFail("expected Claude .cliNotInstalled to offer the no-CLI ladder") }
    }
    /// Codex has no Web API rung, so it keeps the install-link remediation.
    func testCliNotInstalledCodexOpensURL() {
        if case .openURL = UsageAuthStatus.make(provider: .codex, state: .cliNotInstalled).remediation { }
        else { XCTFail("expected Codex .cliNotInstalled to open the install URL") }
    }

    // MARK: - Compact chip label (footer chip + menu-bar surfaces)

    /// The chip drops the verbose "Runway paused — …" headline for a tight,
    /// provider-qualified label.
    func testChipLabelIsShortAndProviderQualified() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .expired).chipLabel, "Claude auth expired")
        XCTAssertEqual(UsageAuthStatus.make(provider: .codex, state: .signedOut).chipLabel, "Codex signed out")
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled).chipLabel, "Claude token needed")
    }

    /// Non-alarming states carry no chip label (nothing to surface).
    func testChipLabelEmptyWhenNotAlarming() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .ok).chipLabel, "")
        XCTAssertEqual(UsageAuthStatus.make(provider: .codex, state: .unknown).chipLabel, "")
    }
}
