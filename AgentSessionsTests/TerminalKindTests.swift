import XCTest
@testable import AgentSessions

final class TerminalKindTests: XCTestCase {

    // MARK: - TerminalKind.infer

    func testInferWarpPreviewFromBundleID() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: "dev.warp.Warp-Preview")
        XCTAssertEqual(kind, .warpPreview)
    }

    func testInferWarpStableFromBundleID() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: "dev.warp.Warp")
        XCTAssertEqual(kind, .warp)
    }

    func testInferWarpPreviewFallbackFromTermProgram() {
        let kind = TerminalKind.infer(termProgram: "WarpTerminal", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .warpPreview)
    }

    func testInferITerm2() {
        let kind = TerminalKind.infer(termProgram: "iTerm.app", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .iterm2)
    }

    func testInferTerminalApp() {
        let kind = TerminalKind.infer(termProgram: "Apple_Terminal", cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .terminalApp)
    }

    func testInferUnknownWhenBothNil() {
        let kind = TerminalKind.infer(termProgram: nil, cfBundleIdentifier: nil)
        XCTAssertEqual(kind, .unknown)
    }

    func testBundleIDTakesPriorityOverTermProgram() {
        // TERM_PROGRAM says iTerm but bundle says Warp — bundle wins
        let kind = TerminalKind.infer(termProgram: "iTerm.app", cfBundleIdentifier: "dev.warp.Warp-Preview")
        XCTAssertEqual(kind, .warpPreview)
    }

    // MARK: - newTabURL

    func testWarpPreviewNewTabURL() {
        let url = TerminalKind.warpPreview.newTabURL(cwd: "/Users/test/project")
        XCTAssertEqual(url?.scheme, "warppreview")
        XCTAssertEqual(url?.host, "action")
        XCTAssertEqual(url?.path, "/new_tab")
        XCTAssertEqual(url?.query, "path=/Users/test/project")
    }

    func testWarpNewTabURL() {
        let url = TerminalKind.warp.newTabURL(cwd: "/Users/test")
        XCTAssertEqual(url?.scheme, "warp")
    }

    func testITerm2NewTabURLIsNil() {
        XCTAssertNil(TerminalKind.iterm2.newTabURL(cwd: "/tmp"))
    }

    func testNewTabURLWithNilCwdOmitsQueryParam() {
        let url = TerminalKind.warpPreview.newTabURL(cwd: nil)
        XCTAssertNil(url?.query)
    }
}
