import XCTest
@testable import AgentSessions

final class OpenCodePresenceIntegrationTests: XCTestCase {
    private var temporary: URL!
    private var payload: URL!
    private var config: URL!
    private var retired: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("opencode-integration-" + UUID().uuidString)
        payload = temporary.appendingPathComponent("payload")
        config = temporary.appendingPathComponent("config")
        retired = temporary.appendingPathComponent("retired")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("{\"type\":\"module\"}".utf8).write(to: payload.appendingPathComponent("package.json"))
        try Data("export default { id: 'agent-sessions.presence', setup() {} };".utf8)
            .write(to: payload.appendingPathComponent("tui.js"))
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }
    private var installer: OpenCodePresenceInstaller { .init(payload: payload, retiredRoot: retired) }
    private var installed: URL { config.appendingPathComponent("plugins/agent-sessions-presence") }

    func testDistributablePayloadIsBundledWithTheApp() throws {
        let resource = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("OpenCodePresence")
        let script = try String(contentsOf: resource.appendingPathComponent("tui.js"), encoding: .utf8)
        XCTAssertTrue(script.contains("ctx.ui.router.current()"))
        XCTAssertTrue(script.contains("agent-sessions-opencode-tui"))
        let package = try JSONSerialization.jsonObject(with: Data(contentsOf: resource.appendingPathComponent("package.json"))) as? [String: Any]
        XCTAssertEqual(package?["type"] as? String, "module")
    }

    func testFreshInstallPreservesConfigurationAndSiblingPluginsAndIsIdempotent() throws {
        let sibling = config.appendingPathComponent("plugins/another-plugin")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let untouched = Data("// owner comments and explicit plugin disable\n{\"plugins\":[\"-agent-sessions.presence\"]}\n".utf8)
        let settings = config.appendingPathComponent("cli.json")
        try untouched.write(to: settings)
        try Data("owner".utf8).write(to: sibling.appendingPathComponent("tui.js"))
        XCTAssertTrue(try installer.install(configRoot: config))
        XCTAssertEqual(try Data(contentsOf: settings), untouched)
        XCTAssertEqual(try String(contentsOf: sibling.appendingPathComponent("tui.js"), encoding: .utf8), "owner")
        let script = installed.appendingPathComponent("tui.js")
        let before = try fm.attributesOfItem(atPath: script.path)[.modificationDate] as? Date
        XCTAssertFalse(try installer.install(configRoot: config))
        XCTAssertEqual(try fm.attributesOfItem(atPath: script.path)[.modificationDate] as? Date, before)
        XCTAssertEqual((try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUpdateAtomicallyExchangesPackageAndRetainsPreviousVersion() throws {
        try installer.install(configRoot: config)
        let old = try Data(contentsOf: installed.appendingPathComponent("tui.js"))
        let new = Data("export default {id:'agent-sessions.presence', setup(){return ()=>{}}};".utf8)
        try new.write(to: payload.appendingPathComponent("tui.js"))
        XCTAssertTrue(try installer.install(configRoot: config))
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("tui.js")), new)
        let previous = try XCTUnwrap(fm.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("tui.js")), old)
        XCTAssertFalse(try installer.install(configRoot: config))
    }

    func testRepeatedUpdatesKeepOnlyTheNewestRetiredCopies() throws {
        try installer.install(configRoot: config)
        var replaced: [Data] = []
        for version in 1...4 {
            replaced.append(try Data(contentsOf: installed.appendingPathComponent("tui.js")))
            try Data("export default {id:'agent-sessions.presence', version: \(version), setup(){}};".utf8)
                .write(to: payload.appendingPathComponent("tui.js"))
            XCTAssertTrue(try installer.install(configRoot: config))
        }
        let kept = try fm.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil)
        XCTAssertEqual(kept.count, OpenCodePresenceInstaller.retainedRetiredCopies)
        let keptScripts = Set(try kept.map { try Data(contentsOf: $0.appendingPathComponent("tui.js")) })
        XCTAssertEqual(keptScripts, Set(replaced.suffix(OpenCodePresenceInstaller.retainedRetiredCopies)))
    }

    func testUnrecognizedPackageIsNeverOverwrittenOrRemoved() throws {
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        let file = installed.appendingPathComponent("tui.js")
        try Data("unrelated".utf8).write(to: file)
        XCTAssertThrowsError(try installer.install(configRoot: config))
        XCTAssertThrowsError(try installer.disable(configRoot: config))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unrelated")
    }

    func testLocallyModifiedManagedPackageIsPreserved() throws {
        try installer.install(configRoot: config)
        let file = installed.appendingPathComponent("tui.js")
        try Data("customized".utf8).write(to: file)
        XCTAssertThrowsError(try installer.install(configRoot: config))
        XCTAssertThrowsError(try installer.disable(configRoot: config))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "customized")
    }

    func testDisableRetiresOnlyOwnedPackageAndCanReenable() throws {
        try installer.install(configRoot: config)
        let sibling = config.appendingPathComponent("plugins/keep.js")
        try Data("keep".utf8).write(to: sibling)
        try installer.disable(configRoot: config)
        XCTAssertFalse(fm.fileExists(atPath: installed.path))
        XCTAssertTrue(fm.fileExists(atPath: sibling.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: retired.path).count, 1)
        XCTAssertTrue(try installer.install(configRoot: config))
        XCTAssertTrue(fm.fileExists(atPath: installed.appendingPathComponent("tui.js").path))
    }

    func testSymlinkedPackageIsPreserved() throws {
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: installed, withDestinationURL: payload)
        XCTAssertThrowsError(try installer.install(configRoot: config))
        XCTAssertThrowsError(try installer.disable(configRoot: config))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installed.path), payload.path)
    }

    func testProfileResolvesXDGAndConfigDirectoryIndependentlyOfConfigFile() {
        let standard = OpenCodeRuntimeProfile(environment: [:], home: temporary)
        XCTAssertEqual(standard.config.path, temporary.appendingPathComponent(".config/opencode").path)
        let profile = OpenCodeRuntimeProfile(environment: ["HOME": "/profile", "XDG_CONFIG_HOME": "/xdg/config",
            "OPENCODE_CONFIG_DIR": "/custom/opencode", "OPENCODE_CONFIG": "/irrelevant/server.json",
            "XDG_STATE_HOME": "/xdg/state", "XDG_DATA_HOME": "/xdg/data"], home: temporary)
        XCTAssertEqual(profile.config.path, "/custom/opencode")
        XCTAssertEqual(profile.state.path, "/xdg/state/opencode")
        XCTAssertEqual(profile.data.path, "/xdg/data/opencode")
        let xdg = OpenCodeRuntimeProfile(environment: ["XDG_CONFIG_HOME": "/xdg/config"], home: temporary)
        XCTAssertEqual(xdg.config.path, "/xdg/config/opencode")
    }

    func testKernelEnvironmentReaderRetainsOnlyConfigurationAndStoragePaths() throws {
        let child = Process()
        // macOS redacts environments for protected Apple system binaries.
        // A copied fixture exercises the same non-platform path as OpenCode.
        let executable = temporary.appendingPathComponent("presence-env-probe")
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        child.executableURL = executable
        child.arguments = ["10"]
        child.environment = ["HOME": temporary.path, "OPENCODE_CONFIG_DIR": config.path,
                             "XDG_STATE_HOME": temporary.appendingPathComponent("state").path,
                             "UNRELATED_SECRET": "must-not-be-retained"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let environment = try XCTUnwrap(OpenCodeRuntimeProfile.environment(pid: child.processIdentifier))
        XCTAssertEqual(environment["HOME"], temporary.path)
        XCTAssertEqual(environment["OPENCODE_CONFIG_DIR"], config.path)
        XCTAssertEqual(Set(environment.keys), ["HOME", "OPENCODE_CONFIG_DIR", "XDG_STATE_HOME"])
        let profile = OpenCodeRuntimeProfile(environment: environment, home: temporary)
        XCTAssertEqual(profile.config.path, config.path)
        XCTAssertEqual(profile.state.path, temporary.appendingPathComponent("state/opencode").path)
    }

    func testFreshProfileAutomaticallyInstallsWithoutConfigurationOrInstallerAndRemembersRoots() async throws {
        let profile = OpenCodeRuntimeProfile(environment: [:], home: temporary.appendingPathComponent("fresh-user"))
        try fm.createDirectory(at: profile.data, withIntermediateDirectories: true)
        let support = temporary.appendingPathComponent("support")
        let manager = OpenCodePresenceIntegration()
        let status = await manager.reconcile(enabled: true, payload: payload, support: support, discoveredProfiles: [profile])
        XCTAssertTrue(status.contains("installed and managed automatically"), status)
        let package = profile.config.appendingPathComponent("plugins/agent-sessions-presence/tui.js")
        XCTAssertTrue(fm.fileExists(atPath: package.path))
        XCTAssertFalse(fm.fileExists(atPath: profile.config.appendingPathComponent("cli.json").path))
        let roots = await manager.stateRoots()
        XCTAssertTrue(roots.contains(profile.state))
        // A later app launch can disable even a custom profile whose process closed.
        let nextLaunch = OpenCodePresenceIntegration()
        let disabled = await nextLaunch.reconcile(enabled: false, payload: nil, support: support, discoveredProfiles: [])
        XCTAssertTrue(disabled.contains("removed"), disabled)
        XCTAssertFalse(fm.fileExists(atPath: package.path))
    }

    func testAbsentOpenCodeDoesNotCreateConfiguration() async {
        let profile = OpenCodeRuntimeProfile(environment: [:], home: temporary.appendingPathComponent("absent"))
        let status = await OpenCodePresenceIntegration().reconcile(enabled: true, payload: payload,
            support: temporary.appendingPathComponent("support"), discoveredProfiles: [profile])
        XCTAssertTrue(status.contains("when OpenCode is detected"), status)
        XCTAssertFalse(fm.fileExists(atPath: profile.config.path))
    }

    func testDeletedCustomConfigurationIsNotResurrectedFromRememberedRoots() async throws {
        let profile = OpenCodeRuntimeProfile(environment: [:], home: temporary.appendingPathComponent("custom-user"))
        try fm.createDirectory(at: profile.data, withIntermediateDirectories: true)
        let support = temporary.appendingPathComponent("support")
        let manager = OpenCodePresenceIntegration()
        _ = await manager.reconcile(enabled: true, payload: payload, support: support, discoveredProfiles: [profile])
        try fm.removeItem(at: profile.config)
        let status = await manager.reconcile(enabled: true, payload: payload, support: support, discoveredProfiles: [])
        XCTAssertFalse(fm.fileExists(atPath: profile.config.path))
        XCTAssertTrue(status.contains("when OpenCode is detected"), status)
    }

    func testRememberedExistingPackageUpdatesWithoutRewritingUnchangedRootInventory() async throws {
        let profile = OpenCodeRuntimeProfile(environment: [:], home: temporary.appendingPathComponent("custom-user"))
        try fm.createDirectory(at: profile.data, withIntermediateDirectories: true)
        let support = temporary.appendingPathComponent("support")
        let manager = OpenCodePresenceIntegration()
        _ = await manager.reconcile(enabled: true, payload: payload, support: support, discoveredProfiles: [profile])
        let record = support.appendingPathComponent("Integrations/opencode-managed-roots.json")
        let sentinel = Date(timeIntervalSince1970: 1000)
        try fm.setAttributes([.modificationDate: sentinel], ofItemAtPath: record.path)
        let updated = Data("export default {id:'agent-sessions.presence', setup(){ /* updated */ }}".utf8)
        try updated.write(to: payload.appendingPathComponent("tui.js"))
        let status = await manager.reconcile(enabled: true, payload: payload, support: support, discoveredProfiles: [])
        XCTAssertTrue(status.contains("installed and managed automatically"), status)
        XCTAssertEqual(try Data(contentsOf: profile.config.appendingPathComponent("plugins/agent-sessions-presence/tui.js")), updated)
        XCTAssertEqual(try fm.attributesOfItem(atPath: record.path)[.modificationDate] as? Date, sentinel)
    }

    func testDisabledUndetectedIntegrationDoesNotPromiseInstallation() async {
        let status = await OpenCodePresenceIntegration().reconcile(enabled: false, payload: nil,
            support: temporary.appendingPathComponent("support"), discoveredProfiles: [])
        XCTAssertTrue(status.contains("inactive"), status)
        XCTAssertFalse(fm.fileExists(atPath: temporary.appendingPathComponent("support").path))
    }
}
