import XCTest
@testable import AgentSessions

/// The Antigravity sessions-root override reached availability
/// (`AntigravitySourceDescriptor`), presence (`PresenceEngine`) and archive
/// backfill, but never the indexer — which built its discovery with no
/// arguments and so always scanned the default root. A custom path therefore
/// made the agent look available at that path while listing nothing from it,
/// which is worse than ignoring the setting outright.
///
/// The indexer assertions deliberately check both directions. A machine that
/// happens to have a real `~/.gemini/antigravity/brain` would pass the
/// "custom root is readable" case even unwired, and a machine without one
/// would pass the "missing root is unreadable" case even unwired; only a
/// wired indexer satisfies both.
@MainActor
final class AntigravitySessionsRootOverrideTests: XCTestCase {

    private let overrideKey = PreferencesKey.Paths.antigravitySessionsRootOverride
    /// `refresh()` returns before touching discovery when the agent is off, and
    /// tests share `UserDefaults.standard` with the developer's own settings —
    /// so this must be forced on, and it is the enablement key the registry
    /// reads (`AgentEnabledAntigravity`), not `IncludeAntigravitySessions`.
    private let enabledKey = PreferencesKey.Agents.antigravityEnabled

    private var savedOverride: Any?
    private var savedEnabled: Any?
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        savedOverride = UserDefaults.standard.object(forKey: overrideKey)
        savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    override func tearDown() {
        restore(savedOverride, forKey: overrideKey)
        restore(savedEnabled, forKey: enabledKey)
        for url in tempRoots { try? FileManager.default.removeItem(at: url) }
        tempRoots = []
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A brain root in the real on-disk shape: `<root>/<conversation-id>/<artifact>.md`.
    private func makeBrainRoot(artifact: String, function: String = #function) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRootOverride.\(function).\(UUID().uuidString)", isDirectory: true)
        let conversation = root.appendingPathComponent("conversation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        try "# walkthrough\n".write(to: conversation.appendingPathComponent(artifact), atomically: true, encoding: .utf8)
        tempRoots.append(root)
        return root
    }

    private func missingRootPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRootOverride.absent.\(UUID().uuidString)", isDirectory: true)
            .path
    }

    // MARK: - Discovery contract

    /// The plumbing target: a custom root changes which files are discovered.
    func testCustomRootChangesTheDiscoveredFileSet() throws {
        let rootA = try makeBrainRoot(artifact: "alpha.md")
        let rootB = try makeBrainRoot(artifact: "beta.md")

        // `cliRoot` is pinned to an absent directory on purpose. Without it this
        // test picks up the developer's real `~/.gemini/antigravity-cli/brain`,
        // which is itself the finding: the single override moves the markdown
        // brain store only, and CLI transcripts keep coming from the default
        // location. The Preferences copy now says so.
        let absentCLI = missingRootPath()
        let fromA = AntigravitySessionDiscovery(customRoot: rootA.path, cliRoot: absentCLI).discoverSessionFiles()
        let fromB = AntigravitySessionDiscovery(customRoot: rootB.path, cliRoot: absentCLI).discoverSessionFiles()

        XCTAssertEqual(fromA.map(\.lastPathComponent), ["alpha.md"])
        XCTAssertEqual(fromB.map(\.lastPathComponent), ["beta.md"])
        XCTAssertNotEqual(fromA, fromB, "a different custom root must yield a different file set")
    }

    /// An empty override string means "use the default", never "use the empty path".
    func testEmptyOverrideFallsBackToTheDefaultRoot() {
        let root = AntigravitySessionDiscovery(customRoot: "").sessionsRoot()
        XCTAssertEqual(root.path, NSHomeDirectory() + "/.gemini/antigravity/brain")
    }

    // MARK: - Indexer wiring (the regression)

    func testIndexerReadsTheCustomRootWhenTheOverrideIsSet() throws {
        let root = try makeBrainRoot(artifact: "alpha.md")
        UserDefaults.standard.set(root.path, forKey: overrideKey)

        let indexer = AntigravitySessionIndexer()

        XCTAssertTrue(indexer.canAccessRootDirectory,
                      "indexer ignored the override and scanned the default root instead of \(root.path)")
    }

    func testIndexerReportsAMissingCustomRootAsUnreadable() {
        let absent = missingRootPath()
        UserDefaults.standard.set(absent, forKey: overrideKey)

        let indexer = AntigravitySessionIndexer()

        XCTAssertFalse(indexer.canAccessRootDirectory,
                       "indexer fell back to the default root; a custom path that does not exist must read as unreadable")
    }

    /// Changing the preference after launch must re-point discovery, otherwise
    /// the setting only takes effect on the next app start.
    func testRefreshPicksUpAnOverrideChangedAfterInit() throws {
        UserDefaults.standard.set(missingRootPath(), forKey: overrideKey)
        let indexer = AntigravitySessionIndexer()
        XCTAssertFalse(indexer.canAccessRootDirectory)

        let root = try makeBrainRoot(artifact: "alpha.md")
        UserDefaults.standard.set(root.path, forKey: overrideKey)
        indexer.refresh(mode: .fullReconcile, trigger: .manual)

        XCTAssertTrue(indexer.canAccessRootDirectory,
                      "refresh did not re-read the override, so a Preferences change needs an app restart")
    }
}
