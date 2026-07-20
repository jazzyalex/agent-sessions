import XCTest
@testable import AgentSessions

final class ProbeCleanupHelpersTests: XCTestCase {

    // The exact ps line shape of the real 3-day orphan observed 2026-07-19.
    private let orphanLine = "46300 /opt/homebrew/bin/tmux -L as-cc-uWZOFrvx8vv3 new-session -d -s usage cd '/Users/alexm/Library/Application Support/AgentSessions/ClaudeProbeProject' && env TERM=xterm-256color BROWSER=/usr/bin/true '/Users/alexm/.local/bin/claude' --model sonnet"

    func testSocketlessOrphan_isKilled() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: orphanLine,
                                        socketExists: { _ in false },
                                        killAction: { killed.append($0) })
        XCTAssertEqual(killed, [46300])
    }

    func testLiveSocketServer_isSpared() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: orphanLine,
                                        socketExists: { label in label == "as-cc-uWZOFrvx8vv3" },
                                        killAction: { killed.append($0) })
        XCTAssertTrue(killed.isEmpty)
    }

    func testForeignTmuxServer_isIgnored() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: "999 /opt/homebrew/bin/tmux -L someone-else new-session -d",
                                        socketExists: { _ in false },
                                        killAction: { killed.append($0) })
        XCTAssertTrue(killed.isEmpty)
    }
}
