import XCTest
@testable import AgentSessions

/// From cli_version ~0.126 Codex writes `originator: "Codex Desktop"` into every
/// rollout regardless of surface, so originator alone cannot classify anything.
/// These pin which field is trusted for which value, and — just as importantly —
/// which one is deliberately still distrusted.
final class CodexSurfaceClassificationTests: XCTestCase {
    private func classify(originator: String?, source: Any?) -> CodexSessionSurface {
        SessionIndexer.classifyCodexSurface(originator: originator,
                                            source: source,
                                            sourceString: source as? String)
    }

    /// The decisive counter-example: a genuine CLI session recording Desktop.
    func testCLISourceBeatsAPinnedDesktopOriginator() {
        XCTAssertEqual(classify(originator: "Codex Desktop", source: "cli"), .cli)
    }

    func testExecSourceBeatsAPinnedDesktopOriginator() {
        XCTAssertEqual(classify(originator: "Codex Desktop", source: "exec"), .cli)
    }

    /// NOT promoted on purpose. Codex Desktop writes `source: "vscode"` too —
    /// 76 rollouts carrying it sit in Desktop's own generated
    /// `~/Documents/Codex/<date>/` chat workspaces. Trusting it would relabel
    /// real Desktop sessions as VS Code and drop them from the Desktop Chats
    /// grouping. Change this only with evidence from a controlled pair of
    /// sessions, never because it looks inconsistent with the two above.
    func testVSCodeSourceDoesNotOverrideADesktopOriginator() {
        XCTAssertEqual(classify(originator: "Codex Desktop", source: "vscode"), .desktop)
    }

    func testSubagentStillWinsOverEverything() {
        XCTAssertEqual(classify(originator: "Codex Desktop", source: ["subagent": ["id": "x"]]), .subagent)
        XCTAssertEqual(classify(originator: "codex-tui", source: ["subagent": ["id": "x"]]), .subagent)
    }

    /// Legacy rollouts (cli_version <= ~0.125) carry a truthful originator and
    /// sometimes no source at all; those rules must keep working.
    func testLegacyOriginatorsStillClassifyWhenSourceIsAbsent() {
        XCTAssertEqual(classify(originator: "codex-tui", source: nil), .cli)
        XCTAssertEqual(classify(originator: "codex_cli_rs", source: nil), .cli)
        XCTAssertEqual(classify(originator: "codex_vscode", source: nil), .vscode)
        XCTAssertEqual(classify(originator: "Codex Desktop", source: nil), .desktop)
    }

    func testUnknownWhenNothingIsRecorded() {
        XCTAssertEqual(classify(originator: nil, source: nil), .unknown)
        XCTAssertEqual(classify(originator: "Claude Code", source: "vscode"), .vscode)
    }
}
