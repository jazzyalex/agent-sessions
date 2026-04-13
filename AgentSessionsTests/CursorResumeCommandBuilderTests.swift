import XCTest
@testable import AgentSessions

final class CursorResumeCommandBuilderTests: XCTestCase {
    func testBuildResumeWithWorkingDirectory() throws {
        let builder = CursorResumeCommandBuilder()
        let binary = URL(fileURLWithPath: "/usr/local/bin/agent")
        let cwd = URL(fileURLWithPath: "/Users/alex/my repo")

        let pkg = try builder.makeCommand(strategy: .resumeByID(id: "178ea7fa-c37b-43e1-a9e6-bfbe996c0c55"),
                                          binaryURL: binary,
                                          workingDirectory: cwd)

        XCTAssertEqual(pkg.shellCommand,
                       "cd '/Users/alex/my repo' && '/usr/local/bin/agent' --resume '178ea7fa-c37b-43e1-a9e6-bfbe996c0c55'")
    }

    func testBuildContinueWithoutWorkingDirectory() throws {
        let builder = CursorResumeCommandBuilder()
        let binary = URL(fileURLWithPath: "/usr/local/bin/agent")

        let pkg = try builder.makeCommand(strategy: .continueMostRecent,
                                          binaryURL: binary,
                                          workingDirectory: nil)

        XCTAssertEqual(pkg.shellCommand, "'/usr/local/bin/agent' --continue")
    }

    func testBuildResumeWithCursorBinaryUsesAgentSubcommand() throws {
        let builder = CursorResumeCommandBuilder()
        let binary = URL(fileURLWithPath: "/usr/local/bin/cursor")

        let pkg = try builder.makeCommand(strategy: .resumeByID(id: "chat-123"),
                                          binaryURL: binary,
                                          workingDirectory: nil)

        XCTAssertEqual(pkg.shellCommand, "'/usr/local/bin/cursor' agent --resume 'chat-123'")
    }

    func testMakeCoreCommandWithBareCursorUsesAgentSubcommand() throws {
        let builder = CursorResumeCommandBuilder()
        let core = try builder.makeCoreCommand(strategy: .continueMostRecent, binaryCommand: "cursor")
        XCTAssertEqual(core, "cursor agent --continue")
    }

    func testBuildResumeThrowsForEmptyID() {
        let builder = CursorResumeCommandBuilder()
        XCTAssertThrowsError(try builder.makeCommand(strategy: .resumeByID(id: "  "),
                                                     binaryURL: URL(fileURLWithPath: "/usr/local/bin/agent"),
                                                     workingDirectory: nil))
    }
}
