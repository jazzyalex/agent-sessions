import XCTest
@testable import AgentSessions

final class CommandExecutorTests: XCTestCase {
    /// `process.environment = environment` is what makes Finder-launch Pi probes
    /// actually see Homebrew. A mock that records the dict still passes if that
    /// assignment is deleted.
    func testRunAppliesExplicitEnvironmentToChild() throws {
        let result = try ProcessCommandExecutor().run(
            ["/bin/sh", "-c", "printf %s \"$PATH\""],
            cwd: nil,
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "/opt/homebrew/bin:/usr/bin")
    }

    /// The 2-arg `run` must not assign `process.environment = nil`. That
    /// write wipes the child instead of inheriting, and `/bin/sh` then
    /// invents a POSIX default PATH — every other CLI probe would lose
    /// Homebrew. `/usr/bin/env` prints the real child environment.
    func testRunWithNilEnvironmentInheritsParentHOME() throws {
        let parentHOME = ProcessInfo.processInfo.environment["HOME"] ?? ""
        XCTAssertFalse(parentHOME.isEmpty, "test host must have HOME")

        let result = try ProcessCommandExecutor().run(["/usr/bin/env"], cwd: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stdout.split(whereSeparator: \.isNewline)
                .contains(where: { $0 == "HOME=\(parentHOME)" }),
            "nil environment should inherit parent HOME=\(parentHOME); got:\n\(result.stdout)"
        )
    }
}
