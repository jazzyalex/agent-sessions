import XCTest
@testable import AgentSessions

final class PiResumeCommandBuilderTests: XCTestCase {
    func testBuildSessionCommandWithWorkingDirectory() throws {
        let builder = PiResumeCommandBuilder()
        let binary = URL(fileURLWithPath: "/usr/local/bin/pi")
        let cwd = URL(fileURLWithPath: "/Users/alex/my repo")

        let package = try builder.makeCommand(strategy: .sessionByID(id: "019e19b4-eb48-746a-aa6b-8dfcfa37954b"),
                                              binaryURL: binary,
                                              workingDirectory: cwd)

        XCTAssertEqual(package.shellCommand,
                       "cd '/Users/alex/my repo' && '/usr/local/bin/pi' --session '019e19b4-eb48-746a-aa6b-8dfcfa37954b'")
    }

    func testBuildContinueWithoutWorkingDirectory() throws {
        let builder = PiResumeCommandBuilder()
        let binary = URL(fileURLWithPath: "/usr/local/bin/pi")

        let package = try builder.makeCommand(strategy: .continueMostRecent,
                                              binaryURL: binary,
                                              workingDirectory: nil)

        XCTAssertEqual(package.shellCommand, "'/usr/local/bin/pi' --continue")
    }

    func testMakeCoreCommandUsesBarePiCommand() throws {
        let builder = PiResumeCommandBuilder()
        let core = try builder.makeCoreCommand(strategy: .sessionByID(id: "pi-session"), binaryCommand: "pi")
        XCTAssertEqual(core, "pi --session pi-session")
    }

    func testMakeCoreCommandIncludesConfiguredSessionDirectory() throws {
        let builder = PiResumeCommandBuilder()
        let core = try builder.makeCoreCommand(strategy: .sessionByID(id: "pi-session"),
                                               binaryCommand: "pi",
                                               sessionDirectory: "/Users/alex/Pi Sessions")

        XCTAssertEqual(core, "pi --session-dir '/Users/alex/Pi Sessions' --session pi-session")
    }

    func testBuildSessionThrowsForEmptyID() {
        let builder = PiResumeCommandBuilder()
        XCTAssertThrowsError(try builder.makeCommand(strategy: .sessionByID(id: " "),
                                                     binaryURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
                                                     workingDirectory: nil))
    }
}
