import XCTest
@testable import AgentSessions

final class KimiResumeCommandBuilderTests: XCTestCase {
    private let builder = KimiResumeCommandBuilder()

    /// Kimi session directories are prefixed (`session_<uuid>`), and
    /// `kimi -S session_<uuid>` was confirmed against the real 0.29.1 CLI to
    /// resolve that id. The prefix must survive verbatim.
    func testSessionByIDKeepsThePrefixedSessionID() throws {
        let command = try builder.makeCoreCommand(
            strategy: .sessionByID(id: "session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5"),
            binaryCommand: "kimi")

        XCTAssertEqual(command, "kimi --session session_9eb1bf57-c1af-48a5-b658-0e8d9fe794f5")
    }

    func testContinueMostRecentUsesContinueFlag() throws {
        let command = try builder.makeCoreCommand(strategy: .continueMostRecent, binaryCommand: "kimi")

        XCTAssertEqual(command, "kimi --continue")
    }

    func testStrategyFallsBackToContinueWhenSessionIDIsBlank() {
        guard case .continueMostRecent = builder.strategy(forSessionID: "   ") else {
            return XCTFail("blank id must fall back to --continue")
        }
    }

    func testStrategyPrefersSessionByIDWhenIDPresent() {
        guard case .sessionByID(let id) = builder.strategy(forSessionID: "session_abc") else {
            return XCTFail("non-empty id must resolve to --session")
        }
        XCTAssertEqual(id, "session_abc")
    }

    func testBlankSessionIDIsRejectedRatherThanEmittingBareFlag() {
        XCTAssertThrowsError(try builder.makeCoreCommand(strategy: .sessionByID(id: "  "),
                                                         binaryCommand: "kimi")) { error in
            XCTAssertEqual(error as? KimiResumeCommandBuilder.BuildError, .missingSessionID)
        }
    }

    func testBinaryPathWithSpacesIsQuoted() throws {
        let command = try builder.makeCoreCommand(strategy: .continueMostRecent,
                                                  binaryCommand: "/opt/my tools/kimi")

        XCTAssertEqual(command, "'/opt/my tools/kimi' --continue")
    }
}

extension KimiResumeCommandBuilder.BuildError: Equatable {}
