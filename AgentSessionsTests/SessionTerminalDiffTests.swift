import XCTest
@testable import AgentSessions

final class SessionTerminalDiffTests: XCTestCase {
    func testTailPatchStrategyReturnsAppendForPureTailGrowth() {
        let previous = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two")
        ]
        let current = previous + [line(id: 2, text: "three")]

        XCTAssertEqual(SessionTerminalView.tailPatchStrategy(previous: previous, current: current), .append(startIndex: 2))
    }

    func testTailPatchStrategyReturnsReplaceSuffixForTailRewrite() {
        let previous = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two"),
            line(id: 2, text: "three")
        ]
        let current = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two"),
            line(id: 2, text: "three-updated")
        ]

        XCTAssertEqual(SessionTerminalView.tailPatchStrategy(previous: previous, current: current), .replaceSuffix(startIndex: 2))
    }

    func testTailPatchStrategyReturnsNilWhenPrefixChangesAtStart() {
        let previous = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two")
        ]
        let current = [
            line(id: 99, text: "changed"),
            line(id: 1, text: "two")
        ]

        XCTAssertNil(SessionTerminalView.tailPatchStrategy(previous: previous, current: current))
    }

    func testStableLineSignatureChangesWhenInteriorLineChanges() {
        let base = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two"),
            line(id: 2, text: "three")
        ]
        let mutated = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two-mutated"),
            line(id: 2, text: "three")
        ]

        XCTAssertNotEqual(SessionTerminalView.stableLineSignature(for: base),
                          SessionTerminalView.stableLineSignature(for: mutated))
    }

    func testStableLineSignatureRemainsEqualForIdenticalContent() {
        let lines = [
            line(id: 0, text: "one"),
            line(id: 1, text: "two"),
            line(id: 2, text: "three")
        ]

        XCTAssertEqual(SessionTerminalView.stableLineSignature(for: lines),
                       SessionTerminalView.stableLineSignature(for: lines))
    }

    private func line(id: Int, text: String, role: TerminalLineRole = .assistant, blockIndex: Int? = nil) -> TerminalLine {
        TerminalLine(id: id,
                     text: text,
                     role: role,
                     eventIndex: nil,
                     blockIndex: blockIndex)
    }
}
