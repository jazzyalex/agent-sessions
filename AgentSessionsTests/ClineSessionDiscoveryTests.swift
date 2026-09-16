import XCTest
@testable import AgentSessions

/// Discovery for Cline session stores, hermetic through an injected home directory
/// and file probe — never the machine the suite runs on.
final class ClineSessionDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/cline-demo", isDirectory: true)
    private let sessionID = "cline-session-001"

    private func probe(sessionsRoot: String, includeMessages: Bool = true) -> FakeFileProbe {
        var files: Set<String> = [
            "\(sessionsRoot)/\(sessionID)/\(sessionID).json"
        ]
        if includeMessages {
            files.insert("\(sessionsRoot)/\(sessionID)/\(sessionID).messages.json")
        }
        return FakeFileProbe(
            files: files,
            directories: ["\(sessionsRoot)", "\(sessionsRoot)/\(sessionID)"]
        )
    }

    func testDefaultRootIsUnderDotClineDataSessions() {
        let discovery = ClineSessionDiscovery(customRoot: nil,
                                              fileProbe: FakeFileProbe(),
                                              homeDirectory: home,
                                              environment: [:])
        XCTAssertEqual(discovery.sessionsRoot().path,
                       home.appendingPathComponent(".cline/data/sessions").path)
        XCTAssertTrue(discovery.discoverSessionFiles().isEmpty)
    }

    func testEnvironmentDataDirPrecedesDefaultRoot() {
        let dataRoot = "/Volumes/cline-data"
        let sessions = "\(dataRoot)/sessions"
        let discovery = ClineSessionDiscovery(customRoot: nil,
                                              fileProbe: probe(sessionsRoot: sessions),
                                              homeDirectory: home,
                                              environment: ["CLINE_DATA_DIR": dataRoot])
        XCTAssertEqual(discovery.sessionsRoot().path, sessions)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    func testEnvironmentDataDirRemainsAuthoritativeWhenItsSessionsRootIsMissing() {
        let dataRoot = "/Volumes/empty-cline-data"
        let defaultSessions = home.appendingPathComponent(".cline/data/sessions").path
        let discovery = ClineSessionDiscovery(
            customRoot: nil,
            fileProbe: probe(sessionsRoot: defaultSessions),
            homeDirectory: home,
            environment: ["CLINE_DATA_DIR": dataRoot]
        )

        XCTAssertEqual(discovery.sessionsRoot().path, "\(dataRoot)/sessions")
        XCTAssertTrue(discovery.discoverSessionFiles().isEmpty,
                      "an explicit empty data root must not expose the default profile")
    }

    func testExplicitOverridePrecedesEnvironmentDataDir() {
        let explicit = "/Volumes/explicit/sessions"
        let environmentData = "/Volumes/environment"
        let combinedProbe = FakeFileProbe(
            files: ["\(explicit)/\(sessionID)/\(sessionID).json",
                    "\(environmentData)/sessions/\(sessionID)/\(sessionID).json"],
            directories: [explicit,
                          "\(explicit)/\(sessionID)",
                          "\(environmentData)/sessions",
                          "\(environmentData)/sessions/\(sessionID)"]
        )
        let discovery = ClineSessionDiscovery(customRoot: explicit,
                                              fileProbe: combinedProbe,
                                              homeDirectory: home,
                                              environment: ["CLINE_DATA_DIR": environmentData])
        XCTAssertEqual(discovery.sessionsRoot().path, explicit)
    }

    func testCustomRootAcceptsSessionsDirectory() {
        let sessions = "/Volumes/data/cline/sessions"
        let discovery = ClineSessionDiscovery(customRoot: sessions,
                                              fileProbe: probe(sessionsRoot: sessions),
                                              homeDirectory: home)
        XCTAssertEqual(discovery.sessionsRoot().path, sessions)
        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent), ["\(sessionID).json"])
        XCTAssertEqual(ClineSessionDiscovery.sessionID(forManifest: discovery.discoverSessionFiles()[0]),
                       sessionID)
    }

    func testCustomRootAcceptsDataRoot() {
        let dataRoot = "/Volumes/data/cline-data"
        let sessions = "/Volumes/data/cline-data/sessions"
        // Pointing at a directory whose `sessions` child exists resolves to it.
        let discovery = ClineSessionDiscovery(customRoot: dataRoot,
                                              fileProbe: probe(sessionsRoot: sessions),
                                              homeDirectory: home)
        XCTAssertEqual(discovery.sessionsRoot().path, sessions)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    func testMissingRootDiscoversNothing() {
        let discovery = ClineSessionDiscovery(customRoot: "/Volumes/nowhere/cline",
                                              fileProbe: FakeFileProbe(),
                                              homeDirectory: home)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 0)
    }

    /// Only immediate session directories with a canonical
    /// `<session-id>/<session-id>.json` manifest qualify. Nested trees,
    /// mismatched basenames and `*.messages.json` files never do.
    func testOnlyCanonicalManifestsAreAccepted() {
        let sessions = "/Users/cline-demo/.cline/data/sessions"
        let other = "other-session"
        let files: Set<String> = [
            "\(sessions)/\(sessionID)/\(sessionID).json",
            "\(sessions)/\(sessionID)/\(sessionID).messages.json",
            "\(sessions)/\(other)/mismatched.json",
            "\(sessions)/\(other)/\(other).messages.json",
            "\(sessions)/nested/deep/deep.json"
        ]
        let dirs: Set<String> = [
            "\(sessions)/\(sessionID)",
            "\(sessions)/\(other)",
            "\(sessions)/nested",
            "\(sessions)/nested/deep"
        ]
        let discovery = ClineSessionDiscovery(customRoot: nil,
                                              fileProbe: FakeFileProbe(files: files, directories: dirs),
                                              homeDirectory: home)
        let found = discovery.discoverSessionFiles()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].lastPathComponent, "\(sessionID).json")
    }

    func testMessagesFilesAreNeverDiscoveryUnits() {
        let manifest = URL(fileURLWithPath: "/s/abc/abc.json")
        let messages = URL(fileURLWithPath: "/s/abc/abc.messages.json")
        XCTAssertEqual(ClineSessionDiscovery.sessionID(forManifest: manifest), "abc")
        XCTAssertNil(ClineSessionDiscovery.sessionID(forManifest: messages))
    }

    func testMessagesFileSitsBesideManifest() {
        let manifest = URL(fileURLWithPath: "/s/abc/abc.json")
        XCTAssertEqual(ClineSessionDiscovery.messagesFile(forManifest: manifest).lastPathComponent,
                       "abc.messages.json")
    }
}
