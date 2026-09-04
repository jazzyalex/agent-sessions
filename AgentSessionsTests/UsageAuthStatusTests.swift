import XCTest
@testable import AgentSessions

final class UsageAuthStatusTests: XCTestCase {
    private func localized(_ resource: LocalizedStringResource) -> String {
        String(localized: resource)
    }

    func testSignedOutClaudeCopyAndRemediation() {
        let s = UsageAuthStatus.make(provider: .claude, state: .signedOut)
        XCTAssertEqual(s.state, .signedOut)
        XCTAssertEqual(s.remediation, .showCommand("claude auth login"))
        XCTAssertTrue(localized(s.headline).localizedCaseInsensitiveContains("sign in"))
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
    func testAccountUnavailableDoesNotSuggestReauthentication() {
        let status = UsageAuthStatus.make(provider: .claude, state: .accountUnavailable)
        XCTAssertTrue(status.state.isAlarming)
        XCTAssertEqual(status.remediation, .none)
        XCTAssertEqual(localized(status.chipLabel), "Claude plan inactive")
        XCTAssertTrue(localized(status.detail).localizedCaseInsensitiveContains("plan"))
        XCTAssertFalse(localized(status.detail).contains("claude auth login"))
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
        XCTAssertEqual(localized(UsageAuthStatus.make(provider: .claude, state: .expired).chipLabel), "Claude auth expired")
        XCTAssertEqual(localized(UsageAuthStatus.make(provider: .codex, state: .signedOut).chipLabel), "Codex signed out")
        XCTAssertEqual(localized(UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled).chipLabel), "Claude token needed")
    }

    /// Non-alarming states carry no chip label (nothing to surface).
    func testChipLabelEmptyWhenNotAlarming() {
        XCTAssertEqual(localized(UsageAuthStatus.make(provider: .claude, state: .ok).chipLabel), "")
        XCTAssertEqual(localized(UsageAuthStatus.make(provider: .codex, state: .unknown).chipLabel), "")
    }
}
