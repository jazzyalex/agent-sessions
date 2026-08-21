import XCTest
@testable import AgentSessions

/// Discovery for fx session stores, hermetic through an injected home directory
/// and file probe — never the machine the suite runs on.
final class FxSessionDiscoveryTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/fx-demo", isDirectory: true)
    private let sessionID = "1787261000000-1787261000000000000-0000000000000001"

    private func probe(sessionsRoot: String) -> FakeFileProbe {
        FakeFileProbe(
            files: [
                "\(sessionsRoot)/\(sessionID)/checkpoint.json",
                "\(sessionsRoot)/\(sessionID)/session.json"
            ],
            directories: ["\(sessionsRoot)", "\(sessionsRoot)/\(sessionID)"]
        )
    }

    func testDefaultRootIsUnderDotFx() {
        let discovery = FxSessionDiscovery(customRoot: nil,
                                           fileProbe: FakeFileProbe(),
                                           homeDirectory: home)
        XCTAssertEqual(discovery.sessionsRoot().path,
                       home.appendingPathComponent(".fx/sessions").path)
        XCTAssertTrue(discovery.discoverSessionFiles().isEmpty)
    }

    /// The custom root accepts the sessions directory itself.
    func testCustomRootAcceptsSessionsDirectory() {
        let sessions = "/Volumes/data/fx/sessions"
        let discovery = FxSessionDiscovery(customRoot: sessions,
                                           fileProbe: probe(sessionsRoot: sessions),
                                           homeDirectory: home)
        XCTAssertEqual(discovery.sessionsRoot().path, sessions)
        XCTAssertEqual(discovery.discoverSessionFiles().map(\.lastPathComponent), ["checkpoint.json"])
        XCTAssertEqual(FxSessionDiscovery.sessionID(forCheckpoint: discovery.discoverSessionFiles()[0]),
                       sessionID)
    }

    /// …and the `.fx` data root above it.
    func testCustomRootAcceptsDataRoot() {
        let dataRoot = "/Volumes/data/fx"
        let sessions = "/Volumes/data/fx/sessions"
        let discovery = FxSessionDiscovery(customRoot: dataRoot,
                                           fileProbe: probe(sessionsRoot: sessions),
                                           homeDirectory: home)
        XCTAssertEqual(discovery.sessionsRoot().path, sessions)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }

    /// A root pointing at nothing discovers nothing without crashing.
    func testMissingRootDiscoversNothing() {
        let discovery = FxSessionDiscovery(customRoot: "/Volumes/nowhere/fx",
                                           fileProbe: FakeFileProbe(),
                                           homeDirectory: home)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 0)
    }

    /// `latest/` is a CLI pointer directory, not a session — even when it holds
    /// a fully-formed checkpoint + sidecar pair. A session whose sidecar is
    /// missing is skipped too.
    func testPointerDirectoriesAndSidecarlessSessionsAreSkipped() {
        let sessions = "/Users/fx-demo/.fx/sessions"
        let second = "1787262000000-1787262000000000000-0000000000000002"
        let files: Set<String> = [
            "\(sessions)/\(sessionID)/checkpoint.json",
            "\(sessions)/\(sessionID)/session.json",
            "\(sessions)/latest/checkpoint.json",
            "\(sessions)/latest/session.json",
            "\(sessions)/\(second)/checkpoint.json"
        ]
        let dirs: Set<String> = [
            "\(sessions)/\(sessionID)",
            "\(sessions)/latest",
            "\(sessions)/\(second)"
        ]
        let discovery = FxSessionDiscovery(customRoot: nil,
                                           fileProbe: FakeFileProbe(files: files, directories: dirs),
                                           homeDirectory: home)
        XCTAssertEqual(discovery.discoverSessionFiles().count, 1)
    }
}
