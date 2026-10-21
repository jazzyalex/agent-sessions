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
        XCTAssertEqual(FxSessionDiscovery.sessionID(forSessionFile: discovery.discoverSessionFiles()[0]),
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

    // MARK: - Schema 4 (fx 0.0.8+)

    /// fx 0.0.8 moved to `session.json` schema 4 plus a conversation
    /// `events.jsonl` and stopped writing `checkpoint.json`. The event log is
    /// the discovery unit for those directories; the id is still the
    /// directory name (a 12-character token since 0.0.8).
    func testSchema4DirectoryDiscoversItsEventLog() throws {
        let sessions = "/Users/fx-demo/.fx/sessions"
        let id = "Fx4FixtureS1"
        let discovery = FxSessionDiscovery(
            customRoot: nil,
            fileProbe: FakeFileProbe(
                files: ["\(sessions)/\(id)/session.json", "\(sessions)/\(id)/events.jsonl"],
                directories: [sessions, "\(sessions)/\(id)"]),
            homeDirectory: home)

        let files = discovery.discoverSessionFiles()
        XCTAssertEqual(files.map(\.lastPathComponent), ["events.jsonl"])
        XCTAssertEqual(FxSessionDiscovery.sessionID(forSessionFile: try XCTUnwrap(files.first)), id)
        XCTAssertEqual(FxSessionDiscovery.layout(forSessionFile: try XCTUnwrap(files.first)), .eventLog)
    }

    /// A store holding both layouts lists both. A schema-3 directory keeps its
    /// checkpoint even though it also has an (infrastructure) `events.jsonl`;
    /// a schema-3 directory with no checkpoint (it still has `authority.json`)
    /// is not mistaken for schema 4; the opt-in sessions-v2 root `v2/` and a
    /// sidecar-less directory are skipped.
    func testMixedStoreListsBothLayoutsAndSkipsLegacyStubsAndV2Root() {
        let sessions = "/Users/fx-demo/.fx/sessions"
        let legacy = sessionID
        let current = "Fx4FixtureS1"
        let stub = "1787262000000-1787262000000000000-0000000000000002"
        let orphan = "Fx4OrphanAAA"
        let files: Set<String> = [
            "\(sessions)/\(legacy)/checkpoint.json",
            "\(sessions)/\(legacy)/session.json",
            "\(sessions)/\(legacy)/events.jsonl",
            "\(sessions)/\(current)/session.json",
            "\(sessions)/\(current)/events.jsonl",
            "\(sessions)/\(stub)/session.json",
            "\(sessions)/\(stub)/events.jsonl",
            "\(sessions)/\(stub)/authority.json",
            "\(sessions)/v2/session.json",
            "\(sessions)/v2/events.jsonl",
            "\(sessions)/\(orphan)/events.jsonl"
        ]
        let dirs: Set<String> = [
            sessions,
            "\(sessions)/\(legacy)",
            "\(sessions)/\(current)",
            "\(sessions)/\(stub)",
            "\(sessions)/v2",
            "\(sessions)/\(orphan)"
        ]
        let discovery = FxSessionDiscovery(customRoot: nil,
                                           fileProbe: FakeFileProbe(files: files, directories: dirs),
                                           homeDirectory: home)

        let found = Set(discovery.discoverSessionFiles().map(\.path))
        XCTAssertEqual(found, [
            "\(sessions)/\(legacy)/checkpoint.json",
            "\(sessions)/\(current)/events.jsonl"
        ])
    }
}
