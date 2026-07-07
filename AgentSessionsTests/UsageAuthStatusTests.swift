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
    func testCliNotInstalledOpensURL() {
        if case .openURL = UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled).remediation { }
        else { XCTFail("expected openURL remediation") }
    }
}
